import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'calendar_models.dart';
import 'calendar_providers.dart';
import 'drag_and_drop.dart';
import 'workout_actions.dart';
import 'workout_card.dart';
import 'workout_editor.dart';

const wideBreakpoint = 900.0;

ValueKey<String> dayKey(DateTime d) =>
    ValueKey('day-${DateFormat('yyyy-MM-dd').format(d)}');

class WeekView extends ConsumerStatefulWidget {
  const WeekView({super.key, required this.weekStart, required this.data});

  final DateTime weekStart;
  final CalendarData data;

  @override
  ConsumerState<WeekView> createState() => _WeekViewState();
}

class _WeekViewState extends ConsumerState<WeekView> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// The list has no built-in drag scrolling, so nudge it near the edges.
  void _autoScroll(PointerMoveEvent e) {
    if (ref.read(draggedWorkoutProvider) == null || !_scroll.hasClients) return;
    final box = context.findRenderObject() as RenderBox;
    final y = box.globalToLocal(e.position).dy;
    const edge = 72.0;
    final delta = y < edge ? -16.0 : (y > box.size.height - edge ? 16.0 : 0.0);
    if (delta == 0) return;
    _scroll.jumpTo(
      (_scroll.offset + delta).clamp(
        _scroll.position.minScrollExtent,
        _scroll.position.maxScrollExtent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final days = [for (var i = 0; i < 7; i++) addDays(widget.weekStart, i)];
    final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
    if (wide) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final d in days)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: DayPanel(
                    key: dayKey(d),
                    day: d,
                    data: widget.data,
                    compact: true,
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return Listener(
      onPointerMove: _autoScroll,
      child: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 88),
        children: [
          for (final d in days)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: DayPanel(key: dayKey(d), day: d, data: widget.data),
            ),
        ],
      ),
    );
  }
}

/// One day: header with add button and issue badge, its workouts, drop zone.
class DayPanel extends ConsumerWidget {
  const DayPanel({
    super.key,
    required this.day,
    required this.data,
    this.compact = false,
  });

  final DateTime day;
  final CalendarData data;

  /// Full-height column (wide layout) instead of a list tile.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final today = sameDay(day, DateTime.now());
    final entries = data.on(day);
    final issues = data.issuesOn(day);

    final header = Row(
      children: [
        Expanded(
          child: Text(
            compact
                ? DateFormat('E d').format(day)
                : DateFormat('EEEE, d MMM').format(day),
            style: text.titleSmall?.copyWith(
              color: today ? cs.primary : null,
              fontWeight: today ? FontWeight.bold : null,
            ),
          ),
        ),
        IssueBadge(issues: issues, title: DateFormat.MMMEd().format(day)),
        SizedBox(
          width: 32,
          height: 32,
          child: IconButton(
            padding: EdgeInsets.zero,
            iconSize: 20,
            tooltip: 'Add workout on ${DateFormat.MMMEd().format(day)}',
            icon: const Icon(Icons.add),
            onPressed: () => showWorkoutEditor(context, date: day),
          ),
        ),
      ],
    );

    final cards = [
      for (final e in entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: DraggableWorkout(
            entry: e,
            feedbackWidth: compact ? 160 : 260,
            child: WorkoutCard(
              entry: e,
              compact: compact,
              issues: data.issuesFor(e.id),
            ),
          ),
        ),
    ];

    final body = Container(
      decoration: BoxDecoration(
        color: today
            ? cs.primaryContainer.withValues(alpha: .25)
            : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(right: 6, bottom: 56),
                    children: [
                      ...cards,
                      if (entries.isEmpty)
                        Text(
                          'Rest',
                          style: text.bodySmall?.copyWith(color: cs.outline),
                        ),
                    ],
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                if (entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      'Rest',
                      style: text.bodySmall?.copyWith(color: cs.outline),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Column(children: cards),
                ),
              ],
            ),
    );
    return DayDropTarget(day: day, data: data, child: body);
  }
}
