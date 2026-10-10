import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:training_core/training_core.dart';

import '../../data/database.dart';
import '../../providers.dart';
import '../../util/format.dart';
import '../adaptation/compliance_section.dart';
import 'activity_analysis.dart';
import 'activity_charts.dart';
import 'activity_providers.dart';

class ActivityDetailPage extends ConsumerWidget {
  const ActivityDetailPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activity = ref.watch(activityProvider(id));
    return Scaffold(
      appBar: AppBar(title: Text(activity.value?.name ?? 'Activity')),
      body: activity.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (a) => a == null
            ? const Center(child: Text('Activity not found'))
            : _Details(activity: a),
      ),
    );
  }
}

class _Details extends ConsumerWidget {
  const _Details({required this.activity});

  final Activity activity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = activity;
    final analysis = ref.watch(activityAnalysisProvider(a.id)).value;
    final streams = ref.watch(activityStreamProvider(a.id)).value;
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '${DateFormat.yMMMMEEEEd().add_Hm().format(a.startTime.toLocal())} · ${a.sport}',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (a.distanceM != null) _Stat('Distance', formatKm(a.distanceM!)),
            _Stat('Duration', formatDuration(Duration(seconds: a.durationS))),
            if (a.avgSpeed != null && a.avgSpeed! > 0)
              _Stat('Pace', '${Pace.format(a.avgSpeed!)} /km'),
            if (a.avgHr != null) _Stat('Avg HR', '${a.avgHr!.round()} bpm'),
            if (a.maxHr != null) _Stat('Max HR', '${a.maxHr!.round()} bpm'),
            if (analysis?.efficiencyFactor != null)
              _Stat(
                'Efficiency factor',
                analysis!.efficiencyFactor!.toStringAsFixed(2),
              ),
            if (analysis?.decoupling != null)
              _Stat(
                'Decoupling (Pa:HR)',
                '${analysis!.decoupling!.toStringAsFixed(1)} %',
              ),
            if (analysis?.hrTss != null)
              _Stat('hrTSS', analysis!.hrTss!.round().toString()),
          ],
        ),
        ComplianceSection(activityId: a.id),
        if (analysis != null && analysis.hrZones.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(
            'Time in HR zones (${analysis.zoneModel})',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          for (final z in analysis.hrZones) _ZoneBar(z),
        ],
        if (streams != null)
          ActivityCharts(
            streams: streams,
            paces: ref.watch(paceProfileProvider),
            hrZones: [
              for (final z in analysis?.hrZones ?? const <ZoneTime>[]) z.zone,
            ],
          ),
        if (streams == null)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Text('No recorded streams for this activity.'),
          ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card.filled(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: theme.textTheme.labelSmall),
            Text(value, style: theme.textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}

class _ZoneBar extends StatelessWidget {
  const _ZoneBar(this.time);

  final ZoneTime time;

  @override
  Widget build(BuildContext context) {
    final z = time.zone;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 200,
            child: Text(
              '${z.name} (${z.lower.round()}–${z.upper.round()})',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(child: LinearProgressIndicator(value: time.fraction)),
          SizedBox(
            width: 48,
            child: Text(
              '${(time.fraction * 100).round()} %',
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}
