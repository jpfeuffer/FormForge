import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:training_core/training_core.dart';

import '../../data/activity_streams.dart';
import '../../data/database.dart';
import '../../util/format.dart';
import 'activity_analysis.dart';
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
        if (analysis != null && analysis.hrZones.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(
            'Time in HR zones (${analysis.zoneModel})',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          for (final z in analysis.hrZones) _ZoneBar(z),
        ],
        if (streams != null) ..._charts(context, streams),
        if (streams == null)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Text('No recorded streams for this activity.'),
          ),
      ],
    );
  }

  List<Widget> _charts(BuildContext context, ActivityStreamData s) {
    final scheme = Theme.of(context).colorScheme;
    // Negated seconds per km so that faster pace plots higher.
    final pace = _downsample(
      s.seconds,
      s.speed,
      (v) => v >= 1 ? -Pace.secondsPerKm(v) : null,
    );
    final hr = _downsample(s.seconds, s.heartRate, (v) => v.toDouble());
    return [
      if (pace.isNotEmpty)
        _ChartCard(
          title: 'Pace (min/km)',
          spots: pace,
          color: scheme.primary,
          label: (y) => Pace.format(1000 / -y),
        ),
      if (hr.isNotEmpty)
        _ChartCard(
          title: 'Heart rate (bpm)',
          spots: hr,
          color: scheme.error,
          label: (y) => y.round().toString(),
        ),
    ];
  }
}

/// Averages [values] into at most [buckets] spots; x in minutes.
List<FlSpot> _downsample<T extends num>(
  List<int> seconds,
  List<T?>? values,
  double? Function(T) map, {
  int buckets = 300,
}) {
  if (values == null || seconds.isEmpty) return const [];
  final size = math.max(1, (seconds.length / buckets).ceil());
  final spots = <FlSpot>[];
  for (var start = 0; start < seconds.length; start += size) {
    final end = math.min(start + size, seconds.length);
    var sum = 0.0, n = 0;
    for (var i = start; i < end; i++) {
      final v = values[i];
      final y = v == null ? null : map(v);
      if (y == null) continue;
      sum += y;
      n++;
    }
    if (n > 0) spots.add(FlSpot(seconds[(start + end) ~/ 2] / 60, sum / n));
  }
  return spots;
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

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.spots,
    required this.color,
    required this.label,
  });

  final String title;
  final List<FlSpot> spots;
  final Color color;
  final String Function(double y) label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.labelSmall;
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          SizedBox(
            height: 180,
            child: LineChart(
              LineChartData(
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    color: color,
                    barWidth: 1.5,
                    dotData: const FlDotData(show: false),
                  ),
                ],
                gridData: const FlGridData(drawVerticalLine: false),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 44,
                      getTitlesWidget: (y, _) => Text(label(y), style: small),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      getTitlesWidget: (x, _) =>
                          Text('${x.round()}′', style: small),
                    ),
                  ),
                ),
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipItems: (touched) => [
                      for (final t in touched)
                        LineTooltipItem(
                          '${label(t.y)} @ ${formatDuration(Duration(seconds: (t.x * 60).round()))}',
                          const TextStyle(color: Colors.white),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
