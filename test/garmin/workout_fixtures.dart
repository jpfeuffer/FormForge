import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:training_core/training_core.dart';

/// Fixed paces (m/s) so goldens don't depend on the VDOT formulas.
PaceProfile testProfile({double scale = 1}) => PaceProfile({
  Intensity.recovery: Zone('Recovery', 2.0 * scale, 2.4 * scale),
  Intensity.easy: Zone('Easy', 2.5 * scale, 3.0 * scale),
  Intensity.marathon: Zone('Marathon', 3.2 * scale, 3.4 * scale),
  Intensity.threshold: Zone('Threshold', 3.6 * scale, 3.8 * scale),
  Intensity.interval: Zone('Interval', 4.0 * scale, 4.3 * scale),
  Intensity.repetition: Zone('Repetition', 4.5 * scale, 4.8 * scale),
  Intensity.racePace: Zone('Race', 3.3 * scale, 3.4 * scale),
}, vdotEquivalent: 50);

WorkoutStep _step(
  StepKind kind,
  StepEnd end, [
  Target target = const NoTarget(),
  String? note,
]) => WorkoutStep(kind: kind, end: end, target: target, note: note);

TimeEnd _min(int m) => TimeEnd(Duration(minutes: m));

Workout easyRun() => Workout(
  sport: Sport.run,
  title: 'Easy run',
  notes: 'Keep it conversational',
  elements: [
    _step(StepKind.warmup, _min(5), const IntensityTarget(Intensity.recovery)),
    _step(StepKind.active, _min(30), const IntensityTarget(Intensity.easy)),
    _step(StepKind.cooldown, _min(5)),
  ],
);

Workout thresholdDistance() => Workout(
  sport: Sport.run,
  title: 'Threshold 4x1k',
  elements: [
    _step(
      StepKind.warmup,
      const DistanceEnd(2000),
      const IntensityTarget(Intensity.easy),
    ),
    RepeatBlock(
      times: 4,
      elements: [
        _step(
          StepKind.active,
          const DistanceEnd(1000),
          const IntensityTarget(Intensity.threshold),
          'Controlled',
        ),
        _step(StepKind.recovery, _min(2), const NoTarget()),
      ],
    ),
    _step(StepKind.cooldown, const DistanceEnd(1500)),
  ],
);

Workout nestedIntervals() => Workout(
  sport: Sport.run,
  title: 'Pyramid 2x(3x400)',
  elements: [
    _step(StepKind.warmup, _min(10), const IntensityTarget(Intensity.easy)),
    RepeatBlock(
      times: 2,
      elements: [
        RepeatBlock(
          times: 3,
          elements: [
            _step(
              StepKind.active,
              const DistanceEnd(400),
              const IntensityTarget(Intensity.interval),
            ),
            _step(StepKind.recovery, const TimeEnd(Duration(seconds: 90))),
          ],
        ),
        _step(StepKind.rest, _min(3)),
      ],
    ),
    _step(StepKind.cooldown, _min(10)),
  ],
);

Workout heartRateRun() => Workout(
  sport: Sport.run,
  title: 'HR run',
  elements: [
    _step(
      StepKind.warmup,
      _min(10),
      const HeartRateTarget(Zone('Z2', 130, 145)),
    ),
    _step(
      StepKind.active,
      _min(40),
      const HeartRateTarget(Zone('Z3', 140.4, 152.6)),
    ),
    _step(StepKind.cooldown, _min(5), const SpeedTarget(Zone('Jog', 2.4, 2.8))),
  ],
);

Workout combinedSession() => Workout(
  sport: Sport.combined,
  title: 'Run + core',
  elements: [
    _step(StepKind.warmup, _min(10), const IntensityTarget(Intensity.easy)),
    _step(StepKind.active, _min(20), const IntensityTarget(Intensity.easy)),
    WorkoutStep(
      kind: StepKind.strength,
      end: const LapButtonEnd(),
      note: 'Core circuit, 15 min',
      estimate: const Duration(minutes: 15),
    ),
    _step(StepKind.cooldown, _min(5)),
  ],
);

Workout strengthOnly() => Workout(
  sport: Sport.strength,
  title: 'Strength A',
  elements: [
    const WorkoutStep(
      kind: StepKind.strength,
      end: LapButtonEnd(),
      estimate: Duration(minutes: 30),
    ),
  ],
);

String workoutJsonString(Workout w) => jsonEncode(w.toJson());

/// Compares to `test/garmin/golden/<name>.json`; writes it if missing
/// or when `UPDATE_GOLDENS=1`.
void expectGolden(String name, Object? json) {
  final file = File('test/garmin/golden/$name.json');
  final actual = '${const JsonEncoder.withIndent('  ').convert(json)}\n';
  if (!file.existsSync() || Platform.environment['UPDATE_GOLDENS'] == '1') {
    file.createSync(recursive: true);
    file.writeAsStringSync(actual);
  }
  expect(actual, file.readAsStringSync().replaceAll('\r\n', '\n'));
}
