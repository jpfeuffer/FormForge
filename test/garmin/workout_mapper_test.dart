import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/integrations/garmin/workout_mapper.dart';

import 'workout_fixtures.dart';

List<Map<String, Object?>> _steps(Map<String, Object?> json) {
  final segments = json['workoutSegments']! as List;
  return ((segments.single as Map)['workoutSteps']! as List)
      .cast<Map<String, Object?>>();
}

String _key(Map<String, Object?> step, String field, String keyField) =>
    (step[field]! as Map)[keyField]! as String;

void main() {
  final profile = testProfile();

  test('easy run maps paces to pace.zone in m/s, slower first', () {
    final json = garminWorkoutJson(easyRun(), profile: profile);
    expectGolden('easy_run', json);

    expect(json['workoutName'], 'Easy run [FF]');
    expect(json['description'], '[FormForge] Keep it conversational');
    expect(json['estimatedDurationInSecs'], 40 * 60);
    final steps = _steps(json);
    expect([for (final s in steps) s['stepOrder']], [1, 2, 3]);
    expect(
      [for (final s in steps) _key(s, 'stepType', 'stepTypeKey')],
      ['warmup', 'interval', 'cooldown'],
    );
    expect(steps[1]['targetValueOne'], 2.5);
    expect(steps[1]['targetValueTwo'], 3.0);
    expect(_key(steps[1], 'targetType', 'workoutTargetTypeKey'), 'pace.zone');
    expect(_key(steps[2], 'targetType', 'workoutTargetTypeKey'), 'no.target');
    expect(steps[2], isNot(contains('targetValueOne')));
  });

  test('intensity targets are dropped without a pace profile', () {
    final steps = _steps(garminWorkoutJson(easyRun()));
    expect(
      {for (final s in steps) _key(s, 'targetType', 'workoutTargetTypeKey')},
      {'no.target'},
    );
  });

  test('distance steps and a simple repeat group', () {
    final json = garminWorkoutJson(thresholdDistance(), profile: profile);
    expectGolden('threshold_distance', json);

    final steps = _steps(json);
    expect(
      steps[0]['endCondition'],
      containsPair('conditionTypeKey', 'distance'),
    );
    expect(steps[0]['endConditionValue'], 2000.0);
    final group = steps[1];
    expect(group['type'], 'RepeatGroupDTO');
    expect(group['numberOfIterations'], 4);
    expect(group['endConditionValue'], 4.0);
    expect(group['stepOrder'], 2);
    final children = (group['workoutSteps']! as List)
        .cast<Map<String, Object?>>();
    expect([for (final c in children) c['stepOrder']], [3, 4]);
    expect(
      {for (final c in children) c['childStepId']},
      {group['childStepId']},
    );
    expect(children[0]['description'], 'Controlled');
    expect(steps[2]['stepOrder'], 5);
  });

  test('nested repeats are unrolled into one group', () {
    final json = garminWorkoutJson(nestedIntervals(), profile: profile);
    expectGolden('intervals_nested', json);

    final steps = _steps(json);
    final group = steps[1];
    expect(group['numberOfIterations'], 2);
    final children = (group['workoutSteps']! as List)
        .cast<Map<String, Object?>>();
    expect({for (final c in children) c['type']}, {'ExecutableStepDTO'});
    expect(
      [for (final c in children) _key(c, 'stepType', 'stepTypeKey')],
      [
        'interval',
        'recovery',
        'interval',
        'recovery',
        'interval',
        'recovery',
        'rest',
      ],
    );
    expect(steps.last['stepOrder'], 10);
  });

  test('heart-rate and explicit speed targets', () {
    final json = garminWorkoutJson(heartRateRun(), profile: profile);
    expectGolden('hr_targets', json);

    final steps = _steps(json);
    expect(
      _key(steps[0], 'targetType', 'workoutTargetTypeKey'),
      'heart.rate.zone',
    );
    expect(
      [steps[1]['targetValueOne'], steps[1]['targetValueTwo']],
      [140.0, 153.0],
    );
    expect(_key(steps[2], 'targetType', 'workoutTargetTypeKey'), 'pace.zone');
    expect(
      [steps[2]['targetValueOne'], steps[2]['targetValueTwo']],
      [2.4, 2.8],
    );
  });

  test('combined session: strength is a lap-button rest step in a run', () {
    final json = garminWorkoutJson(combinedSession(), profile: profile);
    expectGolden('combined', json);

    expect(json['sportType'], containsPair('sportTypeKey', 'running'));
    final strength = _steps(json)[2];
    expect(_key(strength, 'stepType', 'stepTypeKey'), 'rest');
    expect(_key(strength, 'endCondition', 'conditionTypeKey'), 'lap.button');
    expect(strength, isNot(contains('endConditionValue')));
    expect(strength['description'], 'Core circuit, 15 min');
    expect(json['estimatedDurationInSecs'], (10 + 20 + 15 + 5) * 60);
  });

  test('strength-only workout uses the strength sport type', () {
    final json = garminWorkoutJson(strengthOnly(), profile: profile);
    expectGolden('strength', json);

    expect(json['sportType'], containsPair('sportTypeId', 5));
    expect(_steps(json).single['description'], 'Strength');
  });

  test('names are marked and truncated', () {
    final long = 'x' * 80;
    final name = garminWorkoutName(long);
    expect(name, endsWith(formForgeNameSuffix));
    expect(name.length, 40 + formForgeNameSuffix.length);
    expect(isFormForgeWorkoutName(name), isTrue);
    expect(isFormForgeWorkoutName('Tempo run'), isFalse);
    expect(isFormForgeWorkoutName(null), isFalse);
  });
}
