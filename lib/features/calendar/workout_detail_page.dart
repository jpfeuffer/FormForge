import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:training_core/training_core.dart';

import '../../data/database.dart';
import '../../providers.dart';
import '../adaptation/match_widgets.dart';
import 'calendar_models.dart';
import 'calendar_providers.dart';
import 'kind_style.dart';
import 'workout_actions.dart';
import 'workout_editor.dart';
import 'workout_spec.dart';

class WorkoutDetailPage extends ConsumerWidget {
  const WorkoutDetailPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final row = ref.watch(plannedWorkoutProvider(id));
    final entry = row.value == null ? null : CalendarEntry(row.value!);
    if (entry == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: row.isLoading
              ? const CircularProgressIndicator()
              : const Text('Workout not found'),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(entry.row.title),
        actions: [
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit),
            onPressed: () => showWorkoutEditor(context, existing: entry),
          ),
          PopupMenuButton<WorkoutAction>(
            onSelected: (a) async {
              final deleted = await runWorkoutAction(context, ref, entry, a);
              if (deleted && context.mounted) {
                context.canPop() ? context.pop() : context.go('/calendar');
              }
            },
            itemBuilder: (_) => [
              for (final a in [
                WorkoutAction.moveTo,
                WorkoutAction.duplicate,
                WorkoutAction.toggleSkip,
                WorkoutAction.delete,
              ])
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
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: _Body(entry: entry),
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.entry});

  final CalendarEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final profile = ref.watch(effectivePaceProvider);
    final estimated = ref.watch(paceProfileProvider) == null;
    final w = entry.workout;
    final r = entry.row;
    final meters = w.estimatedDistance(profile);
    final note = r.notes ?? w.notes;
    final issues = ref
        .watch(
          plannedRangeProvider((
            from: addDays(entry.day, -14),
            to: addDays(entry.day, 14),
          )),
        )
        .value;
    final itemIssues = issues == null
        ? const <ScheduleIssue>[]
        : CalendarData(
            issues,
            profile,
            ref.watch(calendarAvailabilityProvider),
          ).issuesFor(entry.id);
    final canAddStrength =
        !entry.hasStrength &&
        const {
          SessionKind.easy,
          SessionKind.recovery,
          SessionKind.long,
        }.contains(entry.kind) &&
        w.estimatedRunDuration(profile) > Duration.zero;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Chip(
              avatar: Icon(
                entry.kind.icon,
                size: 18,
                color: entry.kind.color(cs),
              ),
              label: Text(entry.kind.label),
            ),
            Text(
              '${DateFormat.yMMMEd().format(entry.day)}'
              '${r.startMinute == null ? '' : ' · ${formatClock(r.startMinute!)}'}',
              style: text.titleMedium,
            ),
            if (r.isKey)
              const Chip(
                avatar: Icon(Icons.star, size: 16),
                label: Text('Key'),
              ),
            if (r.status != WorkoutStatus.planned)
              Chip(label: Text(toBeginningOfSentenceCase(r.status.name))),
            if (entry.garmin != GarminSync.none)
              Chip(
                avatar: Icon(
                  entry.garmin == GarminSync.synced
                      ? Icons.watch
                      : Icons.sync_problem,
                  size: 16,
                ),
                label: Text(
                  entry.garmin == GarminSync.synced
                      ? 'On Garmin'
                      : 'Changed since Garmin sync',
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _Stat('Duration', formatMinutes(w.estimatedDuration(profile))),
            if (meters > 0) _Stat('Distance', formatKmShort(meters)),
            _Stat('Load', w.estimatedLoad(profile).round().toString()),
          ],
        ),
        LinkedActivityTile(planned: r),
        if (estimated)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Paces are estimates from a default fitness level. Log a test or race for personal paces.',
              style: text.bodySmall?.copyWith(color: cs.outline),
            ),
          ),
        for (final i in itemIssues)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(i.severity.icon, color: i.severity.color(cs)),
            title: Text(i.message),
          ),
        if (note != null && note.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(note, style: text.bodyMedium),
        ],
        const SizedBox(height: 16),
        Text('Steps', style: text.titleMedium),
        const SizedBox(height: 4),
        if (w.elements.isEmpty)
          const ListTile(title: Text('No structured steps'))
        else
          for (final e in w.elements) _Element(element: e, profile: profile),
        if (entry.hasStrength) ...[
          const SizedBox(height: 16),
          Text('Strength', style: text.titleMedium),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            children: [
              for (final f in entry.focusAreas) Chip(label: Text(f.label)),
            ],
          ),
          if (entry.strength != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(entry.strength!.description, style: text.bodySmall),
            ),
          if (w.sport == Sport.combined)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.remove_circle_outline),
                label: const Text('Remove strength block'),
                onPressed: () => ref
                    .read(calendarRepositoryProvider)
                    .removeStrengthBlock(entry.id),
              ),
            ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (canAddStrength)
              FilledButton.tonalIcon(
                icon: const Icon(Icons.fitness_center),
                label: const Text('Add strength block'),
                onPressed: () => _addStrength(context, ref, profile),
              ),
            OutlinedButton.icon(
              icon: Icon(entry.isSkipped ? Icons.restore : Icons.block),
              label: Text(entry.isSkipped ? 'Restore' : 'Mark skipped'),
              onPressed: () => runWorkoutAction(
                context,
                ref,
                entry,
                WorkoutAction.toggleSkip,
              ),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Duplicate…'),
              onPressed: () => runWorkoutAction(
                context,
                ref,
                entry,
                WorkoutAction.duplicate,
              ),
            ),
            OutlinedButton.icon(
              icon: Icon(Icons.delete_outline, color: cs.error),
              label: Text('Delete', style: TextStyle(color: cs.error)),
              onPressed: () async {
                final deleted = await runWorkoutAction(
                  context,
                  ref,
                  entry,
                  WorkoutAction.delete,
                );
                if (deleted && context.mounted) {
                  context.canPop() ? context.pop() : context.go('/calendar');
                }
              },
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _addStrength(
    BuildContext context,
    WidgetRef ref,
    PaceProfile profile,
  ) async {
    final spec = StrengthSpec();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Add strength block'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: StrengthFields(
                spec: spec,
                showPlacement: true,
                onChanged: () => setState(() {}),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: spec.focusAreas.isEmpty || spec.minutes <= 0
                  ? null
                  : () => Navigator.pop(ctx, true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (ok ?? false) {
      await ref
          .read(calendarRepositoryProvider)
          .addStrengthBlock(entry.id, spec.session, spec.placement, profile);
    }
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Text(value, style: Theme.of(context).textTheme.headlineSmall),
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: Theme.of(context).colorScheme.outline),
        ),
      ],
    ),
  );
}

class _Element extends StatelessWidget {
  const _Element({required this.element, required this.profile});

  final WorkoutElement element;
  final PaceProfile profile;

  @override
  Widget build(BuildContext context) {
    final e = element;
    if (e is WorkoutStep) return _StepTile(step: e, profile: profile);
    final block = e as RepeatBlock;
    final once = [for (final el in block.elements) ...el.steps];
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      leading: const Icon(Icons.repeat),
      title: Text(
        '${block.times} × ${once.map((s) => _endLabel(s.end)).join(' + ')}',
      ),
      subtitle: Text(_targetLabel(once.first.target, profile)),
      children: [
        for (final s in block.steps) _StepTile(step: s, profile: profile),
      ],
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.step, required this.profile});

  final WorkoutStep step;
  final PaceProfile profile;

  @override
  Widget build(BuildContext context) {
    final target = _targetLabel(step.target, profile);
    final detail = [if (target.isNotEmpty) target, ?step.note].join('\n');
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(_icon(step.kind)),
      title: Text(
        '${_label(step.kind)} · ${_endLabel(step.end, step.estimate)}',
      ),
      subtitle: detail.isEmpty ? null : Text(detail),
    );
  }

  static IconData _icon(StepKind k) => switch (k) {
    StepKind.warmup => Icons.whatshot,
    StepKind.active => Icons.directions_run,
    StepKind.recovery => Icons.self_improvement,
    StepKind.rest => Icons.pause,
    StepKind.cooldown => Icons.ac_unit,
    StepKind.strength => Icons.fitness_center,
  };

  static String _label(StepKind k) => switch (k) {
    StepKind.warmup => 'Warm-up',
    StepKind.active => 'Run',
    StepKind.recovery => 'Recovery',
    StepKind.rest => 'Rest',
    StepKind.cooldown => 'Cool-down',
    StepKind.strength => 'Strength',
  };
}

String _endLabel(StepEnd end, [Duration? estimate]) => switch (end) {
  TimeEnd(:final duration) =>
    duration.inSeconds < 120
        ? '${duration.inSeconds} s'
        : duration.inSeconds % 60 == 0
        ? '${duration.inMinutes} min'
        : formatDurationShort(duration),
  DistanceEnd(:final meters) =>
    meters >= 1000
        ? '${(meters / 1000).toStringAsFixed(meters % 1000 == 0 ? 0 : 2)} km'
        : '${meters.round()} m',
  LapButtonEnd() =>
    estimate == null ? 'until lap press' : '~${formatMinutes(estimate)}',
};

String formatDurationShort(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')} min';

String _paceRange(Zone z) =>
    '${Pace.format(z.upper)}–${Pace.format(z.lower)} /km';

String _bpm(Zone z) => '${z.lower.round()}–${z.upper.round()} bpm';

String _targetLabel(Target t, PaceProfile p) => switch (t) {
  NoTarget() => '',
  SpeedTarget(:final zone) => _paceRange(zone),
  HeartRateTarget(:final zone) => _bpm(zone),
  IntensityTarget(:final intensity) => [
    intensity.name,
    _paceRange(p.speedFor(intensity)),
    if (p.heartRateFor(intensity) case final hr?) _bpm(hr),
  ].join(' · '),
};
