import 'package:test/test.dart';
import 'package:training_core/training_core.dart';

RunPerformance perf(double m, int seconds) =>
    RunPerformance(meters: m, time: Duration(seconds: seconds));

void main() {
  group('Vdot', () {
    test('5K in 20:00 is ~49.8 (Daniels table)', () {
      expect(Vdot.fromPerformance(perf(5000, 1200)), closeTo(49.8, 0.1));
    });

    test('VDOT 50 predicts ~3:10:49 marathon', () {
      final t = Vdot.predictTime(50, 42195).inSeconds;
      expect(t, closeTo(3 * 3600 + 10 * 60 + 49, 90));
    });

    test('predictTime inverts fromPerformance', () {
      final t = Vdot.predictTime(45, 10000);
      expect(Vdot.fromPerformance(RunPerformance(meters: 10000, time: t)),
          closeTo(45, 1e-6));
    });

    test('VDOT 50 threshold pace ~4:15/km', () {
      final t = Vdot.trainingZones(50)[DanielsIntensity.threshold]!;
      expect(Pace.secondsPerKm(t.upper), closeTo(255, 3));
    });

    test('zones get faster with intensity', () {
      final z = Vdot.trainingZones(50);
      expect(z[DanielsIntensity.easy]!.mid,
          lessThan(z[DanielsIntensity.marathon]!.mid));
      expect(z[DanielsIntensity.threshold]!.mid,
          lessThan(z[DanielsIntensity.interval]!.mid));
      expect(z[DanielsIntensity.interval]!.mid,
          lessThan(z[DanielsIntensity.repetition]!.mid));
    });
  });

  group('Riegel', () {
    test('default exponent', () {
      expect(Riegel.predict(perf(5000, 1200), 10000).inSeconds,
          closeTo(2502, 1));
    });

    test('fitExponent round-trips', () {
      final a = perf(5000, 1200);
      final b = RunPerformance(
          meters: 21097.5, time: Riegel.predict(a, 21097.5, exponent: 1.08));
      expect(Riegel.fitExponent(a, b), closeTo(1.08, 1e-6));
    });
  });

  test('critical speed fit recovers CS and D′', () {
    final m = CriticalSpeedModel.fit([perf(920, 180), perf(3080, 720)]);
    expect(m.criticalSpeed, closeTo(4, 1e-9));
    expect(m.dPrime, closeTo(200, 1e-6));
  });

  test('half-Cooper MAS', () {
    expect(Pace.kmh(Mas.fromHalfCooper(1500)), closeTo(15, 1e-9));
  });

  group('HeartRate', () {
    test('Friel LTHR uses last 20 minutes', () {
      final samples = [
        for (var s = 0; s < 1800; s += 10) (second: s, bpm: s < 600 ? 150 : 170)
      ];
      expect(HeartRate.lthrFromFrielTest(samples), 170);
    });

    test('Karvonen top zone ends at max', () {
      expect(HeartRate.karvonenZones(rest: 50, max: 190).last.upper, 190);
    });
  });

  group('Load', () {
    test('one hour at LTHR is 100 hrTSS', () {
      expect(
          Load.hrTss(
              duration: const Duration(hours: 1),
              avgHr: 170,
              restHr: 50,
              maxHr: 195,
              lthr: 170),
          closeTo(100, 1e-9));
    });

    test('CTL after 42 days of constant 100', () {
      final from = DateTime.utc(2026, 1, 1);
      final loads = {
        for (var i = 0; i < 42; i++) from.add(Duration(days: i)): 100.0
      };
      final pts = Load.performanceManagement(loads,
          from: from, to: from.add(const Duration(days: 41)));
      expect(pts, hasLength(42));
      expect(pts.last.ctl, closeTo(63.6, 0.1));
      expect(pts.last.acwr, greaterThan(1));
    });
  });

  group('RunEvaluation', () {
    List<Sample> steady(int Function(int s) hr) => [
          for (var s = 0; s <= 3600; s += 5)
            Sample(second: s, speed: 3.0, hr: hr(s))
        ];

    test('no decoupling at constant HR', () {
      expect(RunEvaluation.aerobicDecoupling(steady((_) => 140)),
          closeTo(0, 1e-9));
    });

    test('cardiac drift shows as positive decoupling', () {
      final d =
          RunEvaluation.aerobicDecoupling(steady((s) => s < 1800 ? 140 : 150));
      expect(d, closeTo(6.7, 0.2));
    });

    test('pace compliance', () {
      final samples = [
        for (var s = 0; s <= 100; s++)
          Sample(second: s, speed: s <= 50 ? 3.0 : 4.0)
      ];
      expect(RunEvaluation.paceCompliance(samples, const Zone('E', 2.9, 3.1)),
          closeTo(0.5, 1e-9));
    });
  });
}
