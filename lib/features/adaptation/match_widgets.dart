import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../data/database.dart';
import '../../util/format.dart';
import '../activities/activity_providers.dart';
import 'adaptation_providers.dart';
import 'compliance_section.dart';
import 'match_providers.dart';

String _weekday(DateTime d) => DateFormat.E().format(d.toLocal());

String _runSummary(Activity a) => [
  DateFormat.MMMEd().add_Hm().format(a.startTime.toLocal()),
  if (a.distanceM != null) formatKm(a.distanceM!),
  formatDuration(Duration(seconds: a.durationS)),
].join(' · ');

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _how(PlannedWorkout p) => switch (p.linkSource) {
  LinkSource.auto =>
    'linked automatically${_score(p)}',
  LinkSource.garminWorkout => 'started from the Garmin workout',
  LinkSource.manual => 'linked manually',
  null => 'linked',
};

String _score(PlannedWorkout p) =>
    p.linkScore == null ? '' : ' (${(p.linkScore! * 100).round()} % fit)';

/// Moves the planned workout after a link when the days differ, on request.
Future<void> _announceLink(
  BuildContext context,
  WidgetRef ref,
  Activity a,
  PlannedWorkout p,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final service = ref.read(matchingServiceProvider);
  final differs = !_sameDay(p.date.toLocal(), a.startTime.toLocal());
  messenger.showSnackBar(
    SnackBar(
      content: Text('Linked to ${p.title}'),
      action: differs
          ? SnackBarAction(
              label: 'Move plan to ${_weekday(a.startTime)}',
              onPressed: () => service.moveToActivityDay(p.id),
            )
          : null,
    ),
  );
}

/// Today page: runs that fit more than one planned workout (or none well).
class MatchSuggestionCards extends ConsumerWidget {
  const MatchSuggestionCards({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingMatchesProvider).value ?? const [];
    return Column(
      children: [for (final m in pending) _PendingMatchCard(match: m)],
    );
  }
}

class _PendingMatchCard extends ConsumerWidget {
  const _PendingMatchCard({required this.match});

  final PendingMatch match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final a = match.activity;
    final service = ref.read(matchingServiceProvider);
    final top = match.choices.first;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 12,
              children: [
                const Icon(Icons.help_outline),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Was this run your ${top.planned.title} '
                        '(${_weekday(top.planned.date)})?',
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(_runSummary(a), style: theme.textTheme.bodySmall),
                      if (top.reasons.isNotEmpty)
                        Text(
                          top.reasons.take(2).join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final (i, c) in match.choices.take(2).indexed)
                  _ChoiceButton(
                    primary: i == 0,
                    label: '${c.planned.title} (${_weekday(c.planned.date)})',
                    onPressed: () async {
                      await service.acceptSuggestion(a.id, c.planned.id);
                      if (context.mounted) {
                        await _announceLink(context, ref, a, c.planned);
                      }
                    },
                  ),
                TextButton(
                  onPressed: () => service.markUnplanned(a.id),
                  child: const Text('Unplanned run'),
                ),
                TextButton(
                  onPressed: () => service.dismissSuggestions(a.id),
                  child: const Text('Not now'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({
    required this.primary,
    required this.label,
    required this.onPressed,
  });

  final bool primary;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => primary
      ? FilledButton(onPressed: onPressed, child: Text(label))
      : FilledButton.tonal(onPressed: onPressed, child: Text(label));
}

/// Today page: matches the app made on its own in the last week, with undo.
class AutoLinkedNotes extends ConsumerWidget {
  const AutoLinkedNotes({super.key});

  static const _shown = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final links = ref.watch(recentAutoLinksProvider).value ?? const [];
    if (links.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final service = ref.read(matchingServiceProvider);

    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          children: [
            for (final l in links.take(_shown))
              Row(
                children: [
                  Icon(Icons.link, size: 16, color: theme.colorScheme.outline),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InkWell(
                      onTap: () => context.go('/activities/${l.activity.id}'),
                      child: Text(
                        'Linked automatically: ${l.planned.title} ← '
                        '${DateFormat.MMMEd().format(l.activity.startTime.toLocal())}',
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => service.unlink(l.planned.id),
                    child: const Text('Undo'),
                  ),
                ],
              ),
            if (links.length > _shown)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '+${links.length - _shown} more this week',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Activity detail: which planned workout this was, with manual controls.
class PlannedLinkSection extends ConsumerWidget {
  const PlannedLinkSection({super.key, required this.activityId});

  final int activityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final planned = ref.watch(plannedForActivityProvider(activityId)).value;
    final activity = ref.watch(activityProvider(activityId)).value;
    if (activity == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final service = ref.read(matchingServiceProvider);
    final differs =
        planned != null &&
        !_sameDay(planned.date.toLocal(), activity.startTime.toLocal());

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text('Planned workout', style: theme.textTheme.titleMedium),
          if (planned != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.link),
              title: Text(planned.title),
              subtitle: Text(
                '${DateFormat.MMMEd().format(planned.date.toLocal())} · '
                '${_how(planned)}',
              ),
              onTap: () => context.push('/calendar/workout/${planned.id}'),
            )
          else
            Text(
              activity.unplanned
                  ? 'Unplanned run (confirmed)'
                  : 'Not linked to a planned workout',
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.add_link),
                label: const Text('Link to…'),
                onPressed: () => _pick(context, ref),
              ),
              if (planned != null)
                OutlinedButton.icon(
                  icon: const Icon(Icons.link_off),
                  label: const Text('Unlink'),
                  onPressed: () => service.unlink(planned.id),
                ),
              if (!activity.unplanned)
                OutlinedButton.icon(
                  icon: const Icon(Icons.directions_run),
                  label: const Text('Mark unplanned'),
                  onPressed: () => service.markUnplanned(activity.id),
                ),
              if (differs)
                OutlinedButton.icon(
                  icon: const Icon(Icons.event_repeat),
                  label: const Text('Move planned workout to this day'),
                  onPressed: () => service.moveToActivityDay(planned.id),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final choice = await showModalBottomSheet<LinkChoice>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _LinkPicker(activityId: activityId),
    );
    if (choice == null || !context.mounted) return;
    final activity = ref.read(activityProvider(activityId)).value;
    await ref.read(matchingServiceProvider).link(activityId, choice.id);
    if (activity != null && context.mounted) {
      await _announceLink(context, ref, activity, choice.planned);
    }
  }
}

/// Result of the link picker.
class LinkChoice {
  const LinkChoice(this.planned);

  final PlannedWorkout planned;

  int get id => planned.id;
}

class _LinkPicker extends ConsumerWidget {
  const _LinkPicker({required this.activityId});

  final int activityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(linkOptionsProvider(activityId));
    final theme = Theme.of(context);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Link to planned workout',
                style: theme.textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: options.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('$e'),
                ),
                data: (list) => list.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('No planned workouts nearby.'),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final o in list)
                            ListTile(
                              leading: o.planned.activityId == activityId
                                  ? const Icon(Icons.link)
                                  : const Icon(Icons.fitness_center),
                              title: Text(o.planned.title),
                              subtitle: Text(
                                '${DateFormat.MMMEd().format(o.planned.date.toLocal())}'
                                '${o.reasons.isEmpty ? '' : ' · ${o.reasons.take(2).join(' · ')}'}',
                              ),
                              trailing: Text(
                                '${(o.score * 100).round()} %',
                                style: theme.textTheme.labelLarge,
                              ),
                              onTap: () =>
                                  Navigator.pop(context, LinkChoice(o.planned)),
                            ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Workout detail: the linked activity with open and unlink actions.
class LinkedActivityTile extends ConsumerWidget {
  const LinkedActivityTile({super.key, required this.planned});

  final PlannedWorkout planned;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = planned.activityId;
    if (id == null) return const SizedBox.shrink();
    final activity = ref.watch(activityProvider(id)).value;
    if (activity == null) return const SizedBox.shrink();
    final service = ref.read(matchingServiceProvider);

    return Card(
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: Text('Done: ${_runSummary(activity)}'),
              subtitle: Text(_how(planned)),
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => context.push('/activities/$id'),
                  child: const Text('Open activity'),
                ),
                TextButton(
                  onPressed: () => service.unlink(planned.id),
                  child: const Text('Unlink'),
                ),
                if (!_sameDay(planned.date.toLocal(), activity.startTime.toLocal()))
                  TextButton(
                    onPressed: () => service.moveToActivityDay(planned.id),
                    child: Text('Move plan to ${_weekday(activity.startTime)}'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Calendar card: a small tick with what was actually run.
class LinkedActivityBadge extends ConsumerWidget {
  const LinkedActivityBadge({super.key, required this.activityId});

  final int activityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(activityProvider(activityId)).value;
    if (a == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check, size: 12, color: theme.colorScheme.primary),
        const SizedBox(width: 2),
        Flexible(
          child: Text(
            [
              '${(a.durationS / 60).round()} min',
              if (a.distanceM != null)
                '${(a.distanceM! / 1000).toStringAsFixed(1)} km',
            ].join(' · '),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
