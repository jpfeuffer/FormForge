import 'package:training_core/training_core.dart';

/// Strength block settings, shared by the editor and the add-strength dialog.
final class StrengthSpec {
  StrengthSpec({
    Set<FocusArea>? focusAreas,
    this.minutes = 30,
    this.rpe = 6,
    this.style = StrengthStyle.calisthenics,
    this.placement = StrengthPlacement.during,
  }) : focusAreas = focusAreas ?? {FocusArea.runningStrength, FocusArea.core};

  final Set<FocusArea> focusAreas;
  int minutes;
  int rpe;
  StrengthStyle style;
  StrengthPlacement placement;

  StrengthSession get session => StrengthSession(
    focusAreas: FocusArea.values.where(focusAreas.contains).toList(),
    duration: Duration(minutes: minutes),
    rpe: rpe,
    style: style,
  );
}

/// Form model for manually created workouts; builds a training_core [Workout].
final class WorkoutSpec {
  WorkoutSpec(this.kind) {
    applyKindDefaults();
  }

  static const kinds = [
    SessionKind.easy,
    SessionKind.recovery,
    SessionKind.long,
    SessionKind.threshold,
    SessionKind.interval,
    SessionKind.repetition,
    SessionKind.marathonPace,
    SessionKind.racePace,
    SessionKind.strength,
    SessionKind.combined,
    SessionKind.test,
  ];

  SessionKind kind;
  int runMinutes = 45;
  Intensity intensity = Intensity.easy;

  int warmupMinutes = 10;
  int cooldownMinutes = 10;
  int reps = 4;
  bool byDistance = true;

  /// Metres when [byDistance], else minutes.
  int repSize = 400;
  bool recoveryByDistance = false;
  int recoverySeconds = 90;
  int recoveryMeters = 200;
  Intensity recoveryIntensity = Intensity.recovery;
  TestType testType = TestType.timeTrial5k;
  final strength = StrengthSpec();

  bool get isQuality => const {
    SessionKind.threshold,
    SessionKind.interval,
    SessionKind.repetition,
    SessionKind.marathonPace,
    SessionKind.racePace,
  }.contains(kind);

  bool get isSteady => const {
    SessionKind.easy,
    SessionKind.recovery,
    SessionKind.long,
  }.contains(kind);

  void applyKindDefaults() {
    switch (kind) {
      case SessionKind.recovery:
        runMinutes = 30;
        intensity = Intensity.recovery;
      case SessionKind.long:
        runMinutes = 90;
        intensity = Intensity.easy;
      case SessionKind.threshold:
        _quality(3, false, 10, 120, Intensity.threshold);
      case SessionKind.interval:
        _quality(5, true, 800, 120, Intensity.interval);
      case SessionKind.repetition:
        _quality(8, true, 200, 90, Intensity.repetition);
        recoveryByDistance = true;
        recoveryMeters = 200;
      case SessionKind.marathonPace:
        _quality(2, false, 15, 180, Intensity.marathon);
        recoveryIntensity = Intensity.easy;
      case SessionKind.racePace:
        _quality(4, true, 1000, 120, Intensity.racePace);
      case SessionKind.combined:
        runMinutes = 45;
        intensity = Intensity.easy;
      default:
        runMinutes = 45;
        intensity = Intensity.easy;
    }
  }

  void _quality(
    int reps,
    bool byDistance,
    int size,
    int recovery,
    Intensity i,
  ) {
    this.reps = reps;
    this.byDistance = byDistance;
    repSize = size;
    recoverySeconds = recovery;
    recoveryByDistance = false;
    recoveryIntensity = Intensity.recovery;
    intensity = i;
  }

  /// Workout title derived from the settings.
  String get autoTitle => switch (kind) {
    SessionKind.easy => 'Easy run',
    SessionKind.recovery => 'Recovery run',
    SessionKind.long => 'Long run',
    SessionKind.threshold ||
    SessionKind.interval ||
    SessionKind.repetition ||
    SessionKind.marathonPace ||
    SessionKind.racePace =>
      '$reps × ${byDistance ? '$repSize m' : '$repSize min'} ${intensity.name}',
    SessionKind.strength => 'Strength (${strength.style.name})',
    SessionKind.combined =>
      '${intensity == Intensity.recovery ? 'Recovery' : 'Easy'} run + ${strength.style.name}',
    _ => kind.name,
  };

  StrengthSession? get strengthSession =>
      kind == SessionKind.strength || kind == SessionKind.combined
      ? strength.session
      : null;

  Workout build(PaceProfile profile, {String? title}) {
    final w = _build(profile);
    return title == null || title.isEmpty || title == w.title
        ? w
        : Workout(
            sport: w.sport,
            title: title,
            elements: w.elements,
            focusAreas: w.focusAreas,
            notes: w.notes,
            test: w.test,
          );
  }

  Workout _build(PaceProfile profile) {
    WorkoutStep timed(StepKind k, Duration d, Intensity i) =>
        WorkoutStep(kind: k, end: TimeEnd(d), target: IntensityTarget(i));
    switch (kind) {
      case SessionKind.strength:
        return strength.session.toWorkout(title: autoTitle);
      case SessionKind.combined:
        return strength.session.combineWithRun(
          Duration(minutes: runMinutes),
          placement: strength.placement,
          intensity: intensity,
          title: autoTitle,
        );
      case SessionKind.test:
        return SessionTemplates.test(testType, profile);
      case SessionKind.threshold ||
          SessionKind.interval ||
          SessionKind.repetition ||
          SessionKind.marathonPace ||
          SessionKind.racePace:
        return Workout(
          sport: Sport.run,
          title: autoTitle,
          elements: [
            if (warmupMinutes > 0)
              timed(
                StepKind.warmup,
                Duration(minutes: warmupMinutes),
                Intensity.easy,
              ),
            RepeatBlock(
              times: reps,
              elements: [
                WorkoutStep(
                  kind: StepKind.active,
                  end: byDistance
                      ? DistanceEnd(repSize.toDouble())
                      : TimeEnd(Duration(minutes: repSize)),
                  target: IntensityTarget(intensity),
                ),
                if (recoveryByDistance ? recoveryMeters > 0 : recoverySeconds > 0)
                  WorkoutStep(
                    kind: StepKind.recovery,
                    end: recoveryByDistance
                        ? DistanceEnd(recoveryMeters.toDouble())
                        : TimeEnd(Duration(seconds: recoverySeconds)),
                    target: IntensityTarget(recoveryIntensity),
                  ),
              ],
            ),
            if (cooldownMinutes > 0)
              timed(
                StepKind.cooldown,
                Duration(minutes: cooldownMinutes),
                Intensity.easy,
              ),
          ],
        );
      default:
        return Workout(
          sport: Sport.run,
          title: autoTitle,
          elements: [
            timed(StepKind.active, Duration(minutes: runMinutes), intensity),
          ],
        );
    }
  }

  /// Reconstructs a spec from a stored workout; null if its structure is not
  /// one this form can produce.
  static WorkoutSpec? tryParse(
    SessionKind kind,
    Workout w,
    StrengthSession? strength,
  ) {
    final spec = WorkoutSpec(kind);
    final steps = w.elements;
    switch (kind) {
      case SessionKind.easy || SessionKind.recovery || SessionKind.long:
        if (steps
            case [
              WorkoutStep(
                end: TimeEnd(:final duration),
                target: IntensityTarget(:final intensity),
              ),
            ]
            when w.sport == Sport.run) {
          spec
            ..runMinutes = duration.inMinutes
            ..intensity = intensity;
          return spec;
        }
      case SessionKind.threshold ||
          SessionKind.interval ||
          SessionKind.repetition ||
          SessionKind.marathonPace ||
          SessionKind.racePace:
        int minutes(Duration d) => (d.inSeconds / 60).round();
        var rest = steps;
        if (rest.firstOrNull case WorkoutStep(
          kind: StepKind.warmup,
          end: TimeEnd(:final duration),
        )) {
          spec.warmupMinutes = minutes(duration);
          rest = rest.sublist(1);
        } else {
          spec.warmupMinutes = 0;
        }
        if (rest.lastOrNull case WorkoutStep(
          kind: StepKind.cooldown,
          end: TimeEnd(:final duration),
        )) {
          spec.cooldownMinutes = minutes(duration);
          rest = rest.sublist(0, rest.length - 1);
        } else {
          spec.cooldownMinutes = 0;
        }
        if (rest case [RepeatBlock(:final times, :final elements)]
            when elements.isNotEmpty) {
          if (elements.first case WorkoutStep(
            kind: StepKind.active,
            :final end,
            target: IntensityTarget(:final intensity),
          )) {
            spec
              ..reps = times
              ..intensity = intensity;
            switch (end) {
              case DistanceEnd(:final meters):
                spec
                  ..byDistance = true
                  ..repSize = meters.round();
              case TimeEnd(:final duration)
                  when duration.inSeconds % 60 == 0:
                spec
                  ..byDistance = false
                  ..repSize = duration.inMinutes;
              case TimeEnd() || LapButtonEnd():
                return null;
            }
            switch (elements.skip(1).toList()) {
              case []:
                spec.recoverySeconds = 0;
              case [
                WorkoutStep(kind: StepKind.recovery, :final end, :final target),
              ]:
                if (target case IntensityTarget(:final intensity)) {
                  spec.recoveryIntensity = intensity;
                }
                switch (end) {
                  case TimeEnd(:final duration):
                    spec
                      ..recoveryByDistance = false
                      ..recoverySeconds = duration.inSeconds;
                  case DistanceEnd(:final meters):
                    spec
                      ..recoveryByDistance = true
                      ..recoveryMeters = meters.round();
                  case LapButtonEnd():
                    return null;
                }
              default:
                return null;
            }
            return spec;
          }
        }
      case SessionKind.strength:
        if (strength != null && w.sport == Sport.strength) {
          return spec.._applyStrength(strength);
        }
      case SessionKind.combined:
        if (strength == null || w.sport != Sport.combined) return null;
        final runs = [
          for (final s in w.steps)
            if (s.kind != StepKind.strength) s,
        ];
        if (runs.any(
          (s) => s.end is! TimeEnd || s.target is! IntensityTarget,
        )) {
          return null;
        }
        final firstIsStrength = w.steps.first.kind == StepKind.strength;
        final lastIsStrength = w.steps.last.kind == StepKind.strength;
        spec
          .._applyStrength(strength)
          ..strength.placement = firstIsStrength
              ? StrengthPlacement.before
              : lastIsStrength
              ? StrengthPlacement.after
              : StrengthPlacement.during
          ..runMinutes =
              runs.fold<int>(
                0,
                (a, s) => a + (s.end as TimeEnd).duration.inSeconds,
              ) ~/
              60
          ..intensity = (runs.first.target as IntensityTarget).intensity;
        return spec;
      case SessionKind.test:
        if (w.test case final t?) return spec..testType = t;
      default:
    }
    return null;
  }

  void _applyStrength(StrengthSession s) {
    strength
      ..focusAreas.clear()
      ..focusAreas.addAll(s.focusAreas)
      ..minutes = s.duration.inMinutes
      ..rpe = s.rpe
      ..style = s.style;
  }
}
