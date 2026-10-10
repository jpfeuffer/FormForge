import 'package:formforge/integrations/garmin/garmin_client.dart';
import 'package:formforge/integrations/garmin/garmin_exceptions.dart';

typedef Schedule = ({int workoutId, DateTime date});

/// In-memory Garmin workout-service for push tests.
class FakeGarminClient implements GarminClient {
  final workouts = <int, Map<String, Object?>>{};
  final schedules = <int, Schedule>{};
  final calls = <String>[];
  var _next = 100;

  /// Throws for calls (e.g. `createWorkout`) when this returns an exception.
  GarminException? Function(String op, int callNumber)? failure;
  var _callNumber = 0;

  void _enter(String op, [Object? arg]) {
    calls.add(arg == null ? op : '$op $arg');
    final error = failure?.call(op, ++_callNumber);
    if (error != null) throw error;
  }

  int count(String op) => calls.where((c) => c.split(' ').first == op).length;

  @override
  Future<int> createWorkout(Map<String, Object?> json) async {
    _enter('createWorkout');
    final id = ++_next;
    workouts[id] = json;
    return id;
  }

  @override
  Future<int> scheduleWorkout(int workoutId, DateTime date) async {
    _enter('scheduleWorkout', workoutId);
    final id = ++_next;
    schedules[id] = (workoutId: workoutId, date: date);
    return id;
  }

  @override
  Future<void> unscheduleWorkout(int scheduleId) async {
    _enter('unscheduleWorkout', scheduleId);
    if (schedules.remove(scheduleId) == null) {
      throw const GarminApiException(404, 'schedule');
    }
  }

  @override
  Future<void> deleteWorkout(int workoutId) async {
    _enter('deleteWorkout', workoutId);
    if (workouts.remove(workoutId) == null) {
      throw const GarminApiException(404, 'workout');
    }
  }

  /// Seeds a workout that is already scheduled, as if created by an earlier push.
  (int workoutId, int scheduleId) seed(String name, DateTime date) {
    final workoutId = ++_next;
    workouts[workoutId] = {'workoutName': name};
    final scheduleId = ++_next;
    schedules[scheduleId] = (workoutId: workoutId, date: date);
    return (workoutId, scheduleId);
  }

  @override
  Future<Map<String, Object?>> calendarMonth(int year, int month) async {
    _enter('calendarMonth', '$year-$month');
    return {
      'calendarItems': [
        for (final e in schedules.entries)
          if (e.value.date.year == year && e.value.date.month == month)
            {
              'id': e.key,
              'itemType': 'workout',
              'workoutId': e.value.workoutId,
              'title': workouts[e.value.workoutId]?['workoutName'],
              'date':
                  '${e.value.date.year}-'
                  '${e.value.date.month.toString().padLeft(2, '0')}-'
                  '${e.value.date.day.toString().padLeft(2, '0')}',
            },
        // Non-workout entries must be ignored.
        {'id': 1, 'itemType': 'weight', 'date': '$year-01-01'},
      ],
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
