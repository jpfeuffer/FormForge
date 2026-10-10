import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/database.dart';
import 'package:formforge/integrations/garmin/garmin_exceptions.dart';
import 'package:formforge/integrations/garmin/garmin_push_service.dart';
import 'package:training_core/training_core.dart';

import 'fake_garmin_client.dart';
import 'workout_fixtures.dart';

void main() {
  late AppDatabase db;
  late FakeGarminClient garmin;
  PaceProfile? profile = testProfile();
  late GarminPushService service;

  final today = DateTime(2026, 10, 10);
  DateTime day(int offset) => DateTime(2026, 10, 10 + offset);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    garmin = FakeGarminClient();
    profile = testProfile();
    service = GarminPushService(
      db,
      garmin,
      paceProfile: () => profile,
      delay: Duration.zero,
      clock: () => DateTime(2026, 10, 10, 9),
    );
  });
  tearDown(() => db.close());

  Future<int> addRow(
    DateTime date, {
    Workout? workout,
    String? title,
    WorkoutStatus status = WorkoutStatus.planned,
  }) {
    final w = workout ?? easyRun();
    return db
        .into(db.plannedWorkouts)
        .insert(
          PlannedWorkoutsCompanion.insert(
            date: date,
            kind: SessionKind.easy,
            title: title ?? w.title,
            workoutJson: workoutJsonString(w),
            status: Value(status),
          ),
        );
  }

  Future<PlannedWorkout> rowOf(int id) => (db.select(
    db.plannedWorkouts,
  )..where((t) => t.id.equals(id))).getSingle();

  test(
    'creates and schedules planned workouts and stores ids and hash',
    () async {
      final id = await addRow(day(1));

      final summary = await service.pushRange(today, day(14));

      expect((summary.created, summary.updated, summary.unchanged), (1, 0, 0));
      final row = await rowOf(id);
      expect(garmin.workouts.keys, [int.parse(row.garminWorkoutId!)]);
      final scheduled = garmin.schedules[int.parse(row.garminScheduleId!)]!;
      expect(scheduled.date, day(1));
      expect(scheduled.workoutId, int.parse(row.garminWorkoutId!));
      expect(garmin.workouts.values.single['workoutName'], 'Easy run [FF]');
      expect(row.garminSyncedHash, syncHash(row, profile));
      expect(row.garminSyncedAt, DateTime(2026, 10, 10, 9));
    },
  );

  test('unchanged rows cause no API calls', () async {
    await addRow(day(1));
    await service.pushRange(today, day(14));
    garmin.calls.clear();

    final summary = await service.pushRange(today, day(14));

    expect((summary.created, summary.updated, summary.unchanged), (0, 0, 1));
    expect(garmin.calls, isEmpty);
  });

  test('a changed workout replaces the old Garmin copy', () async {
    final id = await addRow(day(1));
    await service.pushRange(today, day(14));
    final before = await rowOf(id);

    await (db.update(db.plannedWorkouts)..where((t) => t.id.equals(id))).write(
      PlannedWorkoutsCompanion(
        workoutJson: Value(workoutJsonString(thresholdDistance())),
        title: const Value('Threshold 4x1k'),
      ),
    );
    final summary = await service.pushRange(today, day(14));

    expect((summary.created, summary.updated), (0, 1));
    final after = await rowOf(id);
    expect(after.garminWorkoutId, isNot(before.garminWorkoutId));
    expect(garmin.workouts.keys, [int.parse(after.garminWorkoutId!)]);
    expect(garmin.schedules.keys, [int.parse(after.garminScheduleId!)]);
    expect(garmin.workouts.values.single['workoutName'], 'Threshold 4x1k [FF]');
  });

  test('moving the row to another day re-pushes it', () async {
    final id = await addRow(day(1));
    await service.pushRange(today, day(14));

    await (db.update(db.plannedWorkouts)..where((t) => t.id.equals(id))).write(
      PlannedWorkoutsCompanion(date: Value(day(3))),
    );
    final summary = await service.pushRange(today, day(14));

    expect(summary.updated, 1);
    expect(garmin.schedules.values.single.date, day(3));
  });

  test('re-pacing after a fitness change triggers a re-push', () async {
    final id = await addRow(day(1));
    await service.pushRange(today, day(14));
    final row = await rowOf(id);

    final faster = testProfile(scale: 1.05);
    expect(syncHash(row, faster), isNot(syncHash(row, profile)));
    expect(syncHash(row, null), isNot(syncHash(row, profile)));
    expect(syncHash(row, profile), syncHash(row, testProfile()));

    profile = faster;
    final summary = await service.pushRange(today, day(14));

    expect(summary.updated, 1);
    final step =
        (((garmin.workouts.values.single['workoutSegments']! as List).single
                    as Map)['workoutSteps']!
                as List)[1]
            as Map;
    expect(step['targetValueOne'], 2.625);
  });

  test(
    'workouts without intensity targets are not re-pushed on re-pace',
    () async {
      await addRow(day(1), workout: heartRateRun());
      await service.pushRange(today, day(14));

      profile = testProfile(scale: 1.1);
      final summary = await service.pushRange(today, day(14));

      expect(summary.unchanged, 1);
    },
  );

  test(
    'skipped rows are unscheduled; past and done rows are left alone',
    () async {
      final skipped = await addRow(day(1));
      await service.pushRange(today, day(14));
      await (db.update(
        db.plannedWorkouts,
      )..where((t) => t.id.equals(skipped))).write(
        const PlannedWorkoutsCompanion(status: Value(WorkoutStatus.skipped)),
      );
      await addRow(day(-2));
      await addRow(day(2), status: WorkoutStatus.done);
      garmin.calls.clear();

      final summary = await service.pushRange(day(-3), day(14));

      expect((summary.removed, summary.created), (1, 0));
      expect(garmin.workouts, isEmpty);
      expect(garmin.schedules, isEmpty);
      final row = await rowOf(skipped);
      expect(row.garminScheduleId, isNull);
      expect(row.garminWorkoutId, isNull);
      expect(row.garminSyncedHash, isNull);
      expect(garmin.count('createWorkout'), 0);
    },
  );

  test('rows outside the range are not touched', () async {
    await addRow(day(1));
    await addRow(day(20));

    final summary = await service.pushRange(today, day(14));

    expect(summary.created, 1);
  });

  test('rate limiting aborts the run', () async {
    for (var i = 1; i <= 3; i++) {
      await addRow(day(i));
    }
    garmin.failure = (op, n) =>
        op == 'createWorkout' && n == 3 ? const GarminRateLimited() : null;
    final progress = <int>[];

    final summary = await service.pushRange(
      today,
      day(14),
      onProgress: (done, total) => progress.add(done),
    );

    expect(summary.created, 1);
    expect(summary.failed, hasLength(1));
    expect(summary.abortReason, isNotNull);
    expect(garmin.count('createWorkout'), 2);
    expect(summary.message, contains('Stopped'));
    expect(progress, [1]);
  });

  test('other failures are collected and the run continues', () async {
    for (var i = 1; i <= 3; i++) {
      await addRow(day(i), title: 'Run $i');
    }
    var creates = 0;
    garmin.failure = (op, _) => op == 'createWorkout' && ++creates == 2
        ? const GarminApiException(400, 'workout-service/workout')
        : null;

    final summary = await service.pushRange(today, day(14));

    expect(summary.created, 2);
    expect(summary.failed.single.row.title, 'Run 2');
    expect(summary.abortReason, isNull);
  });

  test('a failed schedule call does not leave a workout behind', () async {
    final id = await addRow(day(1));
    garmin.failure = (op, _) => op == 'scheduleWorkout'
        ? const GarminApiException(500, 'schedule')
        : null;

    final summary = await service.pushRange(today, day(14));

    expect(summary.failed, hasLength(1));
    expect(garmin.workouts, isEmpty);
    expect((await rowOf(id)).garminWorkoutId, isNull);
  });

  test('a corrupt workout is reported as failed', () async {
    final id = await addRow(day(1));
    await (db.update(db.plannedWorkouts)..where((t) => t.id.equals(id))).write(
      const PlannedWorkoutsCompanion(workoutJson: Value('{"v": 99}')),
    );
    await addRow(day(2));

    final summary = await service.pushRange(today, day(14));

    expect((summary.created, summary.failed.length), (1, 1));
  });

  test('copies deleted on Garmin by the user do not break updates', () async {
    final id = await addRow(day(1));
    await service.pushRange(today, day(14));
    final old = await rowOf(id);
    garmin.workouts.clear();
    garmin.schedules.clear();
    await (db.update(db.plannedWorkouts)..where((t) => t.id.equals(id))).write(
      PlannedWorkoutsCompanion(date: Value(day(2))),
    );

    final summary = await service.pushRange(today, day(14));

    expect(summary.updated, 1);
    expect((await rowOf(id)).garminWorkoutId, isNot(old.garminWorkoutId));
  });

  test('removeFromGarmin deletes the copy and clears the ids', () async {
    final id = await addRow(day(1));
    await service.pushRange(today, day(14));

    await service.removeFromGarmin(await rowOf(id));

    expect(garmin.workouts, isEmpty);
    expect(garmin.schedules, isEmpty);
    expect((await rowOf(id)).garminScheduleId, isNull);
  });

  group('cleanupOrphans', () {
    test('removes unreferenced FormForge workouts only', () async {
      final id = await addRow(day(1));
      await service.pushRange(today, day(14));
      final kept = await rowOf(id);

      final orphan = garmin.seed('Old tempo [FF]', day(2));
      final foreign = garmin.seed('Parkrun', day(3));
      final outside = garmin.seed('Far away [FF]', day(60));

      final result = await service.cleanupOrphans(from: today, to: day(30));

      expect(result.removed, 1);
      expect(result.failed, isEmpty);
      expect(garmin.schedules.containsKey(orphan.$2), isFalse);
      expect(garmin.workouts.containsKey(orphan.$1), isFalse);
      expect(garmin.schedules.containsKey(foreign.$2), isTrue);
      expect(garmin.schedules.containsKey(outside.$2), isTrue);
      expect(
        garmin.schedules.containsKey(int.parse(kept.garminScheduleId!)),
        isTrue,
      );
    });

    test('reads every month in the range', () async {
      garmin.seed('A [FF]', DateTime(2026, 10, 20));
      garmin.seed('B [FF]', DateTime(2026, 12, 5));

      final result = await service.cleanupOrphans(
        from: DateTime(2026, 10, 1),
        to: DateTime(2026, 12, 31),
      );

      expect(result.removed, 2);
      expect(garmin.count('calendarMonth'), 3);
      expect(garmin.schedules, isEmpty);
    });

    test(
      'a workout referenced by a row is kept even if its schedule moved',
      () async {
        final id = await addRow(day(1));
        await service.pushRange(today, day(14));
        final seeded = garmin.seed('Same [FF]', day(2));
        await (db.update(
          db.plannedWorkouts,
        )..where((t) => t.id.equals(id))).write(
          PlannedWorkoutsCompanion(garminWorkoutId: Value('${seeded.$1}')),
        );

        final result = await service.cleanupOrphans(from: today, to: day(30));

        expect(result.removed, 1);
        expect(garmin.workouts.containsKey(seeded.$1), isTrue);
        expect(garmin.schedules.containsKey(seeded.$2), isFalse);
      },
    );

    test('stops when Garmin rate limits', () async {
      garmin.seed('A [FF]', day(2));
      garmin.failure = (op, _) =>
          op == 'calendarMonth' ? const GarminRateLimited() : null;

      final result = await service.cleanupOrphans(from: today, to: day(30));

      expect(result.removed, 0);
      expect(result.abortReason, isNotNull);
    });
  });
}
