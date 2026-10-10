import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:training_core/training_core.dart';

import '../../providers.dart';
import 'calendar_models.dart';
import 'calendar_providers.dart';
import 'kind_style.dart';
import 'month_view.dart';
import 'week_view.dart';
import 'workout_actions.dart';
import 'workout_editor.dart';

class CalendarPage extends ConsumerWidget {
  const CalendarPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(calendarModeProvider);
    final focus = ref.watch(calendarFocusProvider);
    final range = visibleRange(mode, focus);
    final rows = ref.watch(calendarRowsProvider);
    final data = CalendarData(
      rows.value ?? const [],
      ref.watch(effectivePaceProvider),
      ref.watch(calendarAvailabilityProvider),
    );
    final nav = ref.read(calendarFocusProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: Text(_title(mode, range, focus)),
        actions: [
          IconButton(
            tooltip: 'Previous',
            onPressed: () => nav.step(mode, -1),
            icon: const Icon(Icons.chevron_left),
          ),
          TextButton(onPressed: nav.today, child: const Text('Today')),
          IconButton(
            tooltip: 'Next',
            onPressed: () => nav.step(mode, 1),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
      body: Column(
        children: [
          _Header(mode: mode, range: range, data: data),
          Expanded(
            child: mode == CalendarMode.week
                ? WeekView(weekStart: range.from, data: data)
                : MonthView(focus: focus, data: data),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showWorkoutEditor(context, date: focus),
        icon: const Icon(Icons.add),
        label: const Text('Workout'),
      ),
    );
  }

  static String _title(CalendarMode mode, DateRange range, DateTime focus) {
    if (mode == CalendarMode.month) return DateFormat.yMMMM().format(focus);
    final a = range.from;
    final b = range.to;
    return a.month == b.month
        ? '${a.day}–${b.day} ${DateFormat.yMMM().format(b)}'
        : '${DateFormat.MMMd().format(a)} – ${DateFormat.yMMMd().format(b)}';
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.mode, required this.range, required this.data});

  final CalendarMode mode;
  final DateRange range;
  final CalendarData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final week = mode == CalendarMode.week;
    final vol = data.volume(range.from, range.to);
    final weekly = week
        ? data.weeklyIssues(range.from)
        : const <ScheduleIssue>[];
    final planned = week
        ? data.entries
              .where(
                (e) =>
                    !e.day.isBefore(range.from) &&
                    !e.day.isAfter(range.to) &&
                    e.row.planId != null &&
                    e.row.weekIndex != null,
              )
              .firstOrNull
        : null;
    final plan = planned == null
        ? null
        : ref.watch(planPhasesProvider(planned.row.planId!)).value;
    final weekIndex = planned?.row.weekIndex;
    final phase = plan == null || weekIndex! >= plan.phases.length
        ? null
        : plan.phases[weekIndex];
    final estimated = ref.watch(paceProfileProvider) == null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<CalendarMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: CalendarMode.week,
                icon: Icon(Icons.view_week),
                label: Text('Week'),
              ),
              ButtonSegment(
                value: CalendarMode.month,
                icon: Icon(Icons.calendar_view_month),
                label: Text('Month'),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (s) =>
                ref.read(calendarModeProvider.notifier).set(s.first),
          ),
          Tooltip(
            message: estimated
                ? 'Estimated with default paces; log a test or race for personal paces'
                : 'Estimated from your current paces',
            child: Text(
              '${week ? 'Week' : 'Month'}: ${formatMinutes(vol.run)} running · '
              '${formatKmShort(vol.meters)}${estimated ? ' (est.)' : ''}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          if (plan != null)
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.flag, size: 16),
              label: Text(
                '${plan.name}'
                '${phase == null ? '' : ' · ${toBeginningOfSentenceCase(phase.name)}'}'
                ' · week ${weekIndex! + 1}',
              ),
            ),
          if (weekly.isNotEmpty)
            ActionChip(
              visualDensity: VisualDensity.compact,
              avatar: Icon(
                worstSeverity(weekly)!.icon,
                size: 16,
                color: worstSeverity(weekly)!.color(cs),
              ),
              label: Text(
                weekly.length == 1
                    ? weekly.first.message
                    : '${weekly.length} week warnings',
              ),
              onPressed: () => showIssueSheet(context, 'This week', weekly),
            ),
        ],
      ),
    );
  }
}
