import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_core/training_core.dart' hide TrainingPlan;
import 'package:training_core/training_core.dart' as core show TrainingPlan;

import '../../data/database.dart';
import '../../providers.dart';
import '../../util/format.dart';
import 'plan_providers.dart';
import 'plan_widgets.dart';

class PlanPage extends ConsumerWidget {
  const PlanPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activePlanProvider);
    final row = active.value;
    final generated = ref.watch(activeGeneratedPlanProvider);
    final Widget body;
    if (row == null || generated == null) {
      body = active.isLoading
          ? const Center(child: CircularProgressIndicator())
          : const _EmptyState();
    } else {
      body = _PlanView(row: row, plan: generated);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Plan')),
      body: body,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            Icon(
              Icons.flag,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            Text(
              'No training plan yet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Text(
              'Tell FormForge your goal, fitness and available days. It '
              'builds a periodized plan with a build-up, recovery weeks '
              'and a taper, checked against training-load guardrails.',
              textAlign: TextAlign.center,
            ),
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Create plan'),
              onPressed: () => context.push('/plan/new'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _PlanView extends ConsumerWidget {
  const _PlanView({required this.row, required this.plan});

  final TrainingPlan row;
  final core.TrainingPlan plan;

  Future<void> _regenerate(BuildContext context, WidgetRef ref) async {
    final db = ref.read(databaseProvider);
    final snapshot = await latestPacingSnapshot(db);
    final profile = await (db.select(
      db.athleteProfiles,
    )..where((t) => t.id.equals(1))).getSingleOrNull();
    final fitness = snapshot == null
        ? null
        : CurrentFitness(
            vdot: snapshot.vdot,
            mas: snapshot.masMps,
            lthr: profile?.lthr,
          );
    final n = await ref
        .read(planRepositoryProvider)
        .regenerateFuture(row.id, fitness: fitness);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          snapshot == null
              ? 'No newer fitness data; rebuilt $n upcoming workouts'
              : 'Rebuilt $n upcoming workouts from your current fitness',
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete plan?'),
        content: const Text(
          'Upcoming planned workouts are removed. Completed and past '
          'workouts stay in your history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(planRepositoryProvider).deletePlan(row.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workouts = ref.watch(activePlanWeeksProvider).value ?? const {};
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                _Header(
                  row: row,
                  plan: plan,
                  onRegenerate: () => _regenerate(context, ref),
                  onDelete: () => _delete(context, ref),
                ),
                for (final w in plan.weeks)
                  _WeekCard(
                    week: w,
                    rows: workouts[w.index] ?? const [],
                    current:
                        !today.isBefore(w.startDate) &&
                        today.isBefore(
                          w.startDate.add(const Duration(days: 7)),
                        ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.row,
    required this.plan,
    required this.onRegenerate,
    required this.onDelete,
  });

  final TrainingPlan row;
  final core.TrainingPlan plan;
  final VoidCallback onRegenerate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = plan.feasibility;
    final req = plan.request;
    final race = req.raceDate;
    Widget line(String label, String value) => Row(
      children: [
        Expanded(child: Text(label)),
        Text(value, style: theme.textTheme.bodyLarge),
      ],
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Text(row.name, style: theme.textTheme.titleLarge),
            Text(
              '${formatKm(req.goalMeters)} · '
              '${race == null ? 'ends ${formatDay(row.endDate)}' : 'race ${formatDay(race)}'}'
              ' · ${plan.weeks.length} weeks',
            ),
            const Divider(),
            line('Predicted now', formatDuration(f.predictedTime)),
            if (f.targetTime != null) ...[
              line('Target', formatDuration(f.targetTime!)),
              Align(
                alignment: Alignment.centerLeft,
                child: Chip(
                  avatar: Icon(
                    f.isRealistic ? Icons.check_circle : Icons.warning_amber,
                    size: 18,
                  ),
                  label: Text(
                    f.isRealistic
                        ? 'Target looks realistic'
                        : 'Target is ambitious',
                  ),
                ),
              ),
            ],
            line('Race pace used', '${Pace.format(f.raceSpeed)} /km'),
            for (final w in plan.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    Icon(
                      Icons.warning_amber,
                      size: 18,
                      color: theme.colorScheme.tertiary,
                    ),
                    Expanded(child: Text(w.message)),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Regenerate from current fitness'),
                  onPressed: onRegenerate,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('New plan'),
                  onPressed: () => context.push('/plan/new'),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete plan'),
                  onPressed: onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WeekCard extends StatelessWidget {
  const _WeekCard({
    required this.week,
    required this.rows,
    required this.current,
  });

  final PlanWeek week;
  final List<PlannedWorkout> rows;
  final bool current;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: ExpansionTile(
      key: PageStorageKey('week-${week.index}'),
      initiallyExpanded: current,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text('Week ${week.index + 1} · ${formatDay(week.startDate)}'),
      subtitle: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Chip(
            label: Text(phaseLabel(week.phase)),
            visualDensity: VisualDensity.compact,
          ),
          if (week.isRecovery)
            const Chip(
              avatar: Icon(Icons.hotel, size: 16),
              label: Text('Recovery'),
              visualDensity: VisualDensity.compact,
            ),
          Text(formatVolume(week.targetVolume)),
        ],
      ),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      children: [
        for (final r in rows)
          SessionRow(
            date: r.date,
            kind: r.kind,
            title: r.title,
            isKey: r.isKey,
            status: r.status,
          ),
      ],
    ),
  );
}
