import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:training_core/training_core.dart' hide TrainingPlan;
import 'package:training_core/training_core.dart' as core show TrainingPlan;

import 'database.dart';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

String warningsToJson(Iterable<PlanWarning> warnings) => jsonEncode([
  for (final w in warnings) {'code': w.code, 'message': w.message},
]);

List<PlanWarning> warningsFromJson(String json) => [
  for (final w in jsonDecode(json) as List)
    PlanWarning((w as Map)['code'] as String, w['message'] as String),
];

/// Persists generated training plans as [TrainingPlans] + [PlannedWorkouts].
class PlanRepository {
  PlanRepository(this._db, {this._now = DateTime.now});

  final AppDatabase _db;
  final DateTime Function() _now;

  Stream<TrainingPlan?> watchActivePlan() =>
      (_db.select(_db.trainingPlans)
            ..where((t) => t.active.equals(true))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
            ..limit(1))
          .watchSingleOrNull();

  Stream<List<PlannedWorkout>> watchWorkouts(int planId) =>
      (_db.select(_db.plannedWorkouts)
            ..where((t) => t.planId.equals(planId))
            ..orderBy([
              (t) => OrderingTerm.asc(t.date),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .watch();

  /// Workouts of the plan keyed by week index, in week and date order.
  Stream<Map<int, List<PlannedWorkout>>> watchWeeks(int planId) =>
      watchWorkouts(planId).map((rows) {
        final out = <int, List<PlannedWorkout>>{};
        for (final r in rows) {
          (out[r.weekIndex ?? 0] ??= []).add(r);
        }
        return out;
      });

  /// Makes [plan] the only active plan; the previous plan's future
  /// `planned` workouts are removed, its history stays.
  Future<int> savePlan(
    core.TrainingPlan plan, {
    required String name,
    int? goalId,
  }) => _db.transaction(() async {
    final req = plan.request;
    final today = _day(_now());

    final previous = await (_db.select(
      _db.trainingPlans,
    )..where((t) => t.active.equals(true))).get();
    for (final p in previous) {
      await _removeFuture(p.id, today);
    }
    await (_db.update(_db.trainingPlans)..where((t) => t.active.equals(true)))
        .write(const TrainingPlansCompanion(active: Value(false)));
    await (_db.update(_db.goals)..where((t) => t.active.equals(true))).write(
      const GoalsCompanion(active: Value(false)),
    );

    final goal = GoalsCompanion(
      name: Value(name),
      distanceM: Value(req.goalMeters),
      targetTimeS: Value(req.targetTime?.inSeconds),
      raceDate: Value(req.raceDate),
      active: const Value(true),
    );
    final int gid;
    if (goalId == null) {
      gid = await _db.into(_db.goals).insert(goal);
    } else {
      await (_db.update(
        _db.goals,
      )..where((t) => t.id.equals(goalId))).write(goal);
      gid = goalId;
    }

    final planId = await _db
        .into(_db.trainingPlans)
        .insert(
          TrainingPlansCompanion.insert(
            goalId: Value(gid),
            name: name,
            startDate: plan.weeks.first.startDate,
            endDate: plan.sessions
                .map((s) => s.date)
                .reduce((a, b) => a.isAfter(b) ? a : b),
            requestJson: jsonEncode(req.toJson()),
            warningsJson: Value(warningsToJson(plan.warnings)),
          ),
        );
    await _insertSessions(planId, gid, plan.weeks, (_) => true);
    return planId;
  });

  /// Removes future, untouched workouts. Past and completed workouts stay as
  /// history without a plan; the goal goes with the plan unless history
  /// still refers to it.
  Future<void> deletePlan(int planId) => _db.transaction(() async {
    final plan = await _plan(planId);
    if (plan == null) return;
    await _removeFuture(planId, _day(_now()));
    await (_db.update(_db.plannedWorkouts)
          ..where((t) => t.planId.equals(planId)))
        .write(const PlannedWorkoutsCompanion(planId: Value(null)));
    await (_db.delete(
      _db.trainingPlans,
    )..where((t) => t.id.equals(planId))).go();

    final gid = plan.goalId;
    if (gid == null) return;
    final usedByWorkout =
        await (_db.select(_db.plannedWorkouts)
              ..where((t) => t.goalId.equals(gid))
              ..limit(1))
            .get();
    final usedByPlan =
        await (_db.select(_db.trainingPlans)
              ..where((t) => t.goalId.equals(gid))
              ..limit(1))
            .get();
    if (usedByWorkout.isEmpty && usedByPlan.isEmpty) {
      await (_db.delete(_db.goals)..where((t) => t.id.equals(gid))).go();
    } else {
      await (_db.update(_db.goals)..where((t) => t.id.equals(gid))).write(
        const GoalsCompanion(active: Value(false)),
      );
    }
  });

  /// Re-runs the generator on the stored request (optionally with new
  /// [fitness]) and replaces the `planned` workouts from [from] (default
  /// today) on. Done, partial and skipped workouts, and anything with a
  /// matched activity, are kept and block new sessions on the same day.
  /// Returns the number of workouts inserted.
  Future<int> regenerateFuture(
    int planId, {
    DateTime? from,
    CurrentFitness? fitness,
  }) => _db.transaction(() async {
    final row = await _plan(planId);
    if (row == null) throw StateError('Unknown plan $planId');
    final stored = PlanRequest.fromJson(
      jsonDecode(row.requestJson) as Map<String, Object?>,
    );
    final request = fitness == null
        ? stored
        : stored.withFitness(
            CurrentFitness(
              vdot: fitness.vdot,
              mas: fitness.mas,
              lthr: fitness.lthr ?? stored.fitness.lthr,
            ),
          );
    final plan = PlanGenerator.generate(request);
    final start = _day(from ?? _now());

    await _removeFuture(planId, start);
    final kept = await (_db.select(
      _db.plannedWorkouts,
    )..where((t) => t.planId.equals(planId))).get();
    final occupied = {for (final r in kept) _day(r.date)};

    final inserted = await _insertSessions(
      planId,
      row.goalId,
      plan.weeks,
      (s) => !s.date.isBefore(start) && !occupied.contains(_day(s.date)),
    );
    await (_db.update(
      _db.trainingPlans,
    )..where((t) => t.id.equals(planId))).write(
      TrainingPlansCompanion(
        requestJson: Value(jsonEncode(request.toJson())),
        warningsJson: Value(warningsToJson(plan.warnings)),
      ),
    );
    return inserted;
  });

  Future<TrainingPlan?> _plan(int id) => (_db.select(
    _db.trainingPlans,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> _removeFuture(int planId, DateTime from) =>
      (_db.delete(_db.plannedWorkouts)..where(
            (t) =>
                t.planId.equals(planId) &
                t.status.equals(WorkoutStatus.planned.name) &
                t.activityId.isNull() &
                t.date.isBiggerOrEqualValue(from),
          ))
          .go();

  Future<int> _insertSessions(
    int planId,
    int? goalId,
    List<PlanWeek> weeks,
    bool Function(PlannedSession) include,
  ) async {
    final rows = [
      for (final w in weeks)
        for (final s in w.sessions.where(include))
          PlannedWorkoutsCompanion.insert(
            planId: Value(planId),
            goalId: Value(goalId),
            weekIndex: Value(w.index),
            date: _day(s.date),
            kind: s.kind,
            title: s.workout.title,
            workoutJson: jsonEncode(s.workout.toJson()),
            strengthJson: Value(
              s.strength == null ? null : jsonEncode(s.strength!.toJson()),
            ),
            isKey: Value(s.isKey),
          ),
    ];
    await _db.batch((b) => b.insertAll(_db.plannedWorkouts, rows));
    return rows.length;
  }
}
