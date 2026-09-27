import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:training_core/training_core.dart';

import '../../providers.dart';
import '../../util/format.dart';
import 'activity_providers.dart';

class ActivitiesPage extends ConsumerWidget {
  const ActivitiesPage({super.key});

  Future<void> _importFit(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final summary = await ref.read(fitImportServiceProvider).pickAndImport();
      if (summary != null) {
        messenger.showSnackBar(SnackBar(content: Text(summary.message)));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('FIT import failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activities = ref.watch(activitiesProvider);
    final fmt = DateFormat.yMMMEd().add_Hm();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Activities'),
        actions: [
          IconButton(
            tooltip: 'Import FIT',
            icon: const Icon(Icons.upload_file),
            onPressed: () => _importFit(context, ref),
          ),
        ],
      ),
      body: activities.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => list.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'No activities yet. Import .fit files from your watch '
                        '(GARMIN/Activity) or a Garmin Connect export.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () => _importFit(context, ref),
                        icon: const Icon(Icons.upload_file),
                        label: const Text('Import FIT'),
                      ),
                    ],
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
                    onTap: () => context.go('/activities/${a.id}'),
                  );
                },
              ),
      ),
    );
  }
}
