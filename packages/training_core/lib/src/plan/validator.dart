import 'dart:math';

import 'dates.dart';
import 'plan.dart';
import 'rules.dart';

enum Severity { error, warning, info }

final class PlanViolation {
  const PlanViolation({
    required this.severity,
    required this.weekIndex,
    this.date,
    required this.code,
    required this.message,
  });

  final Severity severity;
  final int weekIndex;
  final DateTime? date;
  final String code;
  final String message;

  @override
  String toString() =>
      '${severity.name} [$code] week $weekIndex${date == null ? '' : ' ${date!.toIso8601String().substring(0, 10)}'}: $message';
}

/// Guardrails every plan (generated or AI-edited) must satisfy.
abstract final class PlanValidator {
  static List<PlanViolation> validate(TrainingPlan plan) {
    final out = <PlanViolation>[];
    final p = plan.profile;
    final req = plan.request;
    final tol = PlanRules.tolerance.inSeconds / 60;
    void add(Severity s, int week, String code, String msg, [DateTime? d]) =>
        out.add(PlanViolation(
            severity: s, weekIndex: week, date: d, code: code, message: msg));
    double minutes(Duration d) => d.inSeconds / 60;

    final volumes = [for (final w in plan.weeks) minutes(w.runningVolume(p))];
    final byDay = <int, List<(int, PlannedSession)>>{};
    for (final w in plan.weeks) {
      for (final s in w.sessions) {
        (byDay[dayNumber(s.date)] ??= []).add((w.index, s));
      }
    }

    for (final w in plan.weeks) {
      final i = w.index;
      final vol = volumes[i];

      if (i > 0) {
        var ref = i - 1;
        if (plan.weeks[ref].isRecovery) {
          while (ref > 0 && plan.weeks[ref].isRecovery) {
            ref--;
          }
        }
        final limit = volumes[ref] * (1 + PlanRules.maxWeeklyRamp) + tol;
        if (vol > limit) {
          add(Severity.error, i, 'volume_ramp',
              'Volume ${vol.round()} min exceeds +10% over week $ref (${volumes[ref].round()} min)');
        }
        if (w.phase == Phase.taper &&
            volumes[i - 1] > 0 &&
            vol >= volumes[i - 1]) {
          add(Severity.error, i, 'taper_not_decreasing',
              'Taper volume ${vol.round()} min is not below the previous week');
        }
      }

      final runDays = {
        for (final s in w.sessions)
          if (s.kind != SessionKind.race &&
              s.workout.estimatedRunDuration(p) > Duration.zero)
            dayNumber(s.date)
      }.length;
      for (final s in w.sessions.where((s) => s.kind == SessionKind.long)) {
        final m = minutes(s.workout.estimatedRunDuration(p));
        final share = PlanRules.longRunShareCap(runDays, plan.category);
        if (m > share * vol + tol) {
          add(
              Severity.error,
              i,
              'long_run_share',
              'Long run ${m.round()} min is > ${(share * 100).round()}% of ${vol.round()} min',
              s.date);
        }
        final cap = minutes(PlanRules.longRunCap(plan.category));
        if (m > cap + tol) {
          add(
              Severity.error,
              i,
              'long_run_duration',
              'Long run ${m.round()} min exceeds ${cap.round()} min cap',
              s.date);
        }
      }

      final sessionDays = {for (final s in w.sessions) dayNumber(s.date)};
      if (sessionDays.length >= 7) {
        add(Severity.error, i, 'no_rest_day', 'No rest day in this week');
      }

      final quality = w.sessions.where((s) => s.kind.isQuality).length;
      final maxQuality = PlanRules.maxQualityPerWeek(req.experience);
      if (quality > maxQuality) {
        add(Severity.error, i, 'too_many_quality',
            '$quality quality sessions (max $maxQuality)');
      }

      final hard = w.sessions.where((s) => s.kind != SessionKind.race).fold(
          Duration.zero, (a, s) => a + s.workout.estimatedHardDuration(p));
      if (vol > 0 && minutes(hard) / vol > PlanRules.maxHardFraction) {
        add(Severity.warning, i, 'intensity_distribution',
            '${(minutes(hard) / vol * 100).round()}% of running time is hard (aim ≤ ${(PlanRules.maxHardFraction * 100).round()}%)');
      }

      final strengthCount = w.sessions.where((s) => s.strength != null).length;
      if (req.strength.isActive &&
          strengthCount > req.strength.sessionsPerWeek) {
        add(Severity.warning, i, 'strength_count',
            '$strengthCount strength sessions (goal ${req.strength.sessionsPerWeek})');
      }
    }

    for (final MapEntry(key: day, value: entries) in byDay.entries) {
      final week = entries.first.$1;
      final date = entries.first.$2.date;
      final nonRace = [
        for (final (_, s) in entries)
          if (s.kind != SessionKind.race) s
      ];
      final avail = req.availability[date.weekday];
      if (nonRace.isNotEmpty && !avail.available) {
        add(Severity.error, week, 'unavailable_day',
            'Session on an unavailable day', date);
      }
      final total = nonRace.fold(
          Duration.zero, (a, s) => a + s.workout.estimatedDuration(p));
      if (avail.maxDuration case final limit?
          when total > limit + PlanRules.tolerance) {
        add(
            Severity.error,
            week,
            'max_duration',
            '${minutes(total).round()} min exceeds ${limit.inMinutes} min limit',
            date);
      }

      final isKey = entries.any((e) => e.$2.isKey);
      bool keyOn(int d) => byDay[d]?.any((e) => e.$2.isKey) ?? false;
      if (isKey && keyOn(day + 1)) {
        add(Severity.error, byDay[day + 1]!.first.$1, 'consecutive_key_days',
            'Key sessions on consecutive days', addDays(date, 1));
      }
      if (entries.any((e) => e.$2.strength?.isHeavyLowerBody ?? false)) {
        if (keyOn(day + 1)) {
          add(Severity.error, week, 'heavy_strength_before_key',
              'Heavy lower-body strength the day before a key session', date);
        } else if (!isKey && keyOn(day + 2)) {
          add(Severity.warning, week, 'heavy_strength_48h',
              'Heavy lower-body strength < 48 h before a key session', date);
        }
      }
    }

    if (req.raceDate case final race?) {
      final found =
          byDay[dayNumber(race)]?.any((e) => e.$2.kind == SessionKind.race) ??
              false;
      if (!found) {
        add(Severity.error, max(0, plan.weeks.length - 1), 'race_missing',
            'No race session on race day', race);
      }
    }

    out.sort((a, b) => a.weekIndex.compareTo(b.weekIndex));
    return out;
  }

  static bool isValid(TrainingPlan plan) =>
      validate(plan).every((v) => v.severity != Severity.error);
}
