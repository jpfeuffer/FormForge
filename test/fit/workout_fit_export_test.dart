import 'package:fit_io/fit_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/integrations/fit/workout_fit_export.dart';

import '../garmin/workout_fixtures.dart';

FitWorkout _roundTrip(FitWorkout w) => FitWorkout.fromFile(
  const FitDecoder(crcCheck: CrcCheck.strict)
      .decode(w.encode(timeCreated: DateTime.utc(2026, 10, 10))),
)!;

void main() {
  final profile = testProfile();

  test('easy run round-trips through the FIT codec', () {
    final fit = _roundTrip(toFitWorkout(easyRun(), profile: profile));

    expect(fit.name, 'Easy run');
    expect(fit.sport, FitSport.running);
    expect(fit.steps, hasLength(3));
    expect(
      [for (final s in fit.steps) s.intensity],
      [FitIntensity.warmup, FitIntensity.active, FitIntensity.cooldown],
    );
    final active = fit.steps[1];
    expect(
      (active.duration as FitTimeDuration).duration,
      const Duration(minutes: 30),
    );
    final speed = active.target as FitSpeedTarget;
    expect((speed.low, speed.high), (2.5, 3.0));
    expect(fit.steps[2].target, isA<FitOpenTarget>());
  });

  test('without a pace profile intensity targets become open', () {
    final fit = _roundTrip(toFitWorkout(easyRun()));
    expect({for (final s in fit.steps) s.target.runtimeType}, {FitOpenTarget});
  });

  test('distance steps, heart-rate and speed targets, notes', () {
    final hr = _roundTrip(toFitWorkout(heartRateRun(), profile: profile));
    expect((hr.steps[0].target as FitHeartRateTarget).low, 130);
    expect((hr.steps[1].target as FitHeartRateTarget).high, 153);
    expect((hr.steps[2].target as FitSpeedTarget).high, 2.8);

    final threshold = _roundTrip(
      toFitWorkout(thresholdDistance(), profile: profile),
    );
    expect((threshold.steps[0].duration as FitDistanceDuration).meters, 2000);
    expect(threshold.steps[1].notes, 'Controlled');
  });

  test('a repeat block becomes a repeat step pointing at its first step', () {
    final fit = _roundTrip(toFitWorkout(thresholdDistance(), profile: profile));

    expect(fit.steps, hasLength(5));
    final repeat = fit.steps[3].duration as FitRepeatDuration;
    expect((repeat.fromStep, repeat.times), (1, 4));
  });

  test('nested repeats are unrolled', () {
    final fit = _roundTrip(toFitWorkout(nestedIntervals(), profile: profile));

    // warmup, 3x(interval, recovery) + rest, repeat 2x, cooldown
    expect(fit.steps, hasLength(10));
    final repeat = fit.steps[8].duration as FitRepeatDuration;
    expect((repeat.fromStep, repeat.times), (1, 2));
    expect(fit.steps[7].intensity, FitIntensity.rest);
    expect(
      fit.steps.where((s) => s.duration is FitRepeatDuration),
      hasLength(1),
    );
  });

  test('strength steps in a run are open rest steps with their note', () {
    final fit = _roundTrip(toFitWorkout(combinedSession(), profile: profile));

    expect(fit.sport, FitSport.running);
    final strength = fit.steps[2];
    expect(strength.duration, isA<FitOpenDuration>());
    expect(strength.intensity, FitIntensity.rest);
    expect(strength.name, 'Strength');
    expect(strength.notes, 'Core circuit, 15 min');
  });

  test('strength-only workouts use the training sport', () {
    final fit = _roundTrip(toFitWorkout(strengthOnly()));

    expect(fit.sport, FitSport.training);
    expect(fit.subSport, FitSubSport.strengthTraining);
  });

  test('long names are cut for the watch', () {
    final fit = _roundTrip(toFitWorkout(easyRun(), title: 'A' * 60));
    expect(fit.name, 'A' * 24);
  });

  group('fitFileName', () {
    final date = DateTime(2026, 10, 12);

    test('is ASCII-only, transliterated and length-limited', () {
      expect(
        fitFileName(date, 'Intervalle: 6×400m, Über-Schwelle'),
        'FF_20261012_Intervalle_6_400m_Ue.fit',
      );
    });

    test('falls back for empty titles and trims trailing separators', () {
      expect(fitFileName(date, '---'), 'FF_20261012_workout.fit');
      expect(fitFileName(date, '${'a' * 19} b'), 'FF_20261012_${'a' * 19}.fit');
    });

    test('supports a duplicate index', () {
      expect(
        fitFileName(date, 'Easy run', duplicateIndex: 2),
        'FF_20261012_Easy_run_2.fit',
      );
    });

    test('pads small dates', () {
      expect(fitFileName(DateTime(2026, 1, 5), 'x'), 'FF_20260105_x.fit');
    });
  });
}
