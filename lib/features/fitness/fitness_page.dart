import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_core/training_core.dart';

import '../../data/database.dart';
import '../../providers.dart';
import '../../util/format.dart';

enum _TestType { timeTrial, halfCooper, lthr }

const _distances = {
  '1500 m': 1500.0,
  '3 km': 3000.0,
  '5 km': 5000.0,
  '10 km': 10000.0,
  'Half marathon': 21097.5,
  'Marathon': 42195.0,
};

class FitnessPage extends ConsumerWidget {
  const FitnessPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Fitness')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _TestEntryCard(),
          SizedBox(height: 16),
          _PaceZonesCard(),
          SizedBox(height: 16),
          _HeartRateCard(),
        ],
      ),
    );
  }
}

class _TestEntryCard extends ConsumerStatefulWidget {
  const _TestEntryCard();

  @override
  ConsumerState<_TestEntryCard> createState() => _TestEntryCardState();
}

class _TestEntryCardState extends ConsumerState<_TestEntryCard> {
  var _type = _TestType.timeTrial;
  var _distance = 5000.0;
  final _value = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final db = ref.read(databaseProvider);
    final now = DateTime.now();
    final FitnessSnapshotsCompanion row;
    switch (_type) {
      case _TestType.timeTrial:
        final time = parseDuration(_value.text);
        if (time == null) {
          setState(() => _error = 'Use mm:ss or h:mm:ss');
          return;
        }
        final p = RunPerformance(meters: _distance, time: time);
        row = FitnessSnapshotsCompanion.insert(
          date: now,
          source: FitnessSource.timeTrial,
          distanceM: Value(_distance),
          durationS: Value(time.inSeconds),
          vdot: Value(Vdot.fromPerformance(p)),
        );
      case _TestType.halfCooper:
        final meters = double.tryParse(_value.text);
        if (meters == null || meters <= 0) {
          setState(() => _error = 'Distance in metres');
          return;
        }
        row = FitnessSnapshotsCompanion.insert(
          date: now,
          source: FitnessSource.halfCooper,
          distanceM: Value(meters),
          durationS: const Value(360),
          masMps: Value(Mas.fromHalfCooper(meters)),
        );
      case _TestType.lthr:
        final bpm = double.tryParse(_value.text);
        if (bpm == null || bpm < 80 || bpm > 230) {
          setState(() => _error = 'Average HR of the last 20 min');
          return;
        }
        row = FitnessSnapshotsCompanion.insert(
          date: now,
          source: FitnessSource.lthrTest,
          durationS: const Value(1800),
          lthr: Value(bpm),
        );
        final profile = await db.watchProfile().first;
        await db.saveProfile((profile?.toCompanion(false) ??
                const AthleteProfilesCompanion())
            .copyWith(lthr: Value(bpm), updatedAt: Value(now)));
    }
    await db.into(db.fitnessSnapshots).insert(row);
    _value.clear();
    setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    final label = switch (_type) {
      _TestType.timeTrial => 'Time (mm:ss or h:mm:ss)',
      _TestType.halfCooper => 'Distance in 6 minutes (m)',
      _TestType.lthr => 'Avg HR last 20 of 30 min (bpm)',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text('Log a test or race',
                style: Theme.of(context).textTheme.titleMedium),
            SegmentedButton<_TestType>(
              segments: const [
                ButtonSegment(
                    value: _TestType.timeTrial, label: Text('Race / TT')),
                ButtonSegment(
                    value: _TestType.halfCooper, label: Text('Half-Cooper')),
                ButtonSegment(value: _TestType.lthr, label: Text('LTHR 30′')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() {
                _type = s.first;
                _error = null;
              }),
            ),
            if (_type == _TestType.timeTrial)
              DropdownButtonFormField<double>(
                initialValue: _distance,
                decoration: const InputDecoration(labelText: 'Distance'),
                items: [
                  for (final e in _distances.entries)
                    DropdownMenuItem(value: e.value, child: Text(e.key)),
                ],
                onChanged: (v) => setState(() => _distance = v!),
              ),
            TextField(
              controller: _value,
              decoration: InputDecoration(labelText: label, errorText: _error),
              onSubmitted: (_) => _save(),
            ),
            FilledButton(onPressed: _save, child: const Text('Save')),
          ],
        ),
      ),
    );
  }
}

class _PaceZonesCard extends ConsumerWidget {
  const _PaceZonesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latest = ref.watch(latestFitnessProvider).value;
    final List<Widget> rows;
    String subtitle;
    if (latest?.vdot case final vdot?) {
      subtitle = 'VDOT ${vdot.toStringAsFixed(1)}';
      rows = [
        for (final z in Vdot.trainingZones(vdot).values)
          _zoneRow(z.name, '${Pace.format(z.lower)}–${Pace.format(z.upper)} /km'),
        const Divider(),
        for (final e in _distances.entries)
          _zoneRow(e.key, formatDuration(Vdot.predictTime(vdot, e.value))),
      ];
    } else if (latest?.masMps case final mas?) {
      subtitle = 'MAS ${Pace.kmh(mas).toStringAsFixed(1)} km/h';
      rows = [
        for (final z in Mas.zones(mas))
          _zoneRow(z.name, '${Pace.format(z.lower)}–${Pace.format(z.upper)} /km'),
      ];
    } else {
      subtitle = 'Log a race, time trial or half-Cooper test to get paces.';
      rows = const [];
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Pace zones', style: Theme.of(context).textTheme.titleMedium),
            Text(subtitle),
            const SizedBox(height: 8),
            ...rows,
          ],
        ),
      ),
    );
  }
}

Widget _zoneRow(String name, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(child: Text(name)),
        Text(value, style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
      ]),
    );

class _HeartRateCard extends ConsumerStatefulWidget {
  const _HeartRateCard();

  @override
  ConsumerState<_HeartRateCard> createState() => _HeartRateCardState();
}

class _HeartRateCardState extends ConsumerState<_HeartRateCard> {
  final _rest = TextEditingController();
  final _max = TextEditingController();
  final _lthr = TextEditingController();
  var _loaded = false;

  @override
  void dispose() {
    _rest.dispose();
    _max.dispose();
    _lthr.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await ref.read(databaseProvider).saveProfile(AthleteProfilesCompanion(
          restHr: Value(double.tryParse(_rest.text)),
          maxHr: Value(double.tryParse(_max.text)),
          lthr: Value(double.tryParse(_lthr.text)),
          updatedAt: Value(DateTime.now()),
        ));
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider).value;
    if (!_loaded && profile != null) {
      _loaded = true;
      _rest.text = profile.restHr?.round().toString() ?? '';
      _max.text = profile.maxHr?.round().toString() ?? '';
      _lthr.text = profile.lthr?.round().toString() ?? '';
    }
    final zones = switch (profile) {
      AthleteProfile(lthr: final l?) => HeartRate.frielZones(l),
      AthleteProfile(restHr: final r?, maxHr: final m?) =>
        HeartRate.karvonenZones(rest: r, max: m),
      _ => const <Zone>[],
    };

    Widget field(TextEditingController c, String label) => Expanded(
          child: TextField(
            controller: c,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: label),
          ),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text('Heart rate', style: Theme.of(context).textTheme.titleMedium),
            Row(spacing: 12, children: [
              field(_rest, 'Resting'),
              field(_max, 'Max'),
              field(_lthr, 'LTHR'),
            ]),
            FilledButton.tonal(onPressed: _save, child: const Text('Save')),
            for (final z in zones)
              _zoneRow(z.name, '${z.lower.round()}–${z.upper.round()} bpm'),
          ],
        ),
      ),
    );
  }
}
