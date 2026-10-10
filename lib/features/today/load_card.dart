import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../adaptation/adaptation_providers.dart';

class LoadCard extends ConsumerWidget {
  const LoadCard({super.key});

  static const _days = 42;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final all = ref.watch(trainingLoadProvider).value ?? const [];
    final points = all.length > _days ? all.sublist(all.length - _days) : all;
    final last = points.lastOrNull;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text('Training load', style: theme.textTheme.titleMedium),
            if (last == null || last.ctl == 0 && last.atl == 0)
              const Text('Not enough activities yet.')
            else ...[
              Wrap(
                spacing: 16,
                children: [
                  Text('Fitness (CTL) ${last.ctl.round()}'),
                  Text('Fatigue (ATL) ${last.atl.round()}'),
                  Text('Form (TSB) ${(last.ctl - last.atl).round()}'),
                  if (last.acwr != null && last.ctl >= 15)
                    Text('ACWR ${last.acwr!.toStringAsFixed(2)}'),
                ],
              ),
              SizedBox(
                height: 100,
                child: LineChart(
                  LineChartData(
                    minY: 0,
                    lineBarsData: [
                      _line([
                        for (final p in points) p.ctl,
                      ], theme.colorScheme.primary),
                      _line([
                        for (final p in points) p.atl,
                      ], theme.colorScheme.error),
                    ],
                    gridData: const FlGridData(show: false),
                    borderData: FlBorderData(show: false),
                    titlesData: const FlTitlesData(show: false),
                    lineTouchData: const LineTouchData(enabled: false),
                  ),
                ),
              ),
              Row(
                spacing: 4,
                children: [
                  Icon(
                    Icons.circle,
                    size: 10,
                    color: theme.colorScheme.primary,
                  ),
                  Text('fitness', style: theme.textTheme.labelSmall),
                  const SizedBox(width: 8),
                  Icon(Icons.circle, size: 10, color: theme.colorScheme.error),
                  Text('fatigue', style: theme.textTheme.labelSmall),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  LineChartBarData _line(List<double> values, Color color) => LineChartBarData(
    spots: [
      for (var i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i]),
    ],
    color: color,
    barWidth: 2,
    dotData: const FlDotData(show: false),
  );
}
