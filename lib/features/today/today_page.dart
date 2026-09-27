import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../providers.dart';

class TodayPage extends ConsumerWidget {
  const TodayPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final db = ref.watch(databaseProvider);
    final fitness = ref.watch(latestFitnessProvider).value;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Today')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.insights),
              title: const Text('Current fitness'),
              subtitle: Text(switch (fitness) {
                FitnessSnapshot(vdot: final v?) => 'VDOT ${v.toStringAsFixed(1)}',
                FitnessSnapshot(masMps: final m?) =>
                  'MAS ${(m * 3.6).toStringAsFixed(1)} km/h',
                _ => 'No test logged yet – see Fitness',
              }),
            ),
          ),
          const SizedBox(height: 16),
          Text('Planned today', style: text.titleMedium),
          StreamBuilder<List<PlannedWorkout>>(
            stream: db.watchPlanned(start, start.add(const Duration(days: 1))),
            builder: (context, snap) {
              final items = snap.data ?? const <PlannedWorkout>[];
              if (items.isEmpty) {
                return const ListTile(title: Text('Nothing planned'));
              }
              return Column(children: [
                for (final w in items)
                  ListTile(
                    leading: const Icon(Icons.fitness_center),
                    title: Text(w.title),
                    subtitle: Text(w.kind.name),
                  ),
              ]);
            },
          ),
        ],
      ),
    );
  }
}
