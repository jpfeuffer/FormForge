import 'package:training_core/training_core.dart';

import '../workout_resolve.dart';

/// Appended to workout names so FormForge-created workouts are recognizable
/// in the Garmin calendar, which only exposes the title.
const formForgeNameSuffix = ' [FF]';

const formForgeDescriptionMarker = '[FormForge]';

const _maxTitleLength = 40;
const _maxDescriptionLength = 512;
const _maxStepNoteLength = 200;

String garminWorkoutName(String title) {
  final t = title.trim();
  final cut = t.length > _maxTitleLength ? t.substring(0, _maxTitleLength) : t;
  return '${cut.trimRight()}$formForgeNameSuffix';
}

bool isFormForgeWorkoutName(String? name) =>
    name != null && name.endsWith(formForgeNameSuffix);

/// Workout-service payload for `POST /workout-service/workout`.
///
/// Format taken from python-garminconnect (`garminconnect/workout.py`).
Map<String, Object?> garminWorkoutJson(
  Workout workout, {
  PaceProfile? profile,
  String? title,
}) {
  final sport = workout.sport == Sport.strength ? _strength : _running;
  final steps = _StepBuilder(profile)
      .build(flattenNestedRepeats(workout.elements));
  return {
    'workoutName': garminWorkoutName(title ?? workout.title),
    'description': _description(workout.notes),
    'sportType': sport,
    'estimatedDurationInSecs': _estimatedSeconds(workout, profile),
    'workoutSegments': [
      {'segmentOrder': 1, 'sportType': sport, 'workoutSteps': steps},
    ],
  };
}

const _running = {
  'sportTypeId': 1,
  'sportTypeKey': 'running',
  'displayOrder': 1,
};

const _strength = {
  'sportTypeId': 5,
  'sportTypeKey': 'strength_training',
  'displayOrder': 5,
};

String _description(String? notes) {
  final text = notes == null || notes.trim().isEmpty
      ? formForgeDescriptionMarker
      : '$formForgeDescriptionMarker ${notes.trim()}';
  return text.length > _maxDescriptionLength
      ? text.substring(0, _maxDescriptionLength)
      : text;
}

int _estimatedSeconds(Workout workout, PaceProfile? profile) {
  if (profile != null) return workout.estimatedDuration(profile).inSeconds;
  return workout.steps.fold(0, (sum, s) {
    final seconds = switch (s.end) {
      TimeEnd(:final duration) => duration.inSeconds,
      _ => s.estimate?.inSeconds ?? 0,
    };
    return sum + seconds;
  });
}

class _StepBuilder {
  _StepBuilder(this._profile);

  final PaceProfile? _profile;
  var _order = 0;
  var _groups = 0;

  /// Depth-first `stepOrder` numbering; repeat groups come before their children.
  List<Map<String, Object?>> build(
    List<WorkoutElement> elements, {
    int? childStepId,
  }) => [
    for (final e in elements)
      switch (e) {
        WorkoutStep() => _step(e, childStepId),
        RepeatBlock() => _repeat(e),
      },
  ];

  Map<String, Object?> _repeat(RepeatBlock block) {
    final order = ++_order;
    final groupId = ++_groups;
    return {
      'type': 'RepeatGroupDTO',
      'stepOrder': order,
      'stepType': _stepType(6, 'repeat'),
      'childStepId': groupId,
      'numberOfIterations': block.times,
      'workoutSteps': build(block.elements, childStepId: groupId),
      'endCondition': _condition(7, 'iterations', displayable: false),
      'endConditionValue': block.times.toDouble(),
      'smartRepeat': false,
    };
  }

  Map<String, Object?> _step(WorkoutStep step, int? childStepId) {
    final (typeId, typeKey) = switch (step.kind) {
      StepKind.warmup => (1, 'warmup'),
      StepKind.cooldown => (2, 'cooldown'),
      StepKind.active => (3, 'interval'),
      StepKind.recovery => (4, 'recovery'),
      // Strength has no running step type; a rest step ended by the lap button.
      StepKind.rest || StepKind.strength => (5, 'rest'),
    };
    final (endCondition, endValue) = switch (step.end) {
      TimeEnd(:final duration) => (
        _condition(2, 'time'),
        duration.inSeconds.toDouble(),
      ),
      DistanceEnd(:final meters) => (_condition(3, 'distance'), meters),
      LapButtonEnd() => (_condition(1, 'lap.button'), null),
    };
    final target = resolveTarget(step.target, _profile);
    final note = _note(step);
    return {
      'type': 'ExecutableStepDTO',
      'stepOrder': ++_order,
      'stepType': _stepType(typeId, typeKey),
      'childStepId': ?childStepId,
      'description': ?note,
      'endCondition': endCondition,
      'endConditionValue': ?endValue,
      ..._targetFields(target),
    };
  }

  static String? _note(WorkoutStep step) {
    final text = step.note?.trim();
    final note = text == null || text.isEmpty
        ? (step.kind == StepKind.strength ? 'Strength' : null)
        : text;
    if (note == null) return null;
    return note.length > _maxStepNoteLength
        ? note.substring(0, _maxStepNoteLength)
        : note;
  }

  static Map<String, Object?> _targetFields(ResolvedTarget? target) {
    if (target == null) {
      return {
        'targetType': {
          'workoutTargetTypeId': 1,
          'workoutTargetTypeKey': 'no.target',
          'displayOrder': 1,
        },
      };
    }
    // For pace.zone both values are speeds in m/s, slower one first.
    return switch (target.kind) {
      BandKind.speed => {
        'targetType': {
          'workoutTargetTypeId': 6,
          'workoutTargetTypeKey': 'pace.zone',
          'displayOrder': 6,
        },
        'targetValueOne': _round(target.low, 1000),
        'targetValueTwo': _round(target.high, 1000),
      },
      BandKind.heartRate => {
        'targetType': {
          'workoutTargetTypeId': 4,
          'workoutTargetTypeKey': 'heart.rate.zone',
          'displayOrder': 4,
        },
        'targetValueOne': target.low.roundToDouble(),
        'targetValueTwo': target.high.roundToDouble(),
      },
    };
  }

  static double _round(double v, int scale) => (v * scale).round() / scale;

  static Map<String, Object?> _stepType(int id, String key) => {
    'stepTypeId': id,
    'stepTypeKey': key,
    'displayOrder': id,
  };

  static Map<String, Object?> _condition(
    int id,
    String key, {
    bool displayable = true,
  }) => {
    'conditionTypeId': id,
    'conditionTypeKey': key,
    'displayOrder': id,
    'displayable': displayable,
  };
}
