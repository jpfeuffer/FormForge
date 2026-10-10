import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:training_core/training_core.dart';

import '../../data/database.dart';
import '../../integrations/garmin/garmin_sync_providers.dart';
import '../../providers.dart';
import '../../util/format.dart';
import '../adaptation/adaptation_providers.dart';
import '../adaptation/verdict_style.dart';
import 'load_card.dart';
import 'suggestion_card.dart';
import 'workout_text.dart';

class TodayPage extends ConsumerWidget {
  const TodayPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Starts the optional sync on app start (once per app run).
    ref.watch(garminStartupSyncProvider);
    final suggestions =
        ref.watch(adaptationSuggestionsProvider).value ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('Today')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final s in suggestions) SuggestionCard(suggestion: s),
          const _PlannedToday(),
          const SizedBox(height: 8),
          const _LastEvaluation(),
          const SizedBox(height: 8),
          const _FitnessCard(),
          const SizedBox(height: 8),
          const LoadCard(),
        ],
      ),
    );
  }
}

class _PlannedToday extends ConsumerWidget {
  const _PlannedToday();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(todaysWorkoutsProvider).value ?? const [];
    final profile = ref.watch(paceProfileProvider);
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('Planned today', style: text.titleMedium),
        ),
        if (items.isEmpty)
          const Card(child: ListTile(title: Text('Nothing planned'))),
        for (final w in items) _WorkoutCard(workout: w, profile: profile),
      ],
    );
  }
}

class _WorkoutCard extends StatelessWidget {
  const _WorkoutCard({required this.workout, required this.profile});

  final PlannedWorkout workout;
  final PaceProfile? profile;

  @override
  Widget build(BuildContext context) {
    final w = _parse(workout);
    final theme = Theme.of(context);
    final duration = w == null || profile == null
        ? null
        : w.estimatedDuration(profile!);
    final done =
        workout.status == WorkoutStatus.done ||
        workout.status == WorkoutStatus.partial;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Row(
              spacing: 8,
              children: [
                Icon(
                  done ? Icons.check_circle : Icons.fitness_center,
                  color: done ? Colors.green : null,
                ),
                Expanded(
                  child: Text(workout.title, style: theme.textTheme.titleSmall),
                ),
                if (workout.isKey) const Chip(label: Text('Key')),
                if (workout.status == WorkoutStatus.partial)
                  const Chip(label: Text('Partial')),
              ],
            ),
            Text(
              [
                workout.kind.name,
                if (duration != null && duration > Duration.zero)
                  '~${formatDuration(duration)}',
              ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
            if (w != null)
              for (final line in describeWorkout(w, profile))
                Padding(
                  padding: EdgeInsets.only(left: 12.0 * line.depth),
                  child: Text(line.text, style: theme.textTheme.bodyMedium),
                ),
            if (workout.activityId != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () =>
                      context.go('/activities/${workout.activityId}'),
                  child: const Text('View activity'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static Workout? _parse(PlannedWorkout p) {
    try {
      return Workout.fromJson(
        (jsonDecode(p.workoutJson) as Map).cast<String, Object?>(),
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

class _LastEvaluation extends ConsumerWidget {
  const _LastEvaluation();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final last = ref.watch(lastEvaluationProvider);
    if (last == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final (:workout, :compliance) = last;
    final ratio = compliance.speedRatio;

    return Card(
      child: InkWell(
        onTap: workout.activityId == null
            ? null
            : () => context.go('/activities/${workout.activityId}'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Text('Last evaluated run', style: theme.textTheme.titleMedium),
              Text(
                '${workout.title} · ${DateFormat.MMMEd().format(workout.date)}',
              ),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  Chip(
                    avatar: Icon(
                      Icons.flag,
                      color: compliance.verdict.color(theme.colorScheme),
                    ),
                    label: Text(compliance.verdict.label),
                  ),
                  Chip(
                    label: Text('Completed ${percent(compliance.completion)}'),
                  ),
                  if (compliance.paceCompliance != null)
                    Chip(
                      label: Text(
                        'Pace ${percent(compliance.paceCompliance!)} in target',
                      ),
                    ),
                  if (compliance.hrCompliance != null)
                    Chip(
                      label: Text(
                        'HR ${percent(compliance.hrCompliance!)} in target',
                      ),
                    ),
                  if (ratio != null)
                    Chip(
                      label: Text(
                        '${ratio >= 1 ? '+' : ''}${((ratio - 1) * 100).toStringAsFixed(1)} % vs planned pace',
                      ),
                    ),
                  if (compliance.decoupling != null)
                    Chip(
                      label: Text(
                        'Decoupling ${compliance.decoupling!.toStringAsFixed(1)} %',
                      ),
                    ),
                ],
              ),
              for (final s in compliance.steps.where(
                (s) =>
                    s.kind == StepKind.active &&
                    s.verdict != StepVerdict.onTarget,
              ))
                Row(
                  spacing: 8,
                  children: [
                    Icon(
                      s.verdict.icon,
                      size: 16,
                      color: s.verdict.color(theme.colorScheme),
                    ),
                    Text('Step ${s.index + 1}: ${s.verdict.label}'),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FitnessCard extends ConsumerWidget {
  const _FitnessCard();

  static const _races = {
    '5 km': 5000.0,
    '10 km': 10000.0,
    'Half marathon': 21097.5,
    'Marathon': 42195.0,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fitness = ref.watch(latestFitnessProvider).value;
    final theme = Theme.of(context);
    final vdot =
        fitness?.vdot ?? ref.watch(paceProfileProvider)?.vdotEquivalent;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            Text('Current fitness', style: theme.textTheme.titleMedium),
            Text(switch (fitness) {
              FitnessSnapshot(vdot: final v?) => 'VDOT ${v.toStringAsFixed(1)}',
              FitnessSnapshot(masMps: final m?) =>
                'MAS ${Pace.kmh(m).toStringAsFixed(1)} km/h'
                    '${vdot == null ? '' : ' (VDOT ≈ ${vdot.toStringAsFixed(1)})'}',
              _ => 'No test logged yet – see Fitness',
            }),
            if (vdot != null) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  for (final e in _races.entries)
                    Text(
                      '${e.key} ${formatDuration(Vdot.predictTime(vdot, e.value))}',
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
