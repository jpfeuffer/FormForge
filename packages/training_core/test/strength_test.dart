import 'package:test/test.dart';
import 'package:training_core/training_core.dart';

void main() {
  StrengthSession s(List<FocusArea> areas, int rpe,
          [StrengthStyle style = StrengthStyle.calisthenics]) =>
      StrengthSession(
          focusAreas: areas,
          duration: const Duration(minutes: 30),
          rpe: rpe,
          style: style);

  group('heavy lower body', () {
    test('leg work at RPE ≥ 7 is heavy', () {
      expect(s([FocusArea.lowerBody], 7).isHeavyLowerBody, isTrue);
      expect(s([FocusArea.plyometrics, FocusArea.core], 8).isHeavyLowerBody,
          isTrue);
      expect(s([FocusArea.runningStrength], 6).isHeavyLowerBody, isFalse);
    });

    test('upper body, core and mobility are never heavy', () {
      expect(s([FocusArea.upperPull, FocusArea.core], 9).isHeavyLowerBody,
          isFalse);
      expect(s([FocusArea.mobility], 10).isHeavyLowerBody, isFalse);
    });

    test('full-body gym is heavy', () {
      expect(s([FocusArea.fullBody], 5, StrengthStyle.gym).isHeavyLowerBody,
          isTrue);
      expect(s([FocusArea.fullBody], 5).isHeavyLowerBody, isFalse);
    });
  });

  group('combined workouts', () {
    final p = PaceProfile.fromVdot(45);
    final core = s([FocusArea.core, FocusArea.upperPush], 6);

    test('sandwich: easy run, lap-button strength, easy run back', () {
      final w = core.combineWithRun(const Duration(minutes: 50));
      expect(w.sport, Sport.combined);
      final steps = w.flatten();
      expect(steps.map((e) => e.kind),
          [StepKind.active, StepKind.strength, StepKind.active]);
      expect(steps[1].end, isA<LapButtonEnd>());
      expect(steps[1].note, contains('upperPush'));
      expect(w.estimatedRunDuration(p), const Duration(minutes: 50));
      expect(w.estimatedDuration(p), const Duration(minutes: 80));
      expect(w.focusAreas, core.focusAreas);
      expect((steps[0].target as IntensityTarget).intensity, Intensity.easy);
    });

    test('strength before or after the run', () {
      final before = core.combineWithRun(const Duration(minutes: 30),
          placement: StrengthPlacement.before, intensity: Intensity.recovery);
      expect(before.flatten().first.kind, StepKind.strength);
      expect(before.title, startsWith('Recovery run'));
      final after = core.combineWithRun(const Duration(minutes: 30),
          placement: StrengthPlacement.after);
      expect(after.flatten().last.kind, StepKind.strength);
    });

    test('standalone strength workout', () {
      final w = core.toWorkout();
      expect(w.sport, Sport.strength);
      expect(w.estimatedDuration(p), core.duration);
      expect(w.estimatedDistance(p), 0);
    });
  });

  test('strength goal defaults', () {
    const g = StrengthGoal(kind: StrengthGoalKind.runningSupport);
    expect(g.effectiveFocusAreas, contains(FocusArea.runningStrength));
    expect(g.isActive, isTrue);
    expect(const StrengthGoal.none().isActive, isFalse);
  });
}
