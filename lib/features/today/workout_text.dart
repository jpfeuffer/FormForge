import 'package:training_core/training_core.dart';

import '../adaptation/verdict_style.dart';

typedef WorkoutLine = ({int depth, String text});

/// One line per step with targets resolved against [profile] when known.
List<WorkoutLine> describeWorkout(Workout workout, PaceProfile? profile) {
  final lines = <WorkoutLine>[];
  void add(WorkoutElement e, int depth) {
    switch (e) {
      case WorkoutStep():
        lines.add((depth: depth, text: _step(e, profile)));
      case RepeatBlock(:final times, :final elements):
        lines.add((depth: depth, text: '$times ×'));
        for (final child in elements) {
          add(child, depth + 1);
        }
    }
  }

  for (final e in workout.elements) {
    add(e, 0);
  }
  return lines;
}

String _step(WorkoutStep s, PaceProfile? profile) {
  final end = switch (s.end) {
    TimeEnd(:final duration) =>
      duration.inSeconds % 60 == 0
          ? '${duration.inMinutes} min'
          : '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}',
    DistanceEnd(:final meters) =>
      meters >= 1000 && meters % 1000 == 0
          ? '${(meters / 1000).round()} km'
          : '${meters.round()} m',
    LapButtonEnd() => 'until lap press',
  };
  final target = switch (s.target) {
    SpeedTarget(:final zone) => paceRange(zone),
    HeartRateTarget(:final zone) =>
      '${zone.lower.round()}–${zone.upper.round()} bpm',
    IntensityTarget(:final intensity) =>
      profile == null
          ? intensity.name
          : '${intensity.name} ${paceRange(profile.speedFor(intensity))}',
    NoTarget() => null,
  };
  return '${s.kind.name} $end${target == null ? '' : ' @ $target'}';
}
