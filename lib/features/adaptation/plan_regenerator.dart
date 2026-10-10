import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_core/training_core.dart' show CurrentFitness, TestType;

import '../../data/plan_repository.dart';
import '../plan/plan_providers.dart';

/// Rebuilds the not-yet-done part of a plan with new fitness.
abstract interface class PlanRegenerator {
  /// Regenerates the workouts of [planId] from [from] (default: tomorrow) on,
  /// paced with [fitness] (default: current fitness); returns the number of
  /// workouts written.
  Future<int> regenerateFuture(
    int planId, {
    DateTime? from,
    CurrentFitness? fitness,
  });
}

/// Smaller plan edits behind the other suggestion actions.
abstract interface class PlanAdjuster {
  /// Scales volume and intensity of the seven days from [from] by [factor].
  Future<void> reduceWeek(
    int planId, {
    required DateTime from,
    required double factor,
  });

  Future<void> addRecoveryDay(int planId, DateTime date);

  Future<void> scheduleTest(
    int planId,
    TestType type, {
    required DateTime from,
  });
}

final planRegeneratorProvider = Provider<PlanRegenerator?>(
  (ref) => _RepositoryRegenerator(ref.watch(planRepositoryProvider)),
);

class _RepositoryRegenerator implements PlanRegenerator {
  _RepositoryRegenerator(this._repo);
  final PlanRepository _repo;

  @override
  Future<int> regenerateFuture(int planId,
          {DateTime? from, CurrentFitness? fitness}) =>
      _repo.regenerateFuture(planId, from: from, fitness: fitness);
}

/// TODO(plan): no implementation yet; Apply stays hidden for these actions.
final planAdjusterProvider = Provider<PlanAdjuster?>((_) => null);
