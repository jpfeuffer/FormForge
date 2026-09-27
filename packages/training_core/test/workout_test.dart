import 'dart:convert';

import 'package:test/test.dart';
import 'package:training_core/training_core.dart';

Workout sampleWorkout() => Workout(
      sport: Sport.run,
      title: '5 × 1000 m',
      notes: 'Track',
      focusAreas: const [FocusArea.core],
      elements: [
        const WorkoutStep(
            kind: StepKind.warmup,
            end: TimeEnd(Duration(minutes: 10)),
            target: IntensityTarget(Intensity.easy)),
        RepeatBlock(times: 5, elements: const [
          WorkoutStep(
              kind: StepKind.active,
              end: DistanceEnd(1000),
              target: IntensityTarget(Intensity.interval),
              note: 'Hard'),
          WorkoutStep(
              kind: StepKind.recovery,
              end: TimeEnd(Duration(minutes: 2)),
              target: HeartRateTarget(Zone('Z1', 100, 130))),
        ]),
        const WorkoutStep(
            kind: StepKind.active,
            end: DistanceEnd(400),
            target: SpeedTarget(Zone('fast', 4.5, 4.7))),
        const WorkoutStep(
            kind: StepKind.strength,
            end: LapButtonEnd(),
            estimate: Duration(minutes: 15),
            note: 'Core'),
        const WorkoutStep(
            kind: StepKind.cooldown, end: TimeEnd(Duration(minutes: 10))),
      ],
    );

void main() {
  final p50 = PaceProfile.fromVdot(50);
  final p40 = PaceProfile.fromVdot(40);

  group('JSON', () {
    test('round-trips through a JSON string', () {
      final w = sampleWorkout();
      final json = w.toJson();
      expect(json['v'], 1);
      final decoded = Workout.fromJson(
          jsonDecode(jsonEncode(json)) as Map<String, Object?>);
      expect(decoded.toJson(), json);
      expect(decoded.flatten().length, w.flatten().length);
    });

    test('round-trips tests and nested repeats', () {
      final w = Workout(
          sport: Sport.run,
          title: 'nested',
          test: TestType.friel30,
          elements: [
            RepeatBlock(times: 2, elements: [
              RepeatBlock(times: 3, elements: const [
                WorkoutStep(
                    kind: StepKind.active, end: TimeEnd(Duration(seconds: 30)))
              ]),
              const WorkoutStep(
                  kind: StepKind.rest, end: TimeEnd(Duration(minutes: 1))),
            ])
          ]);
      final decoded = Workout.fromJson(
          jsonDecode(jsonEncode(w.toJson())) as Map<String, Object?>);
      expect(decoded.toJson(), w.toJson());
      expect(decoded.test, TestType.friel30);
      expect(decoded.flatten().length, 8);
    });

    test('rejects unknown versions and types', () {
      final json = sampleWorkout().toJson()..['v'] = 2;
      expect(() => Workout.fromJson(json), throwsFormatException);
      expect(() => StepEnd.fromJson({'type': 'x'}), throwsFormatException);
    });
  });

  group('estimates', () {
    test('flatten expands repeats', () {
      expect(sampleWorkout().flatten().length, 1 + 10 + 3);
    });

    test('distance steps use the resolved target speed', () {
      final w = sampleWorkout();
      final i = p50.speedFor(Intensity.interval).mid;
      final expected = 600 + 5 * (1000 / i + 120) + 400 / 4.6 + 900 + 600;
      expect(w.estimatedDuration(p50).inMilliseconds / 1000,
          closeTo(expected, 0.01));
      expect(w.estimatedRunDuration(p50),
          w.estimatedDuration(p50) - const Duration(minutes: 15));
    });

    test('re-paces when fitness changes', () {
      final w = sampleWorkout();
      expect(w.estimatedDuration(p40), greaterThan(w.estimatedDuration(p50)));
    });

    test('distance: time steps at planned speed, strength none', () {
      final w = sampleWorkout();
      final easy = p50.speedFor(Intensity.easy).mid;
      final recovery = p50.speedFor(Intensity.recovery).mid;
      final expected =
          600 * easy + 5 * (1000 + 120 * recovery) + 400 + 600 * easy;
      expect(w.estimatedDistance(p50), closeTo(expected, 0.01));
    });

    test('one hour at threshold scores ~100 load', () {
      final w = Workout(sport: Sport.run, title: 'T', elements: const [
        WorkoutStep(
            kind: StepKind.active,
            end: TimeEnd(Duration(hours: 1)),
            target: IntensityTarget(Intensity.threshold))
      ]);
      expect(w.estimatedLoad(p50), closeTo(100, 0.01));
      expect(w.estimatedHardDuration(p50), const Duration(hours: 1));
    });

    test('easy running is not hard', () {
      final w = SessionTemplates.easy(const Duration(minutes: 40));
      expect(w.estimatedHardDuration(p50), Duration.zero);
      expect(w.estimatedLoad(p50), inInclusiveRange(30, 50));
    });

    test('all-out distance step uses its estimate', () {
      final w = SessionTemplates.test(TestType.timeTrial5k, p50);
      final tt = w.flatten()[1];
      expect(tt.estimatedDuration(p50), Vdot.predictTime(50, 5000));
      expect(w.estimatedHardDuration(p50), tt.estimatedDuration(p50));
    });
  });

  group('PaceProfile', () {
    test('zones are ordered by speed', () {
      for (final p in [p50, PaceProfile.fromMas(5)]) {
        final mids = [
          for (final i in [
            Intensity.recovery,
            Intensity.easy,
            Intensity.marathon,
            Intensity.threshold,
            Intensity.interval,
            Intensity.repetition,
          ])
            p.speedFor(i).mid
        ];
        for (var k = 1; k < mids.length; k++) {
          expect(mids[k], greaterThan(mids[k - 1]));
        }
      }
    });

    test('race pace from goal speed, distance prediction or marathon', () {
      expect(
          PaceProfile.fromVdot(50, raceSpeed: 4)
              .speedFor(Intensity.racePace)
              .mid,
          closeTo(4, 1e-9));
      final predicted = 10000 / Vdot.predictTime(50, 10000).inSeconds;
      expect(
          PaceProfile.fromVdot(50, raceMeters: 10000)
              .speedFor(Intensity.racePace)
              .mid,
          closeTo(predicted, 1e-3));
      expect(p50.speedFor(Intensity.racePace).mid,
          closeTo(p50.speedFor(Intensity.marathon).mid, 1e-9));
    });

    test('MAS fallback: interval zone centred on MAS', () {
      final p = PaceProfile.fromMas(5);
      expect(p.speedFor(Intensity.interval).mid, closeTo(5, 1e-9));
      expect(p.vdotEquivalent, closeTo(Vdot.oxygenCost(300), 1e-9));
    });

    test('fromFitness prefers VDOT and needs one input', () {
      expect(PaceProfile.fromFitness(vdot: 50, mas: 3).vdotEquivalent, 50);
      expect(() => PaceProfile.fromFitness(), throwsArgumentError);
    });

    test('HR zones from LTHR', () {
      final p = PaceProfile.fromVdot(50, lthr: 170);
      expect(p.heartRateFor(Intensity.threshold)!.upper, closeTo(170, 1e-9));
      expect(p50.heartRateFor(Intensity.easy), isNull);
    });
  });
}
