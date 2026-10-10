import 'plan/dates.dart';
import 'plan/plan.dart';
import 'plan/request.dart';
import 'plan/rules.dart';
import 'plan/validator.dart' show Severity;

/// A workout on the calendar, reduced to what the schedule rules need.
final class ScheduledItem {
  ScheduledItem({
    required this.id,
    required DateTime date,
    required this.kind,
    this.isKey = false,
    this.heavyStrength = false,
    required this.estimatedDuration,
    Duration? runDuration,
  })  : date = dateOnly(date),
        runDuration = runDuration ??
            (kind == SessionKind.strength ? Duration.zero : estimatedDuration);

  final int id;
  final DateTime date;
  final SessionKind kind;
  final bool isKey;

  /// Heavy lower-body strength (see `StrengthSession.isHeavyLowerBody`).
  final bool heavyStrength;
  final Duration estimatedDuration;

  /// Running part of [estimatedDuration]; defaults to all of it unless strength.
  final Duration runDuration;

  bool get isRun => runDuration > Duration.zero;

  /// Counts as a hard day for recovery rules.
  bool get isHard =>
      isKey ||
      kind.isQuality ||
      kind == SessionKind.long ||
      kind == SessionKind.race;

  ScheduledItem moved(DateTime to) => ScheduledItem(
        id: id,
        date: to,
        kind: kind,
        isKey: isKey,
        heavyStrength: heavyStrength,
        estimatedDuration: estimatedDuration,
        runDuration: runDuration,
      );
}

final class ScheduleIssue {
  const ScheduleIssue({
    required this.severity,
    this.itemId,
    required this.date,
    required this.code,
    required this.message,
    this.weekly = false,
  });

  final Severity severity;

  /// The item the issue is attached to; null for week-level issues.
  final int? itemId;
  final DateTime date;
  final String code;
  final String message;

  /// Concerns the whole Mon–Sun week starting at [date].
  final bool weekly;

  @override
  String toString() =>
      '${severity.name} [$code] ${date.toIso8601String().substring(0, 10)}: $message';
}

/// Rule checks for any list of scheduled items, not only generated plans.
/// Pass whole Mon–Sun weeks (ideally plus the previous one) to avoid
/// false positives from truncated weeks.
abstract final class ScheduleChecker {
  static List<ScheduleIssue> check(
    Iterable<ScheduledItem> items, {
    WeeklyAvailability? availability,
    int maxQualityPer7Days = 2,
    RaceCategory category = RaceCategory.half,
  }) {
    final out = <ScheduleIssue>[];
    final all = items.toList()
      ..sort((a, b) {
        final c = a.date.compareTo(b.date);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    final byDay = <int, List<ScheduledItem>>{};
    final byWeek = <int, List<ScheduledItem>>{};
    for (final i in all) {
      (byDay[dayNumber(i.date)] ??= []).add(i);
      (byWeek[_weekStart(i.date)] ??= []).add(i);
    }

    void add(Severity s, DateTime d, String code, String msg,
            {int? id, bool weekly = false}) =>
        out.add(ScheduleIssue(
            severity: s,
            itemId: id,
            date: d,
            code: code,
            message: msg,
            weekly: weekly));
    int minutes(Duration d) => (d.inSeconds / 60).round();
    bool hardOn(int day) => byDay[day]?.any((i) => i.isHard) ?? false;

    for (final MapEntry(key: day, value: entries) in byDay.entries) {
      final date = entries.first.date;
      final nonRace = entries.where((i) => i.kind != SessionKind.race).toList();

      if (entries.any((i) => i.isHard) && hardOn(day + 1)) {
        final next = byDay[day + 1]!.firstWhere((i) => i.isHard);
        add(Severity.error, next.date, 'consecutive_key_days',
            'Hard sessions on consecutive days',
            id: next.id);
      }

      final heavy = entries.where((i) => i.heavyStrength);
      if (heavy.isNotEmpty) {
        final id = heavy.first.id;
        if (hardOn(day + 1)) {
          add(Severity.error, date, 'heavy_strength_before_key',
              'Heavy lower-body strength the day before a hard session',
              id: id);
        } else if (!entries.any((i) => i.isHard) && hardOn(day + 2)) {
          add(Severity.warning, date, 'heavy_strength_48h',
              'Heavy lower-body strength < 48 h before a hard session',
              id: id);
        }
      }

      final runs = entries.where((i) => i.isRun).toList();
      if (runs.length >= 2) {
        add(Severity.info, date, 'two_runs_same_day', 'Two runs on one day',
            id: runs[1].id);
      }

      if (availability != null && nonRace.isNotEmpty) {
        final avail = availability[date.weekday];
        if (!avail.available) {
          add(Severity.error, date, 'unavailable_day',
              'Session on an unavailable day',
              id: nonRace.first.id);
        } else if (avail.maxDuration case final limit?) {
          final total =
              nonRace.fold(Duration.zero, (a, i) => a + i.estimatedDuration);
          if (total > limit + PlanRules.tolerance) {
            add(Severity.error, date, 'max_duration',
                '${minutes(total)} min exceeds ${limit.inMinutes} min limit',
                id: nonRace.last.id);
          }
        }
      }
    }

    final quality = [
      for (final i in all)
        if (i.kind.isQuality) i
    ];
    for (var n = 0; n < quality.length; n++) {
      final end = dayNumber(quality[n].date);
      final inWindow =
          quality.sublist(0, n + 1).where((q) => end - dayNumber(q.date) < 7);
      if (inWindow.length > maxQualityPer7Days) {
        add(Severity.error, quality[n].date, 'too_many_quality',
            '${inWindow.length} quality sessions within 7 days (max $maxQualityPer7Days)',
            id: quality[n].id);
      }
    }

    final volumes = {
      for (final MapEntry(:key, :value) in byWeek.entries)
        key: value
            .where((i) => i.kind != SessionKind.race)
            .fold(Duration.zero, (a, i) => a + i.runDuration),
    };
    for (final MapEntry(key: week, value: entries) in byWeek.entries) {
      final first = entries.first.date;
      final weekStart = addDays(first, 1 - first.weekday);
      final vol = volumes[week]!;

      final days = {for (final i in entries) dayNumber(i.date)};
      if (days.length >= 7) {
        add(Severity.error, weekStart, 'no_rest_day', 'No rest day this week',
            weekly: true);
      }

      final runDays = {
        for (final i in entries)
          if (i.isRun && i.kind != SessionKind.race) dayNumber(i.date)
      }.length;
      if (runDays >= 2) {
        final share = PlanRules.longRunShareCap(runDays, category);
        for (final l in entries.where((i) => i.kind == SessionKind.long)) {
          if (l.runDuration.inSeconds >
              share * vol.inSeconds + PlanRules.tolerance.inSeconds) {
            add(
                Severity.warning,
                l.date,
                'long_run_share',
                'Long run is ${(l.runDuration.inSeconds / vol.inSeconds * 100).round()}% '
                    'of weekly running (aim ≤ ${(share * 100).round()}%)',
                id: l.id);
          }
        }
      }

      final prev = volumes[week - 7];
      if (prev != null && prev > Duration.zero) {
        final limit = prev.inSeconds * (1 + PlanRules.maxWeeklyRamp) +
            PlanRules.tolerance.inSeconds;
        if (vol.inSeconds > limit) {
          add(Severity.warning, weekStart, 'volume_ramp',
              'Running volume ${minutes(vol)} min is more than +10% over last week (${minutes(prev)} min)',
              weekly: true);
        }
      }
    }

    out.sort((a, b) {
      final c = a.date.compareTo(b.date);
      return c != 0 ? c : a.code.compareTo(b.code);
    });
    return out;
  }

  /// Day number of the Monday starting [d]'s week.
  static int _weekStart(DateTime d) => dayNumber(d) - (d.weekday - 1);
}
