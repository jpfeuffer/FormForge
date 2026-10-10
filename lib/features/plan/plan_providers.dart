import 'dart:convert';

import 'package:drift/drift.dart' show BooleanExpressionOperators, OrderingTerm;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_core/training_core.dart' hide TrainingPlan;
import 'package:training_core/training_core.dart' as core show TrainingPlan;

import '../../data/database.dart';
import '../../data/plan_repository.dart';
import '../../providers.dart';

/// KeyValues key of the wizard's last inputs.
const wizardInputsKey = 'plan.wizard';

/// Latest snapshot that can pace workouts (has VDOT or MAS).
Future<FitnessSnapshot?> latestPacingSnapshot(AppDatabase db) =>
    (db.select(db.fitnessSnapshots)
          ..where((t) => t.vdot.isNotNull() | t.masMps.isNotNull())
          ..orderBy([(t) => OrderingTerm.desc(t.date)])
          ..limit(1))
        .getSingleOrNull();

final planRepositoryProvider = Provider(
  (ref) => PlanRepository(ref.watch(databaseProvider)),
);

final activePlanProvider = StreamProvider<TrainingPlan?>(
  (ref) => ref.watch(planRepositoryProvider).watchActivePlan(),
);

/// The active plan's workouts by week index; empty without an active plan.
final activePlanWeeksProvider = StreamProvider<Map<int, List<PlannedWorkout>>>((
  ref,
) {
  final id = ref.watch(activePlanProvider.select((p) => p.value?.id));
  return id == null
      ? Stream.value(const {})
      : ref.watch(planRepositoryProvider).watchWeeks(id);
});

/// Plan structure (phases, volumes, feasibility) re-derived from the stored
/// request; the generator is deterministic.
final activeGeneratedPlanProvider = Provider<core.TrainingPlan?>((ref) {
  final row = ref.watch(activePlanProvider).value;
  if (row == null) return null;
  return PlanGenerator.generate(
    PlanRequest.fromJson(jsonDecode(row.requestJson) as Map<String, Object?>),
  );
});
