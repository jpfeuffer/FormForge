import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:training_core/training_core.dart';

import '../../providers.dart';
import '../../util/format.dart';

class ActivitiesPage extends ConsumerWidget {
  const ActivitiesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activities = ref.watch(activitiesProvider);
    final fmt = DateFormat.yMMMEd().add_Hm();

    return Scaffold(
      appBar: AppBar(title: const Text('Activities')),
      body: activities.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => list.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No activities yet. Garmin sync and FIT import are next.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final a = list[i];
                  final parts = [
                    if (a.distanceM != null) formatKm(a.distanceM!),
                    formatDuration(Duration(seconds: a.durationS)),
                    if (a.avgSpeed != null) '${Pace.format(a.avgSpeed!)} /km',
                    if (a.avgHr != null) '${a.avgHr!.round()} bpm',
                  ];
                  return ListTile(
                    title: Text(a.name ?? a.sport),
                    subtitle: Text(
                        '${fmt.format(a.startTime)}\n${parts.join(' · ')}'),
                    isThreeLine: true,
                  );
                },
              ),
      ),
    );
  }
}
