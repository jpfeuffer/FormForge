import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_core/training_core.dart';

import '../../data/database.dart';
import '../../providers.dart';
import '../plan/plan_providers.dart';
import 'calendar_models.dart';
import 'calendar_repository.dart';

enum CalendarMode { week, month }

final calendarRepositoryProvider = Provider<CalendarRepository>(
  (ref) => CalendarRepository(ref.watch(databaseProvider)),
);

/// Availability of the active plan; null without a plan.
final calendarAvailabilityProvider = Provider<WeeklyAvailability?>((ref) {
  final json = ref.watch(activePlanProvider).value?.requestJson;
  if (json == null) return null;
  return PlanRequest.fromJson(jsonDecode(json) as Map<String, Object?>)
      .availability;
});

/// Real paces when known, else a conservative default for estimates.
final effectivePaceProvider = Provider<PaceProfile>(
  (ref) => ref.watch(paceProfileProvider) ?? fallbackPaceProfile,
);

class CalendarModeNotifier extends Notifier<CalendarMode> {
  @override
  CalendarMode build() => CalendarMode.week;

  void set(CalendarMode mode) => state = mode;
}

final calendarModeProvider =
    NotifierProvider<CalendarModeNotifier, CalendarMode>(
      CalendarModeNotifier.new,
    );

/// Any day inside the visible week or month.
class CalendarFocusNotifier extends Notifier<DateTime> {
  @override
  DateTime build() => dayOf(DateTime.now());

  void set(DateTime day) => state = dayOf(day);

  void today() => state = dayOf(DateTime.now());

  void step(CalendarMode mode, int direction) => state = switch (mode) {
    CalendarMode.week => addDays(state, 7 * direction),
    CalendarMode.month => DateTime(state.year, state.month + direction, 1),
  };
}

final calendarFocusProvider = NotifierProvider<CalendarFocusNotifier, DateTime>(
  CalendarFocusNotifier.new,
);

/// Id of the workout currently being dragged.
class DraggedWorkoutNotifier extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? id) => state = id;
}

final draggedWorkoutProvider = NotifierProvider<DraggedWorkoutNotifier, int?>(
  DraggedWorkoutNotifier.new,
);

final plannedRangeProvider =
    StreamProvider.family<List<PlannedWorkout>, DateRange>(
      (ref, range) => ref
          .watch(calendarRepositoryProvider)
          .watchRange(range.from, range.to),
    );

/// Rows for the visible period plus a week each side as context for the
/// checker; a single provider so the old rows stay visible while navigating.
final calendarRowsProvider = StreamProvider<List<PlannedWorkout>>((ref) {
  final range = visibleRange(
    ref.watch(calendarModeProvider),
    ref.watch(calendarFocusProvider),
  );
  return ref
      .watch(calendarRepositoryProvider)
      .watchRange(addDays(range.from, -7), addDays(range.to, 7));
});

final plannedWorkoutProvider = StreamProvider.family<PlannedWorkout?, int>(
  (ref, id) => ref.watch(calendarRepositoryProvider).watch(id),
);

final planPhasesProvider = FutureProvider.family<PlanPhases?, int>(
  (ref, planId) => ref.watch(calendarRepositoryProvider).planPhases(planId),
);

/// First to last day shown for [focus] (whole Mon–Sun weeks).
DateRange visibleRange(CalendarMode mode, DateTime focus) {
  switch (mode) {
    case CalendarMode.week:
      final start = weekStartOf(focus);
      return (from: start, to: addDays(start, 6));
    case CalendarMode.month:
      final first = DateTime(focus.year, focus.month, 1);
      final last = DateTime(focus.year, focus.month + 1, 0);
      return (from: weekStartOf(first), to: addDays(weekStartOf(last), 6));
  }
}
