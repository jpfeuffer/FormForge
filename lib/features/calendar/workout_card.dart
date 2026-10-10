import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_core/training_core.dart';

import '../../data/database.dart';
import '../adaptation/match_widgets.dart';
import 'calendar_models.dart';
import 'calendar_providers.dart';
import 'kind_style.dart';
import 'workout_actions.dart';

class WorkoutCard extends ConsumerWidget {
  const WorkoutCard({
    super.key,
    required this.entry,
    this.compact = false,
    this.showMenu = true,
    this.issues = const [],
  });

  final CalendarEntry entry;

  /// Narrow layout for week columns: badges are icon-only.
  final bool compact;
  final bool showMenu;
  final List<ScheduleIssue> issues;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final profile = ref.watch(effectivePaceProvider);
    final color = entry.kind.color(cs);
    final skipped = entry.isSkipped;
    final w = entry.workout;
    final meters = w.estimatedDistance(profile);
    final meta = [
      if (entry.row.startMinute case final m?) formatClock(m),
      formatMinutes(w.estimatedDuration(profile)),
      if (meters > 0 && !compact) formatKmShort(meters),
    ].join(' · ');

    return Material(
      color: Color.alphaBlend(color.withValues(alpha: .12), cs.surface),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/calendar/workout/${entry.id}'),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: color, width: 4)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(entry.kind.icon, size: 16, color: color),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        entry.row.title,
                        maxLines: compact ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall?.copyWith(
                          decoration: skipped
                              ? TextDecoration.lineThrough
                              : null,
                          color: skipped ? cs.outline : null,
                        ),
                      ),
                    ),
                    if (showMenu) _Menu(entry: entry),
                  ],
                ),
                Text(meta, style: text.bodySmall?.copyWith(color: cs.outline)),
                if (entry.row.activityId case final id?)
                  LinkedActivityBadge(activityId: id),
                const SizedBox(height: 2),
                Wrap(
                  spacing: 4,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (entry.row.isKey)
                      _Badge(Icons.star, 'Key', cs.primary, compact: compact),
                    ..._statusBadges(cs),
                    if (entry.garmin == GarminSync.synced)
                      _Badge(
                        Icons.watch,
                        'Synced to Garmin',
                        cs.primary,
                        compact: true,
                      ),
                    if (entry.garmin == GarminSync.changed)
                      _Badge(
                        Icons.sync_problem,
                        'Changed since Garmin sync',
                        cs.tertiary,
                        compact: true,
                      ),
                    if (issues.isNotEmpty)
                      IssueBadge(
                        issues: issues,
                        size: 16,
                        title: entry.row.title,
                      ),
                    if (entry.hasStrength && !compact)
                      for (final f in entry.focusAreas.take(3)) _FocusChip(f),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _statusBadges(ColorScheme cs) {
    final today = dayOf(DateTime.now());
    return switch (entry.row.status) {
      WorkoutStatus.done => [
        _Badge(Icons.check_circle, 'Done', cs.primary, compact: compact),
      ],
      WorkoutStatus.partial => [
        _Badge(Icons.timelapse, 'Partial', cs.tertiary, compact: compact),
      ],
      WorkoutStatus.skipped => [
        _Badge(Icons.block, 'Skipped', cs.outline, compact: compact),
      ],
      WorkoutStatus.planned when entry.isMissed(today) => [
        _Badge(Icons.event_busy, 'Missed', cs.error, compact: compact),
      ],
      _ => const [],
    };
  }
}

class _Menu extends ConsumerWidget {
  const _Menu({required this.entry});

  final CalendarEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SizedBox(
    width: 28,
    height: 28,
    child: PopupMenuButton<WorkoutAction>(
      padding: EdgeInsets.zero,
      iconSize: 18,
      tooltip: 'Workout actions',
      onSelected: (a) => runWorkoutAction(context, ref, entry, a),
      itemBuilder: (_) => [
        for (final a in WorkoutAction.values)
          PopupMenuItem(
            value: a,
            child: Row(
              children: [
                Icon(a.menu(entry).$1, size: 18),
                const SizedBox(width: 12),
                Text(a.menu(entry).$2),
              ],
            ),
          ),
      ],
    ),
  );
}

class _Badge extends StatelessWidget {
  const _Badge(this.icon, this.label, this.color, {this.compact = false});

  final IconData icon;
  final String label;
  final Color color;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: color);
    return Tooltip(
      message: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          if (!compact) ...[
            const SizedBox(width: 2),
            Text(label, style: style),
          ],
        ],
      ),
    );
  }
}

class _FocusChip extends StatelessWidget {
  const _FocusChip(this.area);

  final FocusArea area;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Text(area.label, style: Theme.of(context).textTheme.labelSmall),
      ),
    );
  }
}
