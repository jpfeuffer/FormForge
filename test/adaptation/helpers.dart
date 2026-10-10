import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:formforge/data/activity_streams.dart';
import 'package:formforge/data/database.dart';
import 'package:training_core/training_core.dart';

/// A constant-pace stretch at 1 Hz: [seconds] long at [speed] m/s and [hr] bpm.
typedef Leg = ({int seconds, double speed, int hr});

Leg leg(int seconds, double speed, [int hr = 140]) =>
    (seconds: seconds, speed: speed, hr: hr);

ActivityStreamData streamOf(List<Leg> legs) {
  final seconds = <int>[0], speed = <double?>[0], hr = <int?>[null];
  final distance = <double?>[0];
  var t = 0, d = 0.0;
  for (final l in legs) {
    for (var i = 0; i < l.seconds; i++) {
      t++;
      d += l.speed;
      seconds.add(t);
      speed.add(l.speed);
      hr.add(l.hr);
      distance.add(d);
    }
  }
  return ActivityStreamData(
    seconds: seconds,
    speed: speed,
    heartRate: hr,
    distance: distance,
  );
}

Future<int> addActivity(
  AppDatabase db, {
  required DateTime start,
  List<Leg>? legs,
  int? durationS,
  String sport = 'running',
  ActivitySource source = ActivitySource.garmin,
  String? externalId,
  String? fitPath,
}) async {
  final stream = legs == null ? null : streamOf(legs);
  final id = await db
      .into(db.activities)
      .insert(
        ActivitiesCompanion.insert(
          source: source,
          externalId: Value(externalId),
          startTime: start,
          sport: sport,
          durationS: durationS ?? stream?.seconds.last ?? 0,
          distanceM: Value(stream?.distance?.last),
          fitPath: Value(fitPath),
        ),
      );
  if (stream != null) {
    await db.into(db.activityStreams).insert(stream.toCompanion(id));
  }
  return id;
}

Future<int> addPlanned(
  AppDatabase db, {
  required DateTime date,
  required Workout workout,
  SessionKind kind = SessionKind.easy,
  WorkoutStatus status = WorkoutStatus.planned,
}) => db
    .into(db.plannedWorkouts)
    .insert(
      PlannedWorkoutsCompanion.insert(
        date: date,
        kind: kind,
        title: workout.title,
        workoutJson: jsonEncode(workout.toJson()),
        status: Value(status),
      ),
    );

Future<void> setFitness(AppDatabase db, double vdot) => db
    .into(db.fitnessSnapshots)
    .insert(
      FitnessSnapshotsCompanion.insert(
        date: DateTime(2026, 9, 1),
        source: FitnessSource.manual,
        vdot: Value(vdot),
      ),
    );

DateTime dayOf(DateTime t) {
  final l = t.toLocal();
  return DateTime(l.year, l.month, l.day);
}
