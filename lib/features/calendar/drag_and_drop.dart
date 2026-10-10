import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_core/training_core.dart';

import 'calendar_models.dart';
import 'calendar_providers.dart';
import 'kind_style.dart';
import 'workout_card.dart';

/// Long-press (touch) or press-and-hold (mouse) to drag a workout onto a day.
class DraggableWorkout extends ConsumerWidget {
  const DraggableWorkout({
    super.key,
    required this.entry,
    required this.child,
    this.feedbackWidth = 200,
  });

  final CalendarEntry entry;
  final Widget child;
  final double feedbackWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dragged = ref.read(draggedWorkoutProvider.notifier);
    return LongPressDraggable<int>(
      data: entry.id,
      delay: const Duration(milliseconds: 300),
      hapticFeedbackOnStart: true,
      onDragStarted: () => dragged.set(entry.id),
      onDragEnd: (_) => dragged.set(null),
      feedback: Material(
        color: Colors.transparent,
        elevation: 6,
        child: SizedBox(
          width: feedbackWidth,
          child: WorkoutCard(entry: entry, compact: true, showMenu: false),
        ),
      ),
      childWhenDragging: Opacity(opacity: .3, child: child),
      child: child,
    );
  }
}

/// Drop zone for one day; previews the schedule issues a drop would cause.
class DayDropTarget extends ConsumerWidget {
  const DayDropTarget({
    super.key,
    required this.day,
    required this.data,
    required this.child,
    this.radius = 12,
  });

  final DateTime day;
  final CalendarData data;
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final dragging = ref.watch(draggedWorkoutProvider) != null;
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) {
        final e = data.byId(d.data);
        return e != null && !sameDay(e.day, day);
      },
      onAcceptWithDetails: (d) {
        ref.read(draggedWorkoutProvider.notifier).set(null);
        ref.read(calendarRepositoryProvider).move(d.data, day);
      },
      builder: (context, candidates, _) {
        final hovering = candidates.isNotEmpty;
        final issues = hovering
            ? data.previewMove(candidates.first!, day)
            : const <ScheduleIssue>[];
        final worst = worstSeverity(issues);
        final accent = worst?.color(cs) ?? cs.primary;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            color: hovering ? accent.withValues(alpha: .10) : null,
            border: dragging
                ? Border.all(
                    color: hovering ? accent : cs.outlineVariant,
                    width: hovering ? 2 : 1,
                  )
                : null,
          ),
          child: Stack(
            children: [
              child,
              if (issues.isNotEmpty)
                Positioned(
                  left: 4,
                  right: 4,
                  bottom: 4,
                  child: Material(
                    color: cs.surfaceContainerHigh,
                    elevation: 3,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final i in issues)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  i.severity.icon,
                                  size: 14,
                                  color: i.severity.color(cs),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    i.message,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
