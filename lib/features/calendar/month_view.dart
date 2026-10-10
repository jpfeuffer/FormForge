import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../data/database.dart';
import 'calendar_models.dart';
import 'calendar_providers.dart';
import 'drag_and_drop.dart';
import 'kind_style.dart';

class MonthView extends ConsumerWidget {
  const MonthView({super.key, required this.focus, required this.data});

  final DateTime focus;
  final CalendarData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = visibleRange(CalendarMode.month, focus);
    final weeks = (range.to.difference(range.from).inDays + 1) ~/ 7;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        children: [
          Row(
            children: [
              for (var d = 0; d < 7; d++)
                Expanded(
                  child: Center(
                    child: Text(
                      DateFormat.E().format(addDays(range.from, d)),
                      style: text.labelMedium,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          for (var w = 0; w < weeks; w++)
            Expanded(
              child: Row(
                children: [
                  for (var d = 0; d < 7; d++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(1.5),
                        child: _MonthCell(
                          day: addDays(range.from, w * 7 + d),
                          inMonth:
                              addDays(range.from, w * 7 + d).month ==
                              focus.month,
                          data: data,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MonthCell extends ConsumerWidget {
  const _MonthCell({
    required this.day,
    required this.inMonth,
    required this.data,
  });

  final DateTime day;
  final bool inMonth;
  final CalendarData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final today = sameDay(day, DateTime.now());
    final entries = data.on(day);
    final issues = data.issuesOn(day);
    final worst = worstSeverity(issues);

    final cell = Material(
      color: today
          ? cs.primaryContainer.withValues(alpha: .35)
          : inMonth
          ? cs.surfaceContainerLow
          : cs.surface,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          ref.read(calendarFocusProvider.notifier).set(day);
          ref.read(calendarModeProvider.notifier).set(CalendarMode.week);
        },
        child: LayoutBuilder(
          builder: (context, box) {
            final slots = ((box.maxHeight - 22) / 19).floor().clamp(0, 6);
            final shown = entries.length > slots && slots > 0
                ? slots - 1
                : slots;
            return Padding(
              padding: const EdgeInsets.all(3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        '${day.day}',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              fontWeight: today ? FontWeight.bold : null,
                              color: today
                                  ? cs.primary
                                  : inMonth
                                  ? null
                                  : cs.outline,
                            ),
                      ),
                      const Spacer(),
                      if (worst != null)
                        Icon(worst.icon, size: 13, color: worst.color(cs)),
                    ],
                  ),
                  for (final e in entries.take(shown))
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: DraggableWorkout(
                        entry: e,
                        feedbackWidth: 150,
                        child: _Chip(entry: e, profileMinutes: _minutes(e)),
                      ),
                    ),
                  if (entries.length > shown)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '+${entries.length - shown} more',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
    return DayDropTarget(day: day, data: data, radius: 8, child: cell);
  }

  int _minutes(CalendarEntry e) =>
      (e.workout.estimatedDuration(data.profile).inSeconds / 60).round();
}

class _Chip extends StatelessWidget {
  const _Chip({required this.entry, required this.profileMinutes});

  final CalendarEntry entry;
  final int profileMinutes;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = entry.kind.color(cs);
    final done = entry.row.status == WorkoutStatus.done;
    return Tooltip(
      message: entry.row.title,
      child: InkWell(
        onTap: () => context.push('/calendar/workout/${entry.id}'),
        child: Container(
          height: 17,
          padding: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: entry.isSkipped ? .08 : .22),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Icon(
                done ? Icons.check : entry.kind.icon,
                size: 11,
                color: color,
              ),
              const SizedBox(width: 2),
              Expanded(
                child: Text(
                  '${entry.row.isKey ? '★ ' : ''}$profileMinutes′',
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    decoration: entry.isSkipped
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
