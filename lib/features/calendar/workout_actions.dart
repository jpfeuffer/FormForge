import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:training_core/training_core.dart';

import '../../data/database.dart';
import 'calendar_models.dart';
import 'calendar_providers.dart';
import 'kind_style.dart';
import 'workout_editor.dart';

enum WorkoutAction { open, edit, moveTo, duplicate, toggleSkip, delete }

extension WorkoutActionMenu on WorkoutAction {
  (IconData, String) menu(CalendarEntry e) => switch (this) {
    WorkoutAction.open => (Icons.open_in_new, 'Open'),
    WorkoutAction.edit => (Icons.edit, 'Edit'),
    WorkoutAction.moveTo => (Icons.event, 'Move to…'),
    WorkoutAction.duplicate => (Icons.copy, 'Duplicate…'),
    WorkoutAction.toggleSkip =>
      e.isSkipped ? (Icons.restore, 'Restore') : (Icons.block, 'Mark skipped'),
    WorkoutAction.delete => (Icons.delete_outline, 'Delete'),
  };
}

Future<DateTime?> _pickDay(BuildContext context, DateTime initial) {
  final today = dayOf(DateTime.now());
  return showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: addDays(today, -365),
    lastDate: addDays(today, 365 * 2),
  );
}

/// Returns true when the workout was deleted.
Future<bool> runWorkoutAction(
  BuildContext context,
  WidgetRef ref,
  CalendarEntry e,
  WorkoutAction a,
) async {
  final repo = ref.read(calendarRepositoryProvider);
  switch (a) {
    case WorkoutAction.open:
      context.push('/calendar/workout/${e.id}');
    case WorkoutAction.edit:
      await showWorkoutEditor(context, existing: e);
    case WorkoutAction.moveTo:
      final d = await _pickDay(context, e.day);
      if (d != null) await repo.move(e.id, d);
    case WorkoutAction.duplicate:
      final d = await _pickDay(context, addDays(e.day, 7));
      if (d != null) await repo.duplicate(e.id, d);
    case WorkoutAction.toggleSkip:
      await repo.setStatus(
        e.id,
        e.isSkipped ? WorkoutStatus.planned : WorkoutStatus.skipped,
      );
    case WorkoutAction.delete:
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete workout?'),
          content: Text(
            '"${e.row.title}" on ${DateFormat.MMMEd().format(e.day)} will be removed.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (ok ?? false) {
        await repo.delete(e.id);
        return true;
      }
  }
  return false;
}

Future<void> showIssueSheet(
  BuildContext context,
  String title,
  Iterable<ScheduleIssue> issues,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            ListTile(
              title: Text(title, style: Theme.of(ctx).textTheme.titleMedium),
            ),
            for (final i in issues)
              ListTile(
                leading: Icon(i.severity.icon, color: i.severity.color(cs)),
                title: Text(i.message),
                subtitle: Text(DateFormat.MMMEd().format(i.date)),
              ),
          ],
        ),
      );
    },
  );
}

/// Tappable severity icon; opens the issue list.
class IssueBadge extends StatelessWidget {
  const IssueBadge({
    super.key,
    required this.issues,
    this.size = 18,
    this.title = 'Schedule check',
  });

  final List<ScheduleIssue> issues;
  final double size;
  final String title;

  @override
  Widget build(BuildContext context) {
    final worst = worstSeverity(issues);
    if (worst == null) return const SizedBox.shrink();
    return Tooltip(
      message: issues.map((i) => i.message).join('\n'),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => showIssueSheet(context, title, issues),
        child: Icon(
          worst.icon,
          size: size,
          color: worst.color(Theme.of(context).colorScheme),
        ),
      ),
    );
  }
}
