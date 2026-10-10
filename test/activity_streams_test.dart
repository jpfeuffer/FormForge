import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/activity_streams.dart';
import 'package:formforge/data/database.dart';

void main() {
  test('v3 upgrade adds timer stops and drops timer-time Garmin streams',
      () async {
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) => raw
          ..execute('CREATE TABLE activities (id INTEGER PRIMARY KEY, '
              'source TEXT, fit_path TEXT)')
          ..execute('CREATE TABLE planned_workouts (id INTEGER PRIMARY KEY, '
              'activity_id INTEGER)')
          ..execute('CREATE TABLE activity_streams (activity_id INTEGER '
              'PRIMARY KEY, sample_count INTEGER NOT NULL, seconds BLOB NOT '
              'NULL, speed BLOB, heart_rate BLOB, distance BLOB, latitude '
              'BLOB, longitude BLOB, altitude BLOB)')
          ..execute("INSERT INTO activities VALUES (1, 'garmin', NULL), "
              "(2, 'fitFile', 'x.fit')")
          ..execute("INSERT INTO activity_streams (activity_id, sample_count, "
              "seconds) VALUES (1, 0, x''), (2, 0, x'')")
          ..execute('PRAGMA user_version = 3'),
      ),
    );
    addTearDown(db.close);
    final rows = await db.select(db.activityStreams).get();
    expect(rows.map((r) => r.activityId), [2]);
    expect(rows.single.timerStops, isNull);
  });

  test('timer stops pack round trip; empty differs from unknown', () {
    expect(unpackStops(packStops([(100, 160), (300, 330)])), [
      (100, 160),
      (300, 330),
    ]);
    final none = ActivityStreamData(seconds: [0, 1], timerStops: const []);
    expect(none.toCompanion(1).timerStops.value, isNotNull);
    expect(ActivityStreamData(seconds: [0, 1]).toCompanion(1).timerStops.value,
        isNull);
  });

  test('pack → unpack round trip keeps values and gaps', () {
    final data = ActivityStreamData(
      seconds: [0, 1, 2, 5],
      speed: [2.5, null, 3.25, 4],
      heartRate: [120, 121, null, 255],
      distance: [0, 2.5, 5.75, 18],
      latitude: [574000000, null, -574000000, 1],
      longitude: [null, null, null, null],
    );
    final c = data.toCompanion(7);
    expect(c.longitude.value, isNull);
    expect(c.altitude.value, isNull);
    expect(c.seconds.value.lengthInBytes, 16);
    expect(c.heartRate.value!.lengthInBytes, 4);

    final back = ActivityStreamData.fromRow(
      ActivityStream(
        activityId: 7,
        sampleCount: c.sampleCount.value,
        seconds: c.seconds.value,
        speed: c.speed.value,
        heartRate: c.heartRate.value,
        distance: c.distance.value,
        latitude: c.latitude.value,
        longitude: c.longitude.value,
        altitude: c.altitude.value,
      ),
    );
    expect(back.seconds, [0, 1, 2, 5]);
    expect(back.speed, [2.5, null, 3.25, 4]);
    expect(back.heartRate, [120, 121, null, 255]);
    expect(back.distance, [0, 2.5, 5.75, 18]);
    expect(back.latitude, [574000000, null, -574000000, 1]);
    expect(back.longitude, isNull);
    expect(back.altitude, isNull);
  });

  test('toSamples maps speed and HR per second', () {
    final samples = ActivityStreamData(
      seconds: [0, 1],
      speed: [3, null],
      heartRate: [null, 150],
    ).toSamples();
    expect(samples.map((s) => (s.second, s.speed, s.hr)), [
      (0, 3.0, null),
      (1, null, 150),
    ]);
  });

  test('schema v1 databases get new tables on upgrade', () async {
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) => raw
          ..execute('CREATE TABLE activities (id INTEGER PRIMARY KEY, '
              'source TEXT, fit_path TEXT)')
          ..execute('PRAGMA user_version = 1'),
      ),
    );
    addTearDown(db.close);
    expect(await db.select(db.activityStreams).get(), isEmpty);
    expect(await db.select(db.trainingPlans).get(), isEmpty);
    expect(await db.select(db.plannedWorkouts).get(), isEmpty);
    expect(await db.select(db.matchSuggestions).get(), isEmpty);
    expect(db.schemaVersion, 5);
  });
}
