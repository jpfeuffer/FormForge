import 'compliance.dart';
import 'load.dart';
import 'plan/dates.dart';
import 'plan/plan.dart';
import 'plan/request.dart';
import 'test_evaluation.dart';
import 'workout.dart';

enum SuggestionSeverity { info, warning, critical }

/// What happened to a planned session; [missed] = past, no activity, not skipped.
enum OutcomeStatus { done, partial, skipped, missed }

/// A past planned session with its evaluation, as input to the engine.
final class SessionOutcome {
  const SessionOutcome({
    required this.date,
    required this.kind,
    required this.status,
    this.isKey = false,
    this.compliance,
  });

  final DateTime date;
  final SessionKind kind;
  final OutcomeStatus status;
  final bool isKey;
  final SessionCompliance? compliance;

  bool get executed =>
      status == OutcomeStatus.done || status == OutcomeStatus.partial;

  /// Skipped, missed or cut short.
  bool get notCompleted =>
      status != OutcomeStatus.done ||
      compliance?.verdict == SessionVerdict.incomplete;
}

final class UpcomingSession {
  const UpcomingSession({
    required this.date,
    required this.kind,
    this.isKey = false,
  });

  final DateTime date;
  final SessionKind kind;
  final bool isKey;
}

/// A detected hard effort and where to find it again (e.g. an activity id).
final class EffortCandidate {
  const EffortCandidate({
    required this.ref,
    required this.date,
    required this.effort,
  });

  final String ref;
  final DateTime date;
  final DetectedEffort effort;
}

sealed class AdaptationAction {
  const AdaptationAction();

  Map<String, Object?> toJson();
}

/// Rebuild the future plan with [fitness].
final class RegenerateFuture extends AdaptationAction {
  const RegenerateFuture(this.fitness);

  final CurrentFitness fitness;

  @override
  Map<String, Object?> toJson() => {
        'type': 'regenerateFuture',
        'fitness': _fitnessJson(fitness),
      };
}

/// Scale next week's volume and intensity by [factor] (< 1).
final class ReduceNextWeek extends AdaptationAction {
  const ReduceNextWeek(this.factor);

  final double factor;

  @override
  Map<String, Object?> toJson() => {'type': 'reduceNextWeek', 'factor': factor};
}

final class ScheduleTest extends AdaptationAction {
  const ScheduleTest(this.type);

  final TestType type;

  @override
  Map<String, Object?> toJson() => {'type': 'scheduleTest', 'test': type.name};
}

/// Turn [date] into a rest or recovery day.
final class AddRecoveryDay extends AdaptationAction {
  const AddRecoveryDay(this.date);

  final DateTime date;

  @override
  Map<String, Object?> toJson() => {
        'type': 'addRecoveryDay',
        'date': date.toIso8601String(),
      };
}

/// Take a detected effort as new fitness; [ref] identifies its source.
final class AdoptEffort extends AdaptationAction {
  const AdoptEffort(
      {required this.ref, required this.effort, required this.date});

  final String ref;
  final DetectedEffort effort;
  final DateTime date;

  @override
  Map<String, Object?> toJson() => {
        'type': 'adoptEffort',
        'ref': ref,
        'distanceM': effort.distanceM,
        'seconds': effort.time.inSeconds,
        'vdot': effort.vdot,
        'date': date.toIso8601String(),
      };
}

/// Nothing to apply; the message is the point.
final class Advice extends AdaptationAction {
  const Advice();

  @override
  Map<String, Object?> toJson() => {'type': 'advice'};
}

final class AdaptationSuggestion {
  AdaptationSuggestion({
    required this.code,
    required this.severity,
    required this.message,
    required this.action,
    String? key,
  }) : key = key ?? code;

  final String code;
  final SuggestionSeverity severity;
  final String message;
  final AdaptationAction action;

  /// Stable id for dismissals; changes when new evidence arrives.
  final String key;

  Map<String, Object?> toJson() => {
        'code': code,
        'key': key,
        'severity': severity.name,
        'message': message,
        'action': action.toJson(),
      };
}

/// Deterministic coaching rules over recent history.
abstract final class AdaptationEngine {
  static const fitnessChangeVdot = 1.0;
  static const easyWindowDays = 14;
  static const qualityWindowDays = 14;
  static const missedWindowDays = 7;
  static const decouplingWindowDays = 28;
  static const exceedWindowDays = 21;
  static const detectedWindowDays = 14;
  static const acwrLimit = 1.3;
  static const acwrCritical = 1.5;
  static const formLimit = -30.0;
  static const formCritical = -40.0;

  /// ACWR is noise below this CTL.
  static const minCtlForAcwr = 15.0;
  static const decouplingLimit = 5.0;
  static const exceedSpeedRatio = 1.03;
  static const testCooldownDays = 21;

  /// [history]: planned sessions up to [today] (activity-matched ones may be
  /// today). [planFitness] is what the plan was sized with, [currentFitness]
  /// the latest test/race result.
  static List<AdaptationSuggestion> suggest({
    required DateTime today,
    required List<SessionOutcome> history,
    List<UpcomingSession> upcoming = const [],
    CurrentFitness? planFitness,
    CurrentFitness? currentFitness,
    List<LoadPoint> load = const [],
    List<EffortCandidate> detected = const [],
    DateTime? lastTestDate,
  }) {
    final day = dateOnly(today);
    final past = [
      for (final o in history)
        if (dateOnly(o.date).isBefore(day) || o.executed) o,
    ]..sort((a, b) => a.date.compareTo(b.date));

    final out = [
      _fitnessChanged(planFitness, currentFitness),
      _detected(day, detected, currentFitness ?? planFitness),
      _load(day, load, upcoming),
      _missed(day, past),
      _qualityNotCompleted(day, past),
      _easyTooHard(day, past),
      _decoupling(day, past),
      _exceeding(day, past, upcoming, planFitness, lastTestDate),
    ].nonNulls.toList();
    // List.sort is not stable.
    final order = [...out];
    return out
      ..sort((a, b) {
        final bySeverity = b.severity.index.compareTo(a.severity.index);
        return bySeverity != 0
            ? bySeverity
            : order.indexOf(a).compareTo(order.indexOf(b));
      });
  }

  static double? _vdot(CurrentFitness? f) =>
      f?.vdot ?? (f?.mas == null ? null : PaceProfile.vdotFromMas(f!.mas!));

  static AdaptationSuggestion? _fitnessChanged(
    CurrentFitness? plan,
    CurrentFitness? current,
  ) {
    final p = _vdot(plan), c = _vdot(current);
    if (p == null || c == null || (c - p).abs() < fitnessChangeVdot) {
      return null;
    }
    final better = c > p;
    return AdaptationSuggestion(
      code: 'fitness_changed',
      severity: better ? SuggestionSeverity.info : SuggestionSeverity.warning,
      message:
          'Fitness is ${better ? 'up' : 'down'} from VDOT ${p.toStringAsFixed(1)} '
          'to ${c.toStringAsFixed(1)}. Re-pace the remaining plan?',
      action: RegenerateFuture(current!),
      key: 'fitness_changed:${c.toStringAsFixed(1)}',
    );
  }

  static AdaptationSuggestion? _detected(
    DateTime day,
    List<EffortCandidate> detected,
    CurrentFitness? fitness,
  ) {
    final base = _vdot(fitness);
    final fresh = [
      for (final c in detected)
        if (daysBetween(c.date, day) <= detectedWindowDays &&
            (base == null || c.effort.vdot - base >= fitnessChangeVdot))
          c,
    ]..sort((a, b) => b.effort.vdot.compareTo(a.effort.vdot));
    if (fresh.isEmpty) return null;
    final c = fresh.first;
    final e = c.effort;
    return AdaptationSuggestion(
      code: 'detected_effort',
      severity: SuggestionSeverity.info,
      message: 'Use this ${_distanceLabel(e.distanceM)} effort '
          '(${_clock(e.time)}, VDOT ${e.vdot.toStringAsFixed(1)}) as new fitness?',
      action: AdoptEffort(ref: c.ref, effort: e, date: c.date),
      key: 'detected_effort:${c.ref}:${e.distanceM.round()}',
    );
  }

  static AdaptationSuggestion? _load(
    DateTime day,
    List<LoadPoint> load,
    List<UpcomingSession> upcoming,
  ) {
    final p = load.lastOrNull;
    if (p == null) return null;
    final acwr = p.ctl >= minCtlForAcwr ? p.acwr : null;
    final form = p.ctl - p.atl;
    final highAcwr = acwr != null && acwr > acwrLimit;
    if (!highAcwr && form >= formLimit) return null;
    final critical =
        (acwr != null && acwr > acwrCritical) || form < formCritical;
    final reason = [
      if (highAcwr) 'acute:chronic load ${acwr.toStringAsFixed(2)}',
      if (form < formLimit) 'form (TSB) ${form.round()}',
    ].join(' and ');
    return AdaptationSuggestion(
      code: 'load_high',
      severity:
          critical ? SuggestionSeverity.critical : SuggestionSeverity.warning,
      message: 'Training load is high: $reason. Add a recovery day.',
      action: AddRecoveryDay(_recoveryDate(day, upcoming)),
      key: 'load_high:${day.toIso8601String().substring(0, 10)}',
    );
  }

  /// First of the next three days without a key session.
  static DateTime _recoveryDate(DateTime day, List<UpcomingSession> upcoming) {
    for (var i = 1; i <= 3; i++) {
      final d = addDays(day, i);
      final key = upcoming.any((u) => dateOnly(u.date) == d && u.isKey);
      if (!key) return d;
    }
    return addDays(day, 1);
  }

  static AdaptationSuggestion? _missed(
      DateTime day, List<SessionOutcome> past) {
    final missed = [
      for (final o in past)
        if (!o.executed && daysBetween(o.date, day) <= missedWindowDays) o,
    ];
    if (missed.length < 2) return null;
    return AdaptationSuggestion(
      code: 'missed_sessions',
      severity: SuggestionSeverity.warning,
      message:
          '${missed.length} sessions missed in the last $missedWindowDays days. '
          'Lighten next week.',
      action: const ReduceNextWeek(0.9),
      key: 'missed_sessions:${_date(missed.last.date)}',
    );
  }

  static AdaptationSuggestion? _qualityNotCompleted(
    DateTime day,
    List<SessionOutcome> past,
  ) {
    final quality = _last3(
      past,
      day,
      qualityWindowDays,
      (o) => o.kind.isQuality && o.kind != SessionKind.test,
    );
    final bad = quality.where((o) => o.notCompleted).toList();
    if (quality.length < 2 || bad.length < 2) return null;
    return AdaptationSuggestion(
      code: 'quality_not_completed',
      severity: SuggestionSeverity.warning,
      message:
          '${bad.length} of the last ${quality.length} quality sessions were not '
          'completed. Reduce intensity and volume next week.',
      action: const ReduceNextWeek(0.85),
      key: 'quality_not_completed:${_date(bad.last.date)}',
    );
  }

  static AdaptationSuggestion? _easyTooHard(
    DateTime day,
    List<SessionOutcome> past,
  ) {
    const easyKinds = {
      SessionKind.easy,
      SessionKind.recovery,
      SessionKind.long
    };
    final runs = _last3(
      past,
      day,
      easyWindowDays,
      (o) =>
          easyKinds.contains(o.kind) &&
          o.executed &&
          o.compliance != null &&
          o.compliance!.verdict != SessionVerdict.incomplete,
    );
    final hard = runs
        .where((o) => o.compliance!.verdict == SessionVerdict.tooHard)
        .toList();
    if (runs.length < 2 || hard.length < 2) return null;
    final pace = hard.any((o) => o.compliance!.tooFast);
    final hr = hard.any((o) => o.compliance!.hrTooHigh);
    final what = switch ((pace, hr)) {
      (true, true) => 'too fast and with HR too high',
      (true, false) => 'too fast',
      _ => 'with HR too high',
    };
    return AdaptationSuggestion(
      code: 'easy_too_hard',
      severity: SuggestionSeverity.warning,
      message:
          '${hard.length} of the last ${runs.length} easy runs were $what. '
          'Slow down; easy days make the hard days work.',
      action: const Advice(),
      key: 'easy_too_hard:${_date(hard.last.date)}',
    );
  }

  static AdaptationSuggestion? _decoupling(
    DateTime day,
    List<SessionOutcome> past,
  ) {
    final runs = _last3(
      past,
      day,
      decouplingWindowDays,
      (o) =>
          (o.kind == SessionKind.long || o.kind == SessionKind.easy) &&
          o.compliance?.decoupling != null,
    );
    final drifting =
        runs.where((o) => o.compliance!.decoupling! > decouplingLimit).toList();
    if (runs.length < 2 || drifting.length < 2) return null;
    return AdaptationSuggestion(
      code: 'decoupling_high',
      severity: SuggestionSeverity.info,
      message: 'Aerobic decoupling above ${decouplingLimit.round()} % on '
          '${drifting.length} of the last ${runs.length} long/easy runs. '
          'Build more easy aerobic volume before adding intensity.',
      action: const Advice(),
      key: 'decoupling_high:${_date(drifting.last.date)}',
    );
  }

  static AdaptationSuggestion? _exceeding(
    DateTime day,
    List<SessionOutcome> past,
    List<UpcomingSession> upcoming,
    CurrentFitness? fitness,
    DateTime? lastTestDate,
  ) {
    final quality = _last3(
      past,
      day,
      exceedWindowDays,
      (o) => o.kind.isQuality && o.kind != SessionKind.test,
    );
    if (quality.length < 3) return null;
    final exceeding = quality.every((o) {
      final c = o.compliance;
      return o.executed &&
          c != null &&
          c.completion >= 0.9 &&
          (c.speedRatio ?? 0) >= exceedSpeedRatio &&
          !c.hrTooHigh;
    });
    if (!exceeding) return null;
    final testSoon = upcoming.any(
      (u) => u.kind == SessionKind.test && daysBetween(day, u.date) <= 14,
    );
    final recentTest = lastTestDate != null &&
        daysBetween(lastTestDate, day) < testCooldownDays;
    if (testSoon || recentTest) return null;
    return AdaptationSuggestion(
      code: 'exceeding_targets',
      severity: SuggestionSeverity.info,
      message:
          'You beat the targets in the last 3 quality sessions. Fitness may '
          'have improved; schedule a test run.',
      action: ScheduleTest(
        fitness?.vdot != null || fitness?.mas == null
            ? TestType.timeTrial5k
            : TestType.halfCooper,
      ),
      key: 'exceeding_targets:${_date(quality.last.date)}',
    );
  }

  /// The latest (up to) three matching outcomes within [days] of [day].
  static List<SessionOutcome> _last3(
    List<SessionOutcome> past,
    DateTime day,
    int days,
    bool Function(SessionOutcome) test,
  ) {
    final hits = [
      for (final o in past)
        if (daysBetween(o.date, day) <= days && test(o)) o,
    ];
    return hits.length <= 3 ? hits : hits.sublist(hits.length - 3);
  }

  static String _date(DateTime d) => d.toIso8601String().substring(0, 10);

  static String _distanceLabel(double meters) => switch (meters) {
        21097.5 => 'half-marathon',
        _ => '${(meters / 1000).round()}k',
      };

  static String _clock(Duration d) {
    final s = d.inSeconds;
    final h = s ~/ 3600, m = s % 3600 ~/ 60, sec = s % 60;
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    return '${h > 0 ? '$h:' : ''}$mm:${sec.toString().padLeft(2, '0')}';
  }
}

Map<String, Object?> _fitnessJson(CurrentFitness f) => {
      if (f.vdot != null) 'vdot': f.vdot,
      if (f.mas != null) 'mas': f.mas,
      if (f.lthr != null) 'lthr': f.lthr,
    };
