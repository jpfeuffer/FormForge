import '../strength.dart';
import '../workout.dart';
import 'feasibility.dart';
import 'request.dart';
import 'rules.dart';

enum SessionKind {
  easy,
  recovery,
  long,
  threshold,
  interval,
  repetition,
  marathonPace,
  racePace,
  test,
  strength,
  combined,
  race;

  bool get isQuality => const {
        threshold,
        interval,
        repetition,
        marathonPace,
        racePace,
        test,
      }.contains(this);
}

final class PlannedSession {
  const PlannedSession({
    required this.date,
    required this.kind,
    required this.workout,
    this.isKey = false,
    this.strength,
  });

  final DateTime date;
  final SessionKind kind;
  final Workout workout;

  /// Hard/key session (quality, long run, test, race).
  final bool isKey;

  /// Set for strength and combined sessions.
  final StrengthSession? strength;
}

final class PlanWeek {
  PlanWeek({
    required this.index,
    required this.startDate,
    required this.phase,
    required this.isRecovery,
    required this.targetVolume,
    required List<PlannedSession> sessions,
  }) : sessions = List.unmodifiable(sessions);

  final int index;
  final DateTime startDate;
  final Phase phase;
  final bool isRecovery;

  /// Planned running time (the race itself excluded).
  final Duration targetVolume;
  final List<PlannedSession> sessions;

  /// Estimated running time of all sessions except the race.
  Duration runningVolume(PaceProfile profile) =>
      sessions.where((s) => s.kind != SessionKind.race).fold(
          Duration.zero, (a, s) => a + s.workout.estimatedRunDuration(profile));
}

final class PlanWarning {
  const PlanWarning(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

final class TrainingPlan {
  TrainingPlan({
    required this.request,
    required this.profile,
    required this.feasibility,
    required List<PlanWeek> weeks,
    required List<PlanWarning> warnings,
  })  : weeks = List.unmodifiable(weeks),
        warnings = List.unmodifiable(warnings);

  final PlanRequest request;

  /// Profile the plan was sized with; re-resolve targets with a newer one.
  final PaceProfile profile;
  final Feasibility feasibility;
  final List<PlanWeek> weeks;
  final List<PlanWarning> warnings;

  RaceCategory get category => RaceCategory.of(request.goalMeters);

  Iterable<PlannedSession> get sessions => weeks.expand((w) => w.sessions);
}
