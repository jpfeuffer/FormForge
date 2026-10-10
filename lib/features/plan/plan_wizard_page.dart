import 'package:drift/drift.dart' show Value;
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
import 'wizard_inputs.dart';

const _weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const _resultDistances = {
  '1500 m': 1500.0,
  '3 km': 3000.0,
  '5 km': 5000.0,
  '10 km': 10000.0,
  'Half marathon': 21097.5,
  'Marathon': 42195.0,
};

const _stepTitles = {
  WizardStep.goal: 'Goal',
  WizardStep.fitness: 'Fitness',
  WizardStep.background: 'Background',
  WizardStep.availability: 'Availability',
  WizardStep.strength: 'Strength',
  WizardStep.review: 'Review',
};

String _focusLabel(FocusArea f) => switch (f) {
  FocusArea.runningStrength => 'Running strength',
  FocusArea.core => 'Core',
  FocusArea.lowerBody => 'Lower body',
  FocusArea.upperPush => 'Upper push',
  FocusArea.upperPull => 'Upper pull',
  FocusArea.plyometrics => 'Plyometrics',
  FocusArea.mobility => 'Mobility',
  FocusArea.fullBody => 'Full body',
};

class PlanWizardPage extends ConsumerStatefulWidget {
  const PlanWizardPage({super.key});

  @override
  ConsumerState<PlanWizardPage> createState() => _PlanWizardPageState();
}

class _PlanWizardPageState extends ConsumerState<PlanWizardPage> {
  late final DateTime _today;
  WizardInputs? _in;
  FitnessSnapshot? _stored;
  var _step = WizardStep.goal;

  core.TrainingPlan? _plan;
  List<PlanViolation> _violations = const [];
  String? _generateError;
  final _name = TextEditingController();
  var _saving = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _today = DateTime(now.year, now.month, now.day);
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    final saved = await db.getSetting(wizardInputsKey);
    final snapshot = await latestPacingSnapshot(db);
    final profile = await (db.select(
      db.athleteProfiles,
    )..where((t) => t.id.equals(1))).getSingleOrNull();
    final inputs = WizardInputs.decode(saved, _today)
      ..vdot = snapshot?.vdot
      ..mas = snapshot?.masMps
      ..enterResult = snapshot == null;
    final lthr = profile?.lthr ?? snapshot?.lthr;
    if (lthr != null) inputs.lthr = lthr.round().toString();
    if (!mounted) return;
    setState(() {
      _stored = snapshot;
      _in = inputs;
    });
  }

  WizardStep? _neighbor(int delta) {
    final i = _step.index + delta;
    return i < 0 || i >= WizardStep.values.length ? null : WizardStep.values[i];
  }

  void _next() {
    final next = _neighbor(1);
    if (next == null) return;
    if (next == WizardStep.review) _generate();
    setState(() => _step = next);
  }

  void _generate() {
    final inputs = _in!;
    final request = inputs.toRequest(_today);
    _plan = null;
    _violations = const [];
    _generateError = null;
    if (request == null) {
      _generateError = 'Some inputs are incomplete.';
      return;
    }
    try {
      final plan = PlanGenerator.generate(request);
      _plan = plan;
      _violations = PlanValidator.validate(plan);
      _name.text = inputs.defaultName(request);
    } on ArgumentError catch (e) {
      _generateError = e.message?.toString() ?? 'Could not generate a plan.';
    }
  }

  Future<void> _save() async {
    final inputs = _in!;
    final plan = _plan!;
    final db = ref.read(databaseProvider);
    setState(() => _saving = true);
    final name = _name.text.trim().isEmpty
        ? inputs.defaultName(plan.request)
        : _name.text.trim();
    await ref.read(planRepositoryProvider).savePlan(plan, name: name);
    await db.setSetting(wizardInputsKey, inputs.encode());
    final vdot = inputs.resultVdot;
    if (vdot != null) {
      await db
          .into(db.fitnessSnapshots)
          .insert(
            FitnessSnapshotsCompanion.insert(
              date: DateTime.now(),
              source: FitnessSource.race,
              distanceM: Value(inputs.resultMeters),
              durationS: Value(inputs.result!.inSeconds),
              vdot: Value(vdot),
            ),
          );
    }
    if (!mounted) return;
    setState(() => _saving = false);
    GoRouter.maybeOf(context)?.go('/plan');
  }

  @override
  Widget build(BuildContext context) {
    final inputs = _in;
    final error = inputs?.stepError(_step, _today);
    final isReview = _step == WizardStep.review;
    final canAdvance =
        inputs != null &&
        error == null &&
        (!isReview ||
            (_plan != null &&
                !_violations.any((v) => v.severity == Severity.error)));
    final back = _neighbor(-1);

    return Scaffold(
      appBar: AppBar(title: Text('New plan · ${_stepTitles[_step]}')),
      body: inputs == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      value: (_step.index + 1) / WizardStep.values.length,
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          ..._content(inputs),
                          if (error != null && !isReview)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                error,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            TextButton(
                              onPressed: back == null || _saving
                                  ? null
                                  : () => setState(() => _step = back),
                              child: const Text('Back'),
                            ),
                            const Spacer(),
                            FilledButton(
                              onPressed: !canAdvance || _saving
                                  ? null
                                  : isReview
                                  ? _save
                                  : _next,
                              child: Text(isReview ? 'Save plan' : 'Next'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  List<Widget> _content(WizardInputs i) => switch (_step) {
    WizardStep.goal => _goalStep(i),
    WizardStep.fitness => _fitnessStep(i),
    WizardStep.background => _backgroundStep(i),
    WizardStep.availability => _availabilityStep(i),
    WizardStep.strength => _strengthStep(i),
    WizardStep.review => _reviewStep(i),
  };

  Widget _field(
    String label,
    String value,
    ValueChanged<String> onChanged, {
    String? error,
    String? hint,
    TextInputType? keyboardType,
  }) => TextFormField(
    initialValue: value,
    keyboardType: keyboardType,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      errorText: error,
    ),
    onChanged: (s) => setState(() => onChanged(s)),
  );

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );

  List<Widget> _goalStep(WizardInputs i) {
    final raceError = i.raceDateError(_today);
    return [
      _section('What are you training for?'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final p in GoalPreset.values)
            ChoiceChip(
              label: Text(p.label),
              selected: i.preset == p,
              onSelected: (_) => setState(() => i.preset = p),
            ),
        ],
      ),
      if (i.preset == GoalPreset.custom) ...[
        const SizedBox(height: 12),
        _field(
          'Distance (km)',
          i.customKm,
          (s) => i.customKm = s,
          error: i.customKm.isEmpty ? null : i.customKmError,
          keyboardType: TextInputType.number,
        ),
      ],
      const SizedBox(height: 20),
      _section('When?'),
      const SizedBox(height: 8),
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: true, label: Text('Race date')),
          ButtonSegment(value: false, label: Text('Number of weeks')),
        ],
        selected: {i.useRaceDate},
        onSelectionChanged: (s) => setState(() => i.useRaceDate = s.first),
      ),
      const SizedBox(height: 8),
      if (i.useRaceDate) ...[
        OutlinedButton.icon(
          icon: const Icon(Icons.event),
          label: Text(
            i.raceDate == null ? 'Pick race date' : formatDay(i.raceDate!),
          ),
          onPressed: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: i.raceDate ?? _today.add(const Duration(days: 84)),
              firstDate: _today,
              lastDate: _today.add(const Duration(days: maxWeeks * 7)),
            );
            if (d != null) setState(() => i.raceDate = d);
          },
        ),
        if (raceError != null && i.raceDate != null)
          Text(
            raceError,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ] else
        Row(
          children: [
            Expanded(
              child: Slider(
                value: i.weeks.toDouble(),
                min: 3,
                max: maxWeeks.toDouble(),
                divisions: maxWeeks - 3,
                label: '${i.weeks}',
                onChanged: (v) => setState(() => i.weeks = v.round()),
              ),
            ),
            SizedBox(width: 72, child: Text('${i.weeks} weeks')),
          ],
        ),
      const SizedBox(height: 12),
      _field(
        'Target time (optional)',
        i.targetTime,
        (s) => i.targetTime = s,
        hint: 'h:mm:ss',
        error: i.targetError,
      ),
    ];
  }

  List<Widget> _fitnessStep(WizardInputs i) {
    final stored = _stored;
    final label = i.vdot != null
        ? 'VDOT ${i.vdot!.toStringAsFixed(1)}'
        : 'MAS ${Pace.kmh(i.mas ?? 0).toStringAsFixed(1)} km/h';
    final entered = i.resultVdot;
    return [
      if (stored != null)
        Card(
          child: SwitchListTile(
            title: Text('Stored fitness: $label'),
            subtitle: Text(
              i.enterResult
                  ? 'Using a recent result instead'
                  : 'From ${formatDay(stored.date)}',
            ),
            value: i.enterResult,
            onChanged: (v) => setState(() => i.enterResult = v),
            secondary: const Icon(Icons.edit),
          ),
        )
      else
        const Text(
          'No fitness data yet. Enter a recent race or hard time '
          'trial (last ~8 weeks) to size the paces.',
        ),
      if (i.enterResult) ...[
        const SizedBox(height: 12),
        DropdownButtonFormField<double>(
          initialValue: i.resultMeters,
          decoration: const InputDecoration(labelText: 'Distance'),
          items: [
            for (final e in _resultDistances.entries)
              DropdownMenuItem(value: e.value, child: Text(e.key)),
          ],
          onChanged: (v) => setState(() => i.resultMeters = v!),
        ),
        const SizedBox(height: 12),
        _field(
          'Time',
          i.resultTime,
          (s) => i.resultTime = s,
          hint: 'h:mm:ss',
          error: i.resultTime.isEmpty ? null : i.resultError,
        ),
        if (entered != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('VDOT ${entered.toStringAsFixed(1)}'),
          ),
      ],
      const SizedBox(height: 12),
      _field(
        'Lactate-threshold HR (optional, bpm)',
        i.lthr,
        (s) => i.lthr = s,
        error: i.lthrError,
        keyboardType: TextInputType.number,
      ),
    ];
  }

  List<Widget> _backgroundStep(WizardInputs i) {
    final hours = i.unit == VolumeUnit.hours;
    return [
      _section('Current training'),
      const SizedBox(height: 8),
      SegmentedButton<VolumeUnit>(
        segments: const [
          ButtonSegment(value: VolumeUnit.km, label: Text('Kilometres')),
          ButtonSegment(value: VolumeUnit.hours, label: Text('Hours')),
        ],
        selected: {i.unit},
        onSelectionChanged: (s) => setState(() => i.unit = s.first),
      ),
      const SizedBox(height: 12),
      _field(
        hours ? 'Running per week (hours)' : 'Running per week (km)',
        i.weeklyVolume,
        (s) => i.weeklyVolume = s,
        error: i.weeklyVolumeError,
        keyboardType: TextInputType.number,
      ),
      const SizedBox(height: 12),
      _field(
        hours ? 'Longest recent run (minutes)' : 'Longest recent run (km)',
        i.longestRun,
        (s) => i.longestRun = s,
        error: i.longestRunError,
        keyboardType: TextInputType.number,
      ),
      const SizedBox(height: 4),
      const Text('Leave empty if you are starting from scratch.'),
      const SizedBox(height: 20),
      _section('Experience'),
      const SizedBox(height: 8),
      SegmentedButton<Experience>(
        segments: const [
          ButtonSegment(value: Experience.beginner, label: Text('Beginner')),
          ButtonSegment(
            value: Experience.intermediate,
            label: Text('Intermediate'),
          ),
          ButtonSegment(value: Experience.advanced, label: Text('Advanced')),
        ],
        selected: {i.experience},
        onSelectionChanged: (s) => setState(() => i.experience = s.first),
      ),
    ];
  }

  List<Widget> _availabilityStep(WizardInputs i) => [
    _section('Which days can you train?'),
    const SizedBox(height: 4),
    for (var d = DateTime.monday; d <= DateTime.sunday; d++)
      Row(
        children: [
          Expanded(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_weekdayNames[d - 1]),
              value: i.days.contains(d),
              onChanged: (v) => setState(() {
                v ? i.days.add(d) : i.days.remove(d);
              }),
            ),
          ),
          if (i.days.contains(d))
            SizedBox(
              width: 112,
              child: TextFormField(
                initialValue: i.maxMinutes[d] ?? '',
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Max min',
                  isDense: true,
                  errorText: i.maxMinutesError(d),
                ),
                onChanged: (s) => setState(() => i.maxMinutes[d] = s),
              ),
            ),
        ],
      ),
    const SizedBox(height: 12),
    DropdownButtonFormField<int?>(
      key: ValueKey(i.days.length),
      initialValue: i.days.contains(i.longRunDay) ? i.longRunDay : null,
      decoration: const InputDecoration(labelText: 'Preferred long-run day'),
      items: [
        const DropdownMenuItem(value: null, child: Text('No preference')),
        for (final d in i.days.toList()..sort())
          DropdownMenuItem(value: d, child: Text(_weekdayNames[d - 1])),
      ],
      onChanged: (v) => setState(() => i.longRunDay = v),
    ),
  ];

  List<Widget> _strengthStep(WizardInputs i) => [
    _section('Strength training'),
    const SizedBox(height: 8),
    SegmentedButton<StrengthGoalKind>(
      segments: const [
        ButtonSegment(value: StrengthGoalKind.none, label: Text('None')),
        ButtonSegment(
          value: StrengthGoalKind.runningSupport,
          label: Text('Running support'),
        ),
        ButtonSegment(
          value: StrengthGoalKind.secondaryGoal,
          label: Text('Secondary goal'),
        ),
      ],
      selected: {i.strengthKind},
      onSelectionChanged: (s) => setState(() => i.strengthKind = s.first),
    ),
    if (i.strengthKind != StrengthGoalKind.none) ...[
      const SizedBox(height: 16),
      const Text('Focus areas (none selected = sensible defaults)'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final f in FocusArea.values)
            FilterChip(
              label: Text(_focusLabel(f)),
              selected: i.focus.contains(f),
              onSelected: (v) =>
                  setState(() => v ? i.focus.add(f) : i.focus.remove(f)),
            ),
        ],
      ),
      const SizedBox(height: 16),
      SegmentedButton<StrengthStyle>(
        segments: const [
          ButtonSegment(
            value: StrengthStyle.calisthenics,
            label: Text('Calisthenics'),
          ),
          ButtonSegment(value: StrengthStyle.gym, label: Text('Gym')),
        ],
        selected: {i.style},
        onSelectionChanged: (s) => setState(() => i.style = s.first),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          const SizedBox(width: 120, child: Text('Sessions / week')),
          Expanded(
            child: Slider(
              value: i.sessionsPerWeek.toDouble(),
              min: 1,
              max: 4,
              divisions: 3,
              label: '${i.sessionsPerWeek}',
              onChanged: (v) => setState(() => i.sessionsPerWeek = v.round()),
            ),
          ),
          Text('${i.sessionsPerWeek}'),
        ],
      ),
      Row(
        children: [
          const SizedBox(width: 120, child: Text('Duration')),
          Expanded(
            child: Slider(
              value: i.sessionMinutes.toDouble(),
              min: 15,
              max: 90,
              divisions: 15,
              label: '${i.sessionMinutes} min',
              onChanged: (v) => setState(() => i.sessionMinutes = v.round()),
            ),
          ),
          SizedBox(width: 48, child: Text('${i.sessionMinutes} min')),
        ],
      ),
    ],
  ];

  List<Widget> _reviewStep(WizardInputs i) {
    final plan = _plan;
    final scheme = Theme.of(context).colorScheme;
    if (plan == null) {
      return [
        Text(
          _generateError ?? 'No plan generated.',
          style: TextStyle(color: scheme.error),
        ),
      ];
    }
    final f = plan.feasibility;
    final errors = _violations.where((v) => v.severity == Severity.error);
    final others = _violations.where((v) => v.severity != Severity.error);
    return [
      TextField(
        controller: _name,
        decoration: const InputDecoration(labelText: 'Plan name'),
      ),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Text(
                '${plan.weeks.length} weeks · ${plan.sessions.length} sessions',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text('Distance ${formatKm(plan.request.goalMeters)}'),
              Text('Predicted now: ${formatDuration(f.predictedTime)}'),
              if (f.targetTime != null)
                Text(
                  'Target: ${formatDuration(f.targetTime!)} '
                  '(${f.isRealistic ? 'realistic' : 'ambitious'})',
                ),
              Text('Race pace: ${Pace.format(f.raceSpeed)} /km'),
            ],
          ),
        ),
      ),
      if (plan.warnings.isNotEmpty) ...[
        const SizedBox(height: 12),
        for (final w in plan.warnings)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.warning_amber, color: scheme.tertiary),
            title: Text(w.message),
          ),
      ],
      const SizedBox(height: 12),
      if (_violations.isEmpty)
        const ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.verified_outlined),
          title: Text('All training guardrails satisfied'),
        ),
      for (final v in errors)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.error_outline, color: scheme.error),
          title: Text(v.message),
          subtitle: Text('Week ${v.weekIndex + 1}'),
        ),
      for (final v in others)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.info_outline),
          title: Text(v.message),
          subtitle: Text('Week ${v.weekIndex + 1}'),
        ),
      const SizedBox(height: 12),
      _section('First weeks'),
      for (final w in plan.weeks.take(2)) ...[
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(
            'Week ${w.index + 1} · ${phaseLabel(w.phase)}'
            '${w.isRecovery ? ' · recovery' : ''} · ${formatVolume(w.targetVolume)}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        for (final s in w.sessions)
          SessionRow(
            date: s.date,
            kind: s.kind,
            title: s.workout.title,
            isKey: s.isKey,
          ),
      ],
    ];
  }
}
