import 'package:test/test.dart';
import 'package:training_core/training_core.dart';

import 'synthetic_samples.dart';

void main() {
  group('time trials', () {
    // 15 min warm-up, 3 km at 4.5 m/s, 5 min cool-down.
    final parts = [
      part(900, 3.0, 130),
      part(667, 4.5, 178),
      part(300, 2.8, 140)
    ];

    for (final withDistance in [true, false]) {
      test('3k from the ${withDistance ? 'distance' : 'speed'} stream', () {
        final r = TestEvaluator.evaluate(
          TestType.timeTrial3k,
          synth(parts, distance: withDistance),
        )!;
        expect(r.distanceM, 3000);
        expect(r.startSecond, closeTo(900, 1));
        expect(r.duration.inSeconds, closeTo(3000 / 4.5, 1.5));
        final expected = Vdot.fromPerformance(
          RunPerformance(meters: 3000, time: const Duration(seconds: 667)),
        );
        expect(r.vdot, closeTo(expected, 0.15));
        expect(r.avgHr, closeTo(178, 1));
      });
    }

    test('5k picks the best 5 km inside a longer run', () {
      final r = TestEvaluator.evaluate(
        TestType.timeTrial5k,
        synth([part(600, 3.0), part(1100, 4.55, 180), part(600, 3.0)]),
      )!;
      expect(r.distanceM, 5000);
      expect(r.startSecond, closeTo(600, 1));
      expect(
          r.vdot,
          closeTo(
            Vdot.fromPerformance(
              RunPerformance(
                  meters: 5000,
                  time: Duration(milliseconds: (5000 / 4.55 * 1000).round())),
            ),
            0.15,
          ));
    });

    test('too short a recording gives no result', () {
      expect(
        TestEvaluator.evaluate(
          TestType.timeTrial5k,
          synth([part(900, 3.0), part(400, 4.5)]),
        ),
        isNull,
      );
    });

    test('a pause inside the effort invalidates it', () {
      final samples = [
        ...synth([part(400, 4.5)]),
        // 5 minute dropout in the middle.
        for (final s in synth([part(400, 4.5)]).skip(1))
          Sample(
            second: s.second + 700,
            speed: s.speed,
            distance: s.distance! + 1800,
          ),
      ];
      expect(TestEvaluator.evaluate(TestType.timeTrial3k, samples), isNull);
    });
  });

  test('half-Cooper: distance of the best 6 minutes gives MAS', () {
    final r = TestEvaluator.evaluate(
      TestType.halfCooper,
      synth([part(900, 3.0, 130), part(360, 4.8, 185), part(300, 2.5, 150)]),
    )!;
    expect(r.distanceM, closeTo(1728, 5));
    expect(r.masMps, closeTo(4.8, 0.02));
    expect(r.vdot, isNull);
  });

  group('Friel 30 min', () {
    final samples = synth([
      part(900, 3.0, 125),
      part(600, 3.6, 158),
      part(1200, 3.6, 168),
      part(300, 2.5, 140),
    ]);

    test('LTHR is the average HR of the last 20 minutes', () {
      final r = TestEvaluator.evaluate(TestType.friel30, samples)!;
      expect(r.startSecond, closeTo(900, 1));
      expect(r.lthr, closeTo(168, 0.5));
      expect(r.avgHr, closeTo(164.7, 0.5));
    });

    test('needs heart rate', () {
      final noHr = synth([part(900, 3.0), part(1800, 3.6)]);
      expect(TestEvaluator.evaluate(TestType.friel30, noHr), isNull);
    });
  });

  group('detectHardEfforts', () {
    final race =
        synth([part(900, 3.0, 125), part(1136, 4.4, 177), part(600, 2.5, 120)]);

    test('finds a steady 5k race at high HR and drops the overlapping 3k', () {
      final found = TestEvaluator.detectHardEfforts(race, maxHr: 187);
      expect(found, hasLength(1));
      final e = found.single;
      expect(e.distanceM, 5000);
      expect(e.startSecond, closeTo(900, 1));
      expect(e.hrFractionOfMax, closeTo(177 / 187, 0.01));
      expect(
        e.vdot,
        closeTo(Vdot.fromPerformance(e.performance), 1e-9),
      );
      expect(
          e.vdot,
          closeTo(
            Vdot.fromPerformance(RunPerformance(
                meters: 5000, time: const Duration(seconds: 1136))),
            0.2,
          ));
    });

    test('keeps the longest plausible distance', () {
      final tenK = synth(
          [part(600, 3.0, 125), part(2400, 4.17, 172), part(300, 2.5, 120)]);
      final found = TestEvaluator.detectHardEfforts(tenK, maxHr: 187);
      expect(found.map((e) => e.distanceM), [10000]);
    });

    test('an easy run at low HR is not a race', () {
      final easy = synth([part(3600, 3.0, 140)]);
      expect(TestEvaluator.detectHardEfforts(easy, maxHr: 187), isEmpty);
    });

    test('without max HR steady pacing alone decides', () {
      expect(TestEvaluator.detectHardEfforts(race), isNotEmpty);
    });

    test('intervals are not a race even if the average is high', () {
      final intervals = synth([
        part(600, 3.0, 130),
        for (var i = 0; i < 6; i++) ...[
          part(180, 5.0, 178),
          part(120, 2.5, 150)
        ],
      ]);
      expect(TestEvaluator.detectHardEfforts(intervals, maxHr: 187), isEmpty);
    });

    test('a fading, uneven effort is rejected', () {
      final uneven = synth([
        part(200, 5.5, 180),
        part(200, 4.5, 178),
        part(200, 3.5, 172),
        part(900, 2.8, 150),
      ]);
      expect(TestEvaluator.detectHardEfforts(uneven, maxHr: 187), isEmpty);
    });
  });
}
