import 'dart:math';

import '../vdot.dart';
import '../workout.dart';
import 'plan.dart';
import 'rules.dart';

final class _RepSpec {
  const _RepSpec(this.title, this.intensity, this.work, this.rest, this.minReps,
      this.maxReps, this.capFraction, this.capMinutes,
      {this.restIntensity = Intensity.recovery});

  final String title;
  final Intensity intensity;
  final StepEnd work;
  final StepEnd rest;
  final Intensity restIntensity;
  final int minReps;
  final int maxReps;

  /// Max hard time as a fraction of weekly volume (Daniels-style limits).
  final double capFraction;
  final int capMinutes;
}

/// Session building blocks; all targets are symbolic [IntensityTarget]s.
abstract final class SessionTemplates {
  static const minWarmup = Duration(minutes: 10);
  static const minCooldown = Duration(minutes: 5);

  /// Quality session kinds in priority order for a phase.
  static List<SessionKind> qualityOrder(RaceCategory c, Phase p) => switch (p) {
        Phase.base => c.isShort
            ? const [SessionKind.repetition, SessionKind.threshold]
            : const [SessionKind.threshold, SessionKind.repetition],
        Phase.build => switch (c) {
            RaceCategory.fiveK || RaceCategory.tenK => const [
                SessionKind.interval,
                SessionKind.threshold,
                SessionKind.repetition
              ],
            RaceCategory.half => const [
                SessionKind.threshold,
                SessionKind.interval,
                SessionKind.racePace
              ],
            RaceCategory.marathon => const [
                SessionKind.threshold,
                SessionKind.marathonPace,
                SessionKind.interval
              ],
            _ => const [
                SessionKind.threshold,
                SessionKind.marathonPace,
                SessionKind.repetition
              ],
          },
        Phase.peak => switch (c) {
            RaceCategory.fiveK || RaceCategory.tenK => const [
                SessionKind.racePace,
                SessionKind.interval,
                SessionKind.threshold
              ],
            RaceCategory.half => const [
                SessionKind.racePace,
                SessionKind.threshold,
                SessionKind.interval
              ],
            RaceCategory.marathon => const [
                SessionKind.marathonPace,
                SessionKind.threshold,
                SessionKind.interval
              ],
            _ => const [SessionKind.threshold, SessionKind.marathonPace],
          },
        Phase.taper => switch (c) {
            RaceCategory.marathon => const [SessionKind.marathonPace],
            RaceCategory.ultra50 || RaceCategory.ultra100 => const [
                SessionKind.threshold
              ],
            _ => const [SessionKind.racePace],
          },
      };

  static Workout easy(Duration d,
      {Intensity intensity = Intensity.easy,
      bool strides = false,
      String? title,
      String? note}) {
    const strideBlock = Duration(minutes: 5);
    final withStrides = strides && d >= const Duration(minutes: 25);
    return Workout(
      sport: Sport.run,
      title: title ??
          (intensity == Intensity.recovery
              ? 'Recovery run'
              : withStrides
                  ? 'Easy run + strides'
                  : 'Easy run'),
      elements: [
        WorkoutStep(
            kind: StepKind.active,
            end: TimeEnd(withStrides ? d - strideBlock : d),
            target: IntensityTarget(intensity),
            note: note),
        if (withStrides)
          RepeatBlock(times: 6, elements: const [
            WorkoutStep(
                kind: StepKind.active,
                end: TimeEnd(Duration(seconds: 20)),
                target: IntensityTarget(Intensity.repetition),
                note: 'Stride: fast but relaxed'),
            WorkoutStep(
                kind: StepKind.recovery,
                end: TimeEnd(Duration(seconds: 30)),
                target: IntensityTarget(Intensity.recovery)),
          ]),
      ],
    );
  }

  static Workout long(Duration d,
      {Duration finish = Duration.zero,
      Intensity finishIntensity = Intensity.marathon,
      bool timeOnFeet = false}) {
    final hasFinish = finish > Duration.zero;
    return Workout(
      sport: Sport.run,
      title: hasFinish
          ? 'Long run with ${finishIntensity.name} finish'
          : timeOnFeet
              ? 'Long run (time on feet)'
              : 'Long run',
      elements: [
        WorkoutStep(
            kind: StepKind.active,
            end: TimeEnd(d - finish),
            target: const IntensityTarget(Intensity.easy),
            note: timeOnFeet
                ? 'Time on feet: walk breaks and race nutrition practice ok'
                : null),
        if (hasFinish)
          WorkoutStep(
              kind: StepKind.active,
              end: TimeEnd(finish),
              target: IntensityTarget(finishIntensity)),
      ],
    );
  }

  /// Interval-style quality session fitting [budget], or null if even the
  /// minimum number of reps does not fit.
  static Workout? quality(
    SessionKind kind, {
    required Duration budget,
    required PaceProfile profile,
    required RaceCategory category,
    required Phase phase,
    required Duration weeklyVolume,
    bool light = false,
  }) {
    final spec = switch (kind) {
      SessionKind.threshold => switch (phase) {
          Phase.base => const _RepSpec(
              'cruise intervals',
              Intensity.threshold,
              TimeEnd(Duration(minutes: 5)),
              TimeEnd(Duration(minutes: 1)),
              2,
              6,
              0.10,
              12),
          Phase.build => const _RepSpec(
              'cruise intervals',
              Intensity.threshold,
              TimeEnd(Duration(minutes: 8)),
              TimeEnd(Duration(minutes: 2)),
              2,
              5,
              0.10,
              12),
          _ => const _RepSpec(
              'cruise intervals',
              Intensity.threshold,
              TimeEnd(Duration(minutes: 10)),
              TimeEnd(Duration(minutes: 2)),
              2,
              4,
              0.10,
              12),
        },
      SessionKind.interval => switch (phase) {
          Phase.base => const _RepSpec(
              'VO2max intervals',
              Intensity.interval,
              TimeEnd(Duration(minutes: 2)),
              TimeEnd(Duration(minutes: 2)),
              4,
              8,
              0.08,
              10),
          Phase.build => const _RepSpec(
              'VO2max intervals',
              Intensity.interval,
              TimeEnd(Duration(minutes: 3)),
              TimeEnd(Duration(minutes: 2, seconds: 30)),
              3,
              6,
              0.08,
              10),
          _ => const _RepSpec(
              'VO2max intervals',
              Intensity.interval,
              TimeEnd(Duration(minutes: 4)),
              TimeEnd(Duration(minutes: 3)),
              3,
              5,
              0.08,
              12),
        },
      SessionKind.repetition => phase == Phase.base
          ? const _RepSpec('reps', Intensity.repetition, DistanceEnd(200),
              DistanceEnd(200), 6, 10, 0.05, 5)
          : const _RepSpec('reps', Intensity.repetition, DistanceEnd(400),
              DistanceEnd(400), 3, 8, 0.05, 6),
      SessionKind.marathonPace => _RepSpec(
          'at marathon pace',
          Intensity.marathon,
          TimeEnd(Duration(minutes: phase == Phase.peak ? 20 : 15)),
          const TimeEnd(Duration(minutes: 3)),
          1,
          3,
          0.15,
          20,
          restIntensity: Intensity.easy),
      SessionKind.racePace => switch (category) {
          RaceCategory.fiveK => const _RepSpec(
              'at race pace',
              Intensity.racePace,
              DistanceEnd(1000),
              TimeEnd(Duration(minutes: 2)),
              3,
              6,
              0.10,
              15),
          RaceCategory.tenK || RaceCategory.half => const _RepSpec(
              'at race pace',
              Intensity.racePace,
              DistanceEnd(2000),
              TimeEnd(Duration(minutes: 2, seconds: 30)),
              2,
              5,
              0.15,
              20),
          _ => const _RepSpec(
              'at race pace',
              Intensity.racePace,
              TimeEnd(Duration(minutes: 20)),
              TimeEnd(Duration(minutes: 3)),
              1,
              3,
              0.20,
              20,
              restIntensity: Intensity.easy),
        },
      _ => throw ArgumentError.value(kind, 'kind', 'not a quality kind'),
    };
    return _reps(spec, budget, profile, weeklyVolume, light: light);
  }

  /// Short race-pace touch in race week.
  static Workout? sharpener(
          Duration budget, PaceProfile profile, RaceCategory c) =>
      _reps(
          c.index <= RaceCategory.half.index
              ? const _RepSpec(
                  'race-pace sharpener',
                  Intensity.racePace,
                  TimeEnd(Duration(minutes: 1)),
                  TimeEnd(Duration(minutes: 2)),
                  3,
                  5,
                  0,
                  5)
              : const _RepSpec(
                  'race-pace sharpener',
                  Intensity.racePace,
                  TimeEnd(Duration(minutes: 3)),
                  TimeEnd(Duration(minutes: 2)),
                  2,
                  4,
                  0,
                  12),
          budget,
          profile,
          Duration.zero);

  static Workout test(TestType type, PaceProfile profile) {
    WorkoutStep allOut(StepEnd end, String note, [Duration? estimate]) =>
        WorkoutStep(
            kind: StepKind.active, end: end, note: note, estimate: estimate);
    Duration predicted(double meters) =>
        Vdot.predictTime(profile.vdotEquivalent, meters);
    final (title, main) = switch (type) {
      TestType.timeTrial3k => (
          '3 km time trial',
          [
            allOut(const DistanceEnd(3000), 'All-out 3 km, flat and solo',
                predicted(3000))
          ]
        ),
      TestType.timeTrial5k => (
          '5 km time trial',
          [
            allOut(const DistanceEnd(5000), 'All-out 5 km, flat and solo',
                predicted(5000))
          ]
        ),
      TestType.halfCooper => (
          'Half-Cooper test (6 min)',
          [
            allOut(const TimeEnd(Duration(minutes: 6)),
                'Max distance in 6 min; MAS = meters / 360')
          ]
        ),
      TestType.friel30 => (
          '30-min LTHR test (Friel)',
          [
            allOut(const TimeEnd(Duration(minutes: 10)),
                'All-out 30-min solo effort, pace evenly'),
            allOut(const TimeEnd(Duration(minutes: 20)),
                'Keep pushing; average HR of this lap = LTHR'),
          ]
        ),
    };
    return Workout(
      sport: Sport.run,
      title: title,
      test: type,
      elements: [
        const WorkoutStep(
            kind: StepKind.warmup,
            end: TimeEnd(Duration(minutes: 15)),
            target: IntensityTarget(Intensity.easy),
            note: 'Include 3–4 strides'),
        ...main,
        const WorkoutStep(
            kind: StepKind.cooldown,
            end: TimeEnd(Duration(minutes: 10)),
            target: IntensityTarget(Intensity.easy)),
      ],
    );
  }

  static Workout race(double meters) {
    final c = RaceCategory.of(meters);
    return Workout(
      sport: Sport.run,
      title: 'Race ${_km(meters)}',
      elements: [
        if (c.index <= RaceCategory.half.index)
          WorkoutStep(
              kind: StepKind.warmup,
              end: TimeEnd(Duration(minutes: c.isShort ? 15 : 10)),
              target: const IntensityTarget(Intensity.easy)),
        WorkoutStep(
            kind: StepKind.active,
            end: DistanceEnd(meters),
            target: const IntensityTarget(Intensity.racePace),
            note: 'Race'),
      ],
    );
  }

  static Workout? _reps(
      _RepSpec s, Duration budget, PaceProfile p, Duration weeklyVolume,
      {bool light = false}) {
    final work = WorkoutStep(
        kind: StepKind.active,
        end: s.work,
        target: IntensityTarget(s.intensity));
    final rest = WorkoutStep(
        kind: StepKind.recovery,
        end: s.rest,
        target: IntensityTarget(s.restIntensity));
    final workSec = _sec(work.estimatedDuration(p));
    final cycleSec = workSec + _sec(rest.estimatedDuration(p));
    final capSec = max(
        max(_sec(weeklyVolume) * s.capFraction, s.capMinutes * 60.0) *
            (light ? 0.7 : 1),
        s.minReps * workSec);
    final availSec = _sec(budget) - _sec(minWarmup) - _sec(minCooldown);
    final reps = [
      s.maxReps,
      (capSec / workSec + 1e-9).floor(),
      (availSec / cycleSec).floor(),
    ].reduce(min);
    if (reps < s.minReps) return null;
    final fill = _sec(budget) - reps * cycleSec;
    final warmup = Duration(minutes: (fill * 0.6 / 60).floor());
    final cooldown = Duration(seconds: (fill - _sec(warmup)).floor());
    return Workout(
      sport: Sport.run,
      title: '$reps × ${_label(s.work)} ${s.title}',
      elements: [
        WorkoutStep(
            kind: StepKind.warmup,
            end: TimeEnd(warmup),
            target: const IntensityTarget(Intensity.easy)),
        RepeatBlock(times: reps, elements: [work, rest]),
        WorkoutStep(
            kind: StepKind.cooldown,
            end: TimeEnd(cooldown),
            target: const IntensityTarget(Intensity.easy)),
      ],
    );
  }

  static String _label(StepEnd e) => switch (e) {
        TimeEnd(:final duration) => duration.inSeconds % 60 == 0
            ? '${duration.inMinutes} min'
            : '${duration.inSeconds} s',
        DistanceEnd(:final meters) => '${meters.round()} m',
        LapButtonEnd() => 'lap',
      };

  static String _km(double meters) {
    final km = (meters / 100).round() / 10;
    return '${km == km.roundToDouble() ? km.round() : km} km';
  }
}

double _sec(Duration d) => d.inMicroseconds / Duration.microsecondsPerSecond;
