import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:training_core/training_core.dart';

import 'calendar_models.dart';
import 'calendar_providers.dart';
import 'kind_style.dart';
import 'workout_spec.dart';

/// Create ([existing] null, on [date]) or edit a workout.
Future<void> showWorkoutEditor(
  BuildContext context, {
  CalendarEntry? existing,
  DateTime? date,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => _WorkoutEditor(
      existing: existing,
      initialDate: date ?? dayOf(DateTime.now()),
    ),
  );
}

class _WorkoutEditor extends ConsumerStatefulWidget {
  const _WorkoutEditor({this.existing, required this.initialDate});

  final CalendarEntry? existing;
  final DateTime initialDate;

  @override
  ConsumerState<_WorkoutEditor> createState() => _WorkoutEditorState();
}

class _WorkoutEditorState extends ConsumerState<_WorkoutEditor> {
  late final WorkoutSpec spec;

  /// False for workouts whose steps this form cannot represent.
  late final bool structured;
  late DateTime date;
  int? startMinute;
  late bool isKey;
  final title = TextEditingController();
  final notes = TextEditingController();

  bool get editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    date = e?.day ?? widget.initialDate;
    startMinute = e?.row.startMinute;
    isKey = e?.row.isKey ?? false;
    notes.text = e?.row.notes ?? '';
    if (e == null) {
      spec = WorkoutSpec(SessionKind.easy);
      structured = true;
    } else {
      final parsed = WorkoutSpec.tryParse(e.kind, e.workout, e.strength);
      structured = parsed != null;
      spec = parsed ?? WorkoutSpec(SessionKind.easy);
      title.text = !structured || e.row.title != spec.autoTitle
          ? e.row.title
          : '';
    }
  }

  @override
  void dispose() {
    title.dispose();
    notes.dispose();
    super.dispose();
  }

  String? get problem {
    if (!structured) return null;
    if (spec.isSteady || spec.kind == SessionKind.combined) {
      if (spec.runMinutes <= 0) return 'Enter a duration';
    }
    if (spec.isQuality && (spec.reps < 1 || spec.repSize <= 0)) {
      return 'Enter repetitions and a length';
    }
    if ((spec.kind == SessionKind.strength ||
            spec.kind == SessionKind.combined) &&
        (spec.strength.focusAreas.isEmpty || spec.strength.minutes <= 0)) {
      return 'Pick a focus area and a duration';
    }
    return null;
  }

  Future<void> _save() async {
    final repo = ref.read(calendarRepositoryProvider);
    final name = title.text.trim();
    final note = notes.text.trim().isEmpty ? null : notes.text.trim();
    final e = widget.existing;
    if (e != null && !structured) {
      await repo.updateDetails(
        e.id,
        kind: e.kind,
        date: date,
        startMinute: startMinute,
        title: name.isEmpty ? e.row.title : name,
        isKey: isKey,
        notes: note,
      );
    } else {
      final w = spec.build(ref.read(effectivePaceProvider), title: name);
      await repo.upsertManual(
        id: e?.id,
        kind: spec.kind,
        date: date,
        startMinute: startMinute,
        title: w.title,
        workout: w,
        strength: spec.strengthSession,
        isKey: isKey,
        notes: note,
      );
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: date,
      firstDate: addDays(date, -365 * 2),
      lastDate: addDays(date, 365 * 2),
    );
    if (d != null) setState(() => date = dayOf(d));
  }

  Future<void> _pickTime() async {
    final m = startMinute ?? 7 * 60;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60),
    );
    if (t != null) setState(() => startMinute = t.hour * 60 + t.minute);
  }

  void _setKind(SessionKind k) => setState(() {
    spec
      ..kind = k
      ..applyKindDefaults();
    isKey = k.isQuality || k == SessionKind.long;
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final err = problem;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: _fields(context, cs),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Row(
              children: [
                if (err != null)
                  Expanded(
                    child: Text(err, style: TextStyle(color: cs.error)),
                  )
                else
                  const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: err == null ? _save : null,
                  child: Text(editing ? 'Save' : 'Add'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fields(BuildContext context, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          editing ? 'Edit workout' : 'New workout',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        if (structured)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final k in WorkoutSpec.kinds)
                ChoiceChip(
                  avatar: Icon(k.icon, size: 16, color: k.color(cs)),
                  label: Text(k.label),
                  selected: spec.kind == k,
                  onSelected: (_) => _setKind(k),
                ),
            ],
          )
        else
          Chip(
            avatar: Icon(spec.kind.icon, size: 16),
            label: Text(widget.existing!.kind.label),
          ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.event),
              label: Text(DateFormat.yMMMEd().format(date)),
            ),
            OutlinedButton.icon(
              onPressed: _pickTime,
              icon: const Icon(Icons.schedule),
              label: Text(
                startMinute == null ? 'Add time' : formatClock(startMinute!),
              ),
            ),
            if (startMinute != null)
              IconButton(
                tooltip: 'Clear time',
                onPressed: () => setState(() => startMinute = null),
                icon: const Icon(Icons.close),
              ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: title,
          decoration: InputDecoration(
            labelText: 'Title',
            hintText: structured ? spec.autoTitle : null,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        if (structured) _structure(context) else _fixedStructure(context),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Key session'),
          subtitle: const Text(
            'Hard or important; the checker keeps recovery around it',
          ),
          value: isKey,
          onChanged: (v) => setState(() => isKey = v),
        ),
        TextField(
          controller: notes,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Notes',
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  Widget _fixedStructure(BuildContext context) => Text(
    'This workout has a structure the form cannot edit. Date, title, notes and key flag can be changed.',
    style: Theme.of(context).textTheme.bodySmall,
  );

  Widget _structure(BuildContext context) {
    final k = spec.kind;
    final key = ValueKey(k);
    return switch (k) {
      SessionKind.easy || SessionKind.recovery || SessionKind.long => Row(
        key: key,
        children: [
          Expanded(
            child: IntField(
              label: 'Duration',
              suffix: 'min',
              value: spec.runMinutes,
              onChanged: (v) => setState(() => spec.runMinutes = v),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: _intensity()),
        ],
      ),
      SessionKind.threshold ||
      SessionKind.interval ||
      SessionKind.repetition ||
      SessionKind.marathonPace ||
      SessionKind.racePace => Column(
        key: key,
        children: [
          Row(
            children: [
              Expanded(
                child: IntField(
                  label: 'Warm-up',
                  suffix: 'min',
                  value: spec.warmupMinutes,
                  onChanged: (v) => setState(() => spec.warmupMinutes = v),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: IntField(
                  label: 'Cool-down',
                  suffix: 'min',
                  value: spec.cooldownMinutes,
                  onChanged: (v) => setState(() => spec.cooldownMinutes = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 90,
                child: IntField(
                  label: 'Reps',
                  value: spec.reps,
                  onChanged: (v) => setState(() => spec.reps = v),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: IntField(
                  key: ValueKey(spec.byDistance),
                  label: 'Length',
                  suffix: spec.byDistance ? 'm' : 'min',
                  value: spec.repSize,
                  onChanged: (v) => setState(() => spec.repSize = v),
                ),
              ),
              const SizedBox(width: 12),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: true, label: Text('m')),
                  ButtonSegment(value: false, label: Text('min')),
                ],
                selected: {spec.byDistance},
                onSelectionChanged: (s) => setState(() {
                  spec
                    ..byDistance = s.first
                    ..repSize = s.first ? 800 : 5;
                }),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _intensity(),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: IntField(
                  key: ValueKey(spec.recoveryByDistance),
                  label: 'Recovery (0 = none)',
                  suffix: spec.recoveryByDistance ? 'm' : 'sec',
                  value: spec.recoveryByDistance
                      ? spec.recoveryMeters
                      : spec.recoverySeconds,
                  onChanged: (v) => setState(() {
                    if (spec.recoveryByDistance) {
                      spec.recoveryMeters = v;
                    } else {
                      spec.recoverySeconds = v;
                    }
                  }),
                ),
              ),
              const SizedBox(width: 12),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('sec')),
                  ButtonSegment(value: true, label: Text('m')),
                ],
                selected: {spec.recoveryByDistance},
                onSelectionChanged: (s) =>
                    setState(() => spec.recoveryByDistance = s.first),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _intensity(
            label: 'Recovery intensity',
            value: spec.recoveryIntensity,
            onChanged: (i) => spec.recoveryIntensity = i,
          ),
        ],
      ),
      SessionKind.strength => StrengthFields(
        key: key,
        spec: spec.strength,
        onChanged: () => setState(() {}),
      ),
      SessionKind.combined => Column(
        key: key,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: IntField(
                  label: 'Run duration',
                  suffix: 'min',
                  value: spec.runMinutes,
                  onChanged: (v) => setState(() => spec.runMinutes = v),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: _intensity()),
            ],
          ),
          const SizedBox(height: 12),
          StrengthFields(
            spec: spec.strength,
            showPlacement: true,
            onChanged: () => setState(() {}),
          ),
        ],
      ),
      SessionKind.test => DropdownButtonFormField<TestType>(
        key: key,
        initialValue: spec.testType,
        decoration: const InputDecoration(
          labelText: 'Test',
          border: OutlineInputBorder(),
        ),
        items: [
          for (final t in TestType.values)
            DropdownMenuItem(value: t, child: Text(_testLabel(t))),
        ],
        onChanged: (t) => setState(() => spec.testType = t ?? spec.testType),
      ),
      _ => const SizedBox.shrink(),
    };
  }

  Widget _intensity({
    String label = 'Intensity',
    Intensity? value,
    void Function(Intensity)? onChanged,
  }) => DropdownButtonFormField<Intensity>(
    key: ValueKey(label),
    initialValue: value ?? spec.intensity,
    isExpanded: true,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      isDense: true,
    ),
    items: [
      for (final i in Intensity.values)
        DropdownMenuItem(value: i, child: Text(i.name)),
    ],
    onChanged: (i) => setState(() {
      if (i == null) return;
      onChanged != null ? onChanged(i) : spec.intensity = i;
    }),
  );

  static String _testLabel(TestType t) => switch (t) {
    TestType.timeTrial3k => '3 km time trial',
    TestType.timeTrial5k => '5 km time trial',
    TestType.halfCooper => 'Half-Cooper (6 min)',
    TestType.friel30 => '30-min LTHR test',
  };
}

class IntField extends StatelessWidget {
  const IntField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.suffix,
  });

  final String label;
  final int value;
  final String? suffix;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => TextFormField(
    initialValue: '$value',
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    decoration: InputDecoration(
      labelText: label,
      suffixText: suffix,
      border: const OutlineInputBorder(),
      isDense: true,
    ),
    onChanged: (s) => onChanged(int.tryParse(s) ?? 0),
  );
}

/// Focus areas, duration, RPE, style (and placement within a run).
class StrengthFields extends StatelessWidget {
  const StrengthFields({
    super.key,
    required this.spec,
    required this.onChanged,
    this.showPlacement = false,
  });

  final StrengthSpec spec;
  final VoidCallback onChanged;
  final bool showPlacement;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Focus areas', style: text.labelLarge),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final f in FocusArea.values)
              FilterChip(
                label: Text(f.label),
                selected: spec.focusAreas.contains(f),
                onSelected: (on) {
                  on ? spec.focusAreas.add(f) : spec.focusAreas.remove(f);
                  onChanged();
                },
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            SizedBox(
              width: 120,
              child: IntField(
                label: 'Duration',
                suffix: 'min',
                value: spec.minutes,
                onChanged: (v) {
                  spec.minutes = v;
                  onChanged();
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SegmentedButton<StrengthStyle>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: StrengthStyle.calisthenics,
                    label: Text('Calisthenics'),
                  ),
                  ButtonSegment(value: StrengthStyle.gym, label: Text('Gym')),
                ],
                selected: {spec.style},
                onSelectionChanged: (s) {
                  spec.style = s.first;
                  onChanged();
                },
              ),
            ),
          ],
        ),
        Row(
          children: [
            Text('RPE ${spec.rpe}', style: text.labelLarge),
            Expanded(
              child: Slider(
                min: 1,
                max: 10,
                divisions: 9,
                value: spec.rpe.toDouble(),
                label: '${spec.rpe}',
                onChanged: (v) {
                  spec.rpe = v.round();
                  onChanged();
                },
              ),
            ),
          ],
        ),
        if (showPlacement) ...[
          Text('Strength block goes', style: text.labelLarge),
          const SizedBox(height: 4),
          SegmentedButton<StrengthPlacement>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: StrengthPlacement.before,
                label: Text('Before run'),
              ),
              ButtonSegment(
                value: StrengthPlacement.during,
                label: Text('In the middle'),
              ),
              ButtonSegment(
                value: StrengthPlacement.after,
                label: Text('After run'),
              ),
            ],
            selected: {spec.placement},
            onSelectionChanged: (s) {
              spec.placement = s.first;
              onChanged();
            },
          ),
        ],
      ],
    );
  }
}
