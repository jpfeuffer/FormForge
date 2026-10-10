import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_core/training_core.dart';

import '../../data/database.dart';
import '../../providers.dart';
import '../../util/format.dart';
import 'adaptation_providers.dart';
import 'verdict_style.dart';

final plannedForActivityProvider = StreamProvider.family<PlannedWorkout?, int>((
  ref,
  activityId,
) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.plannedWorkouts)
        ..where((t) => t.activityId.equals(activityId))
        ..limit(1))
      .watch()
      .map((rows) => rows.firstOrNull);
});

/// Planned-versus-actual breakdown of an activity matched to a plan workout.
class ComplianceSection extends ConsumerWidget {
  const ComplianceSection({super.key, required this.activityId});

  final int activityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final planned = ref.watch(plannedForActivityProvider(activityId)).value;
    final compliance = planned == null ? null : parseCompliance(planned);
    if (planned == null || compliance == null) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text('Plan: ${planned.title}', style: theme.textTheme.titleMedium),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Chip(
                label: Text(compliance.verdict.label),
                avatar: Icon(
                  Icons.flag,
                  color: compliance.verdict.color(theme.colorScheme),
                ),
              ),
              Chip(label: Text('Completed ${percent(compliance.completion)}')),
              if (compliance.paceCompliance != null)
                Chip(
                  label: Text(
                    'Pace in target ${percent(compliance.paceCompliance!)}',
                  ),
                ),
              if (compliance.hrCompliance != null)
                Chip(
                  label: Text(
                    'HR in target ${percent(compliance.hrCompliance!)}',
                  ),
                ),
            ],
          ),
          for (final s in compliance.steps) _StepRow(s),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow(this.step);

  final StepCompliance step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = step.verdict;
    final planned = [
      if (step.plannedMeters != null) '${step.plannedMeters!.round()} m',
      if (step.plannedMeters == null && step.plannedSeconds != null)
        formatDuration(Duration(seconds: step.plannedSeconds!.round())),
    ].join();
    final target = [
      if (step.speedTarget != null) paceRange(step.speedTarget!),
      if (step.hrTarget != null)
        '${step.hrTarget!.lower.round()}–${step.hrTarget!.upper.round()} bpm',
    ].join(' · ');
    final actual = [
      if (step.avgSpeed != null && step.avgSpeed! > 0)
        '${Pace.format(step.avgSpeed!)} /km',
      if (step.avgHr != null) '${step.avgHr!.round()} bpm',
      if (step.paceInTarget != null)
        '${percent(step.paceInTarget!)} in pace band',
    ].join(' · ');

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(v.icon, color: v.color(theme.colorScheme)),
      title: Text(
        [
          '${step.index + 1}. ${step.kind.name}',
          if (step.intensity != null) step.intensity!.name,
          if (planned.isNotEmpty) planned,
        ].join(' · '),
      ),
      subtitle: Text(
        [
          if (target.isNotEmpty) 'Target $target',
          if (actual.isNotEmpty) 'Actual $actual',
          if (v == StepVerdict.notCompleted)
            'Executed ${percent(step.coverage)}',
        ].join('\n'),
      ),
      trailing: Text(v.label, style: theme.textTheme.labelMedium),
    );
  }
}
