import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:training_core/training_core.dart';

import '../../data/database.dart';
import 'calendar_models.dart';
import 'strength_codec.dart';

typedef PlanPhases = ({String name, List<Phase> phases});

/// All calendar reads and writes. Garmin columns are never touched here; the
/// push service detects edits through `updatedAt`.
class CalendarRepository {
  CalendarRepository(this._db, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _now;

  Stream<List<PlannedWorkout>> watchRange(DateTime from, DateTime to) =>
      _db.watchPlanned(dayOf(from), dayOf(to));

  Stream<PlannedWorkout?> watch(int id) => (_db.select(
    _db.plannedWorkouts,
  )..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<PlannedWorkout?> get(int id) => (_db.select(
    _db.plannedWorkouts,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Plan name and per-week phases, derived like the generator does.
  Future<PlanPhases?> planPhases(int planId) async {
    final plan = await (_db.select(
      _db.trainingPlans,
    )..where((t) => t.id.equals(planId))).getSingleOrNull();
    if (plan == null) return null;
    final goal = plan.goalId == null
        ? null
        : await (_db.select(
            _db.goals,
          )..where((t) => t.id.equals(plan.goalId!))).getSingleOrNull();
    final weeks =
        (dayOf(plan.endDate).difference(dayOf(plan.startDate)).inDays ~/ 7) + 1;
    return (
      name: plan.name,
      phases: PlanRules.phases(
        weeks < 2 ? 2 : weeks,
        RaceCategory.of(goal?.distanceM ?? 21097),
      ),
    );
  }

  Future<void> move(int id, DateTime to) =>
      _update(id, PlannedWorkoutsCompanion(date: Value(dayOf(to))));

  Future<void> setStatus(int id, WorkoutStatus status) =>
      _update(id, PlannedWorkoutsCompanion(status: Value(status)));

  /// Edits metadata only; the workout structure is left as is.
  Future<void> updateDetails(
    int id, {
    required SessionKind kind,
    required DateTime date,
    int? startMinute,
    required String title,
    required bool isKey,
    String? notes,
  }) => _update(
    id,
    PlannedWorkoutsCompanion(
      kind: Value(kind),
      date: Value(dayOf(date)),
      startMinute: Value(startMinute),
      title: Value(title),
      isKey: Value(isKey),
      notes: Value(notes),
    ),
  );

  /// Copies a workout to [to] as a fresh, unsynced manual workout.
  Future<int> duplicate(int id, DateTime to) async {
    final r = await get(id);
    if (r == null) throw StateError('Workout $id not found');
    return _db
        .into(_db.plannedWorkouts)
        .insert(
          PlannedWorkoutsCompanion.insert(
            date: dayOf(to),
            startMinute: Value(r.startMinute),
            kind: r.kind,
            title: r.title,
            workoutJson: r.workoutJson,
            strengthJson: Value(r.strengthJson),
            isKey: Value(r.isKey),
            notes: Value(r.notes),
            updatedAt: Value(_now()),
          ),
        );
  }

  Future<void> delete(int id) =>
      (_db.delete(_db.plannedWorkouts)..where((t) => t.id.equals(id))).go();

  /// Inserts a manual workout, or replaces the content of [id].
  Future<int> upsertManual({
    int? id,
    required SessionKind kind,
    required DateTime date,
    int? startMinute,
    required String title,
    required Workout workout,
    StrengthSession? strength,
    bool isKey = false,
    String? notes,
  }) async {
    final json = jsonEncode(workout.toJson());
    final strengthJson = strength == null ? null : encodeStrength(strength);
    if (id != null) {
      await _update(
        id,
        PlannedWorkoutsCompanion(
          kind: Value(kind),
          date: Value(dayOf(date)),
          startMinute: Value(startMinute),
          title: Value(title),
          workoutJson: Value(json),
          strengthJson: Value(strengthJson),
          isKey: Value(isKey),
          notes: Value(notes),
        ),
      );
      return id;
    }
    return _db
        .into(_db.plannedWorkouts)
        .insert(
          PlannedWorkoutsCompanion.insert(
            date: dayOf(date),
            startMinute: Value(startMinute),
            kind: kind,
            title: title,
            workoutJson: json,
            strengthJson: Value(strengthJson),
            isKey: Value(isKey),
            notes: Value(notes),
            updatedAt: Value(_now()),
          ),
        );
  }

  /// Adds [session] to a run; the run keeps its total duration.
  Future<void> addStrengthBlock(
    int id,
    StrengthSession session,
    StrengthPlacement placement,
    PaceProfile profile,
  ) async {
    final r = await _require(id);
    final entry = CalendarEntry(r);
    final run = entry.workout.estimatedRunDuration(profile);
    if (entry.hasStrength || run <= Duration.zero) {
      throw StateError('Workout $id is not a plain run');
    }
    final intensity =
        entry.workout.steps
            .map((s) => s.target)
            .whereType<IntensityTarget>()
            .firstOrNull
            ?.intensity ??
        Intensity.easy;
    final combined = session.combineWithRun(
      run,
      placement: placement,
      intensity: intensity,
      title: '${r.title} + ${session.style.name}',
    );
    await _update(
      id,
      PlannedWorkoutsCompanion(
        kind: Value(r.kind == SessionKind.long ? r.kind : SessionKind.combined),
        title: Value(combined.title),
        workoutJson: Value(jsonEncode(combined.toJson())),
        strengthJson: Value(encodeStrength(session)),
      ),
    );
  }

  /// Turns a combined workout back into a plain run (adjacent run steps merge).
  Future<void> removeStrengthBlock(int id) async {
    final r = await _require(id);
    final entry = CalendarEntry(r);
    if (!entry.hasStrength) return;
    final merged = <WorkoutElement>[];
    for (final e in entry.workout.elements) {
      if (e is WorkoutStep && e.kind == StepKind.strength) continue;
      final last = merged.lastOrNull;
      if (e is WorkoutStep &&
          last is WorkoutStep &&
          last.end is TimeEnd &&
          e.end is TimeEnd &&
          last.kind == e.kind &&
          _sameTarget(last.target, e.target)) {
        merged[merged.length - 1] = WorkoutStep(
          kind: e.kind,
          end: TimeEnd(
            (last.end as TimeEnd).duration + (e.end as TimeEnd).duration,
          ),
          target: e.target,
        );
      } else {
        merged.add(e);
      }
    }
    final suffix = RegExp(r' \+ (calisthenics|gym)$');
    final title = r.title.replaceFirst(suffix, '');
    final run = Workout(
      sport: Sport.run,
      title: title,
      elements: merged,
      notes: entry.workout.notes,
    );
    final recovery = merged.whereType<WorkoutStep>().any(
      (s) =>
          s.target is IntensityTarget &&
          (s.target as IntensityTarget).intensity == Intensity.recovery,
    );
    await _update(
      id,
      PlannedWorkoutsCompanion(
        kind: Value(
          r.kind == SessionKind.combined
              ? (recovery ? SessionKind.recovery : SessionKind.easy)
              : r.kind,
        ),
        title: Value(title),
        workoutJson: Value(jsonEncode(run.toJson())),
        strengthJson: const Value(null),
      ),
    );
  }

  static bool _sameTarget(Target a, Target b) =>
      a is IntensityTarget &&
      b is IntensityTarget &&
      a.intensity == b.intensity;

  Future<PlannedWorkout> _require(int id) async =>
      await get(id) ?? (throw StateError('Workout $id not found'));

  Future<void> _update(int id, PlannedWorkoutsCompanion changes) =>
      (_db.update(_db.plannedWorkouts)..where((t) => t.id.equals(id))).write(
        changes.copyWith(updatedAt: Value(_now())),
      );
}
