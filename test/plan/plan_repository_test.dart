import 'dart:convert';

import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/database.dart';
import 'package:formforge/data/plan_repository.dart';
import 'package:training_core/training_core.dart' hide TrainingPlan;

PlanRequest request({double vdot = 45, StrengthGoal? strength}) => PlanRequest(
  goalMeters: 10000,
  raceDate: DateTime(2026, 3, 15),
  targetTime: const Duration(minutes: 48),
  startDate: DateTime(2026, 1, 5),
  fitness: CurrentFitness(vdot: vdot, lthr: 165),
  availability: WeeklyAvailability.on([
    DateTime.tuesday,
    DateTime.thursday,
    DateTime.saturday,
    DateTime.sunday,
  ], longRunWeekday: DateTime.sunday),
  currentWeeklyKm: 25,
  longestRecentRunKm: 10,
  strength:
      strength ??
      const StrengthGoal(
        kind: StrengthGoalKind.runningSupport,
        sessionsPerWeek: 1,
      ),
);

void main() {
  late AppDatabase db;
  var now = DateTime(2026, 2, 2);
  late PlanRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    now = DateTime(2026, 2, 2);
    repo = PlanRepository(db, now: () => now);
  });
  tearDown(() => db.close());

  Future<List<PlannedWorkout>> workouts() => (db.select(
    db.plannedWorkouts,
  )..orderBy([(t) => OrderingTerm.asc(t.date)])).get();

  Future<List<TrainingPlan>> plans() => db.select(db.trainingPlans).get();

  group('savePlan', () {
    test('stores one row per session with goal and request', () async {
      final plan = PlanGenerator.generate(request());
      final id = await repo.savePlan(plan, name: '10K');

      final rows = await workouts();
      expect(rows, hasLength(plan.sessions.length));
      expect(rows.every((r) => r.planId == id), isTrue);
      expect(rows.every((r) => r.status == WorkoutStatus.planned), isTrue);

      final first = rows.first;
      final session = plan.sessions.first;
      expect(first.kind, session.kind);
      expect(first.title, session.workout.title);
      expect(
        first.date,
        DateTime(session.date.year, session.date.month, session.date.day),
      );
      expect(
        Workout.fromJson(jsonDecode(first.workoutJson) as Map<String, Object?>)
            .title,
        session.workout.title,
      );

      final strengthRows = rows.where((r) => r.strengthJson != null);
      expect(strengthRows, isNotEmpty);
      expect(
        StrengthSession.fromJson(
          jsonDecode(strengthRows.first.strengthJson!) as Map<String, Object?>,
        ),
        isA<StrengthSession>(),
      );
      expect(
        rows.where((r) => r.isKey).length,
        plan.sessions.where((s) => s.isKey).length,
      );
      expect(rows.map((r) => r.weekIndex).toSet(), {
        for (final w in plan.weeks) w.index,
      });

      final row = (await plans()).single;
      expect(row.active, isTrue);
      expect(row.name, '10K');
      expect(
        PlanRequest.fromJson(
          jsonDecode(row.requestJson) as Map<String, Object?>,
        ).toJson(),
        plan.request.toJson(),
      );

      final goal = await db.select(db.goals).getSingle();
      expect(goal.id, row.goalId);
      expect(goal.distanceM, 10000);
      expect(goal.targetTimeS, 48 * 60);
      expect(goal.raceDate, DateTime(2026, 3, 15));
      expect(goal.active, isTrue);
    });

    test(
      'keeps a single active plan and drops the old future workouts',
      () async {
        final first = await repo.savePlan(
          PlanGenerator.generate(request()),
          name: 'A',
        );
        final before = await workouts();
        final pastCount = before.where((r) => r.date.isBefore(now)).length;
        expect(pastCount, greaterThan(0));

        final plan2 = PlanGenerator.generate(request(vdot: 50));
        final second = await repo.savePlan(plan2, name: 'B');

        final all = await plans();
        expect(all, hasLength(2));
        expect(all.where((p) => p.active).map((p) => p.id), [second]);
        final rows = await workouts();
        expect(rows.where((r) => r.planId == first), hasLength(pastCount));
        expect(
          rows.where((r) => r.planId == second),
          hasLength(plan2.sessions.length),
        );
        expect(
          await db
              .select(db.goals)
              .get()
              .then((g) => g.where((x) => x.active).length),
          1,
        );
      },
    );

    test('reuses the given goal', () async {
      final id = await db
          .into(db.goals)
          .insert(GoalsCompanion.insert(name: 'Old', distanceM: 5000));
      await repo.savePlan(
        PlanGenerator.generate(request()),
        name: 'New',
        goalId: id,
      );
      final goal = await db.select(db.goals).getSingle();
      expect(goal.name, 'New');
      expect(goal.distanceM, 10000);
    });
  });

  group('regenerateFuture', () {
    test('replaces future planned rows and keeps finished ones', () async {
      final plan = PlanGenerator.generate(request());
      final id = await repo.savePlan(plan, name: 'A');
      final rows = await workouts();
      final future = rows.where((r) => !r.date.isBefore(now)).toList();
      final done = future[0];
      final skipped = future[1];
      final matched = future[2];
      final activity = await db
          .into(db.activities)
          .insert(
            ActivitiesCompanion.insert(
              source: ActivitySource.manual,
              startTime: matched.date,
              sport: 'running',
              durationS: 1800,
            ),
          );
      await (db.update(
        db.plannedWorkouts,
      )..where((t) => t.id.equals(done.id))).write(
        const PlannedWorkoutsCompanion(status: Value(WorkoutStatus.done)),
      );
      await (db.update(
        db.plannedWorkouts,
      )..where((t) => t.id.equals(skipped.id))).write(
        const PlannedWorkoutsCompanion(status: Value(WorkoutStatus.skipped)),
      );
      await (db.update(db.plannedWorkouts)
            ..where((t) => t.id.equals(matched.id)))
          .write(PlannedWorkoutsCompanion(activityId: Value(activity)));
      final pastIds = rows
          .where((r) => r.date.isBefore(now))
          .map((r) => r.id)
          .toSet();
      final untouchedFutureIds = future.skip(3).map((r) => r.id).toSet();

      final inserted = await repo.regenerateFuture(
        id,
        fitness: const CurrentFitness(vdot: 50),
      );

      final after = await workouts();
      final ids = after.map((r) => r.id).toSet();
      expect(ids.containsAll(pastIds), isTrue);
      expect({done.id, skipped.id, matched.id}.every(ids.contains), isTrue);
      expect(untouchedFutureIds.intersection(ids), isEmpty);

      final kept = {done.date, skipped.date, matched.date};
      final fresh = PlanGenerator.generate(request(vdot: 50));
      final expected = fresh.sessions
          .where((s) => !s.date.isBefore(now) && !kept.contains(s.date))
          .length;
      expect(inserted, expected);
      expect(after.length, pastIds.length + 3 + expected);
      expect(after.where((r) => kept.contains(r.date)).length, 3);

      final row = (await plans()).single;
      final stored = PlanRequest.fromJson(
        jsonDecode(row.requestJson) as Map<String, Object?>,
      );
      expect(stored.fitness.vdot, 50);
      expect(stored.fitness.lthr, 165);
    });

    test('without fitness keeps the stored request', () async {
      final id = await repo.savePlan(
        PlanGenerator.generate(request()),
        name: 'A',
      );
      final count = (await workouts()).length;
      await repo.regenerateFuture(id, from: DateTime(2026, 2, 16));
      expect((await workouts()).length, count);
      expect(
        PlanRequest.fromJson(
          jsonDecode((await plans()).single.requestJson)
              as Map<String, Object?>,
        ).fitness.vdot,
        45,
      );
    });

    test('rejects unknown plans', () {
      expect(() => repo.regenerateFuture(42), throwsStateError);
    });
  });

  group('deletePlan', () {
    test('removes future workouts, keeps history without a plan', () async {
      final id = await repo.savePlan(
        PlanGenerator.generate(request()),
        name: 'A',
      );
      final rows = await workouts();
      final past = rows
          .where((r) => r.date.isBefore(now))
          .map((r) => r.id)
          .toSet();
      final doneFuture = rows.firstWhere((r) => !r.date.isBefore(now));
      await (db.update(
        db.plannedWorkouts,
      )..where((t) => t.id.equals(doneFuture.id))).write(
        const PlannedWorkoutsCompanion(status: Value(WorkoutStatus.done)),
      );

      await repo.deletePlan(id);

      expect(await plans(), isEmpty);
      final after = await workouts();
      expect(after.map((r) => r.id).toSet(), {...past, doneFuture.id});
      expect(after.every((r) => r.planId == null), isTrue);
      final goal = await db.select(db.goals).getSingle();
      expect(goal.active, isFalse);
    });

    test('removes plan and goal entirely when nothing was done yet', () async {
      now = DateTime(2025, 12, 1);
      final id = await repo.savePlan(
        PlanGenerator.generate(request()),
        name: 'A',
      );
      await repo.deletePlan(id);
      expect(await plans(), isEmpty);
      expect(await workouts(), isEmpty);
      expect(await db.select(db.goals).get(), isEmpty);
    });

    test('ignores unknown plans', () async {
      await repo.deletePlan(99);
    });
  });

  test('watchWeeks groups workouts by week index', () async {
    final plan = PlanGenerator.generate(request());
    final id = await repo.savePlan(plan, name: 'A');
    final weeks = await repo.watchWeeks(id).first;
    expect(weeks.keys, [for (final w in plan.weeks) w.index]);
    for (final w in plan.weeks) {
      expect(weeks[w.index], hasLength(w.sessions.length));
    }
    expect((await repo.watchActivePlan().first)?.id, id);
  });

  test('warnings round-trip', () {
    const warnings = [PlanWarning('a', 'Message A'), PlanWarning('b', 'B')];
    final back = warningsFromJson(warningsToJson(warnings));
    expect(back.map((w) => w.toString()), warnings.map((w) => w.toString()));
  });
}
