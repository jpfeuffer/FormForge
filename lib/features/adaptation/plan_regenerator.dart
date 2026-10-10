import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_core/training_core.dart' show CurrentFitness, TestType;

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

/// TODO(plan): override with a `PlanRepository.regenerateFuture` adapter;
/// until then Apply is disabled for plan changes.
final planRegeneratorProvider = Provider<PlanRegenerator?>((_) => null);

/// TODO(plan): no implementation yet.
final planAdjusterProvider = Provider<PlanAdjuster?>((_) => null);
