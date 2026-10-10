import 'package:training_core/training_core.dart';

enum BandKind { speed, heartRate }

/// A step target with symbolic intensities resolved: m/s or bpm.
typedef ResolvedTarget = ({BandKind kind, double low, double high});

/// `null` means "no target", also for intensities without a [PaceProfile].
ResolvedTarget? resolveTarget(Target target, PaceProfile? profile) =>
    switch (target) {
      NoTarget() => null,
      SpeedTarget(:final zone) => (
        kind: BandKind.speed,
        low: zone.lower,
        high: zone.upper,
      ),
      HeartRateTarget(:final zone) => (
        kind: BandKind.heartRate,
        low: zone.lower,
        high: zone.upper,
      ),
      IntensityTarget(:final intensity) when profile != null => (
        kind: BandKind.speed,
        low: profile.speedFor(intensity).lower,
        high: profile.speedFor(intensity).upper,
      ),
      IntensityTarget() => null,
    };

/// Garmin devices don't support repeats inside repeats; inner ones are unrolled.
List<WorkoutElement> flattenNestedRepeats(List<WorkoutElement> elements) {
  final result = <WorkoutElement>[];
  for (final e in elements) {
    switch (e) {
      case WorkoutStep():
        result.add(e);
      case RepeatBlock():
        final body = _unroll(e.elements);
        if (body.isNotEmpty) {
          result.add(RepeatBlock(times: e.times, elements: body));
        }
    }
  }
  return result;
}

List<WorkoutStep> _unroll(List<WorkoutElement> elements) => [
  for (final e in elements)
    ...switch (e) {
      WorkoutStep() => [e],
      RepeatBlock() => [
        for (var i = 0; i < e.times; i++) ..._unroll(e.elements),
      ],
    },
];
