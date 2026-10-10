import 'workout.dart';

enum FocusArea {
  runningStrength,
  core,
  lowerBody,
  upperPush,
  upperPull,
  plyometrics,
  mobility,
  fullBody,
}

enum StrengthStyle { calisthenics, gym }

/// Where a strength block goes relative to a run in a combined workout.
enum StrengthPlacement { before, during, after }

final class StrengthSession {
  const StrengthSession({
    required this.focusAreas,
    required this.duration,
    required this.rpe,
    this.style = StrengthStyle.calisthenics,
  });

  static const version = 1;

  factory StrengthSession.fromJson(Map<String, Object?> json) {
    final v = json['v'];
    if (v != version) {
      throw FormatException('Unsupported strength session version', v);
    }
    return StrengthSession(
      focusAreas: _focusAreasFromJson(json['focusAreas']),
      duration: Duration(seconds: json['durationS'] as int),
      rpe: json['rpe'] as int,
      style: StrengthStyle.values.byName(json['style'] as String),
    );
  }

  static const _legLoading = {
    FocusArea.lowerBody,
    FocusArea.plyometrics,
    FocusArea.runningStrength,
    FocusArea.fullBody,
  };

  final List<FocusArea> focusAreas;
  final Duration duration;

  /// Session RPE, 1–10.
  final int rpe;
  final StrengthStyle style;

  /// Leg-loading work at RPE ≥ 7, or any full-body gym session.
  bool get isHeavyLowerBody =>
      (rpe >= 7 && focusAreas.any(_legLoading.contains)) ||
      (style == StrengthStyle.gym && focusAreas.contains(FocusArea.fullBody));

  String get description =>
      '${style.name}: ${focusAreas.map((f) => f.name).join(', ')} (RPE $rpe)';

  Map<String, Object?> toJson() => {
        'v': version,
        'focusAreas': [for (final f in focusAreas) f.name],
        'durationS': duration.inSeconds,
        'rpe': rpe,
        'style': style.name,
      };

  WorkoutStep get step => WorkoutStep(
      kind: StepKind.strength,
      end: const LapButtonEnd(),
      estimate: duration,
      note: description);

  StrengthSession copyWith(
          {List<FocusArea>? focusAreas, Duration? duration, int? rpe}) =>
      StrengthSession(
          focusAreas: focusAreas ?? this.focusAreas,
          duration: duration ?? this.duration,
          rpe: rpe ?? this.rpe,
          style: style);

  Workout toWorkout({String? title}) => Workout(
      sport: Sport.strength,
      title: title ?? 'Strength (${style.name})',
      elements: [step],
      focusAreas: focusAreas);

  /// Combines this session with a [run] of total duration: [StrengthPlacement.during]
  /// splits the run in two halves around the strength block (e.g. a calisthenics park
  /// on an easy-run route).
  Workout combineWithRun(Duration run,
      {StrengthPlacement placement = StrengthPlacement.during,
      Intensity intensity = Intensity.easy,
      String? title}) {
    WorkoutStep runStep(Duration d, String note) => WorkoutStep(
        kind: StepKind.active,
        end: TimeEnd(d),
        target: IntensityTarget(intensity),
        note: note);
    final firstHalf = Duration(minutes: (run.inSeconds / 120).round());
    return Workout(
      sport: Sport.combined,
      title: title ?? '${_runTitle(intensity)} + ${style.name}',
      focusAreas: focusAreas,
      elements: switch (placement) {
        StrengthPlacement.before => [step, runStep(run, 'Run')],
        StrengthPlacement.after => [runStep(run, 'Run'), step],
        StrengthPlacement.during => [
            runStep(firstHalf, 'Run to the workout spot'),
            step,
            runStep(run - firstHalf, 'Run back'),
          ],
      },
    );
  }

  static String _runTitle(Intensity i) =>
      i == Intensity.recovery ? 'Recovery run' : 'Easy run';
}

List<FocusArea> _focusAreasFromJson(Object? json) => [
      for (final f in (json as List?) ?? const [])
        FocusArea.values.byName(f as String)
    ];

enum StrengthGoalKind { none, runningSupport, secondaryGoal }

final class StrengthGoal {
  const StrengthGoal({
    required this.kind,
    this.focusAreas = const [],
    this.sessionsPerWeek = 2,
    this.style = StrengthStyle.calisthenics,
    this.sessionDuration = const Duration(minutes: 30),
  });

  const StrengthGoal.none()
      : kind = StrengthGoalKind.none,
        focusAreas = const [],
        sessionsPerWeek = 0,
        style = StrengthStyle.calisthenics,
        sessionDuration = Duration.zero;

  factory StrengthGoal.fromJson(Map<String, Object?> json) => StrengthGoal(
        kind: StrengthGoalKind.values.byName(json['kind'] as String),
        focusAreas: _focusAreasFromJson(json['focusAreas']),
        sessionsPerWeek: json['sessionsPerWeek'] as int,
        style: StrengthStyle.values.byName(json['style'] as String),
        sessionDuration: Duration(seconds: json['sessionDurationS'] as int),
      );

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'focusAreas': [for (final f in focusAreas) f.name],
        'sessionsPerWeek': sessionsPerWeek,
        'style': style.name,
        'sessionDurationS': sessionDuration.inSeconds,
      };

  final StrengthGoalKind kind;

  /// Empty means a default set for [kind].
  final List<FocusArea> focusAreas;
  final int sessionsPerWeek;
  final StrengthStyle style;
  final Duration sessionDuration;

  bool get isActive => kind != StrengthGoalKind.none && sessionsPerWeek > 0;

  List<FocusArea> get effectiveFocusAreas => focusAreas.isNotEmpty
      ? focusAreas
      : switch (kind) {
          StrengthGoalKind.secondaryGoal => const [
              FocusArea.fullBody,
              FocusArea.upperPull,
              FocusArea.upperPush,
              FocusArea.core,
            ],
          _ => const [
              FocusArea.runningStrength,
              FocusArea.core,
              FocusArea.mobility,
            ],
        };
}
