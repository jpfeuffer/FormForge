import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:training_core/training_core.dart';

import '../adaptation/adaptation_providers.dart';
import '../adaptation/eval_info.dart';

class LoadCard extends ConsumerWidget {
  const LoadCard({super.key});

  static const _days = 42;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    // Fixed hues: theme primary/error are both warm with the orange seed.
    final fitness = dark ? Colors.lightBlue.shade300 : Colors.blue.shade700;
    final fatigue = dark ? Colors.pink.shade200 : Colors.pink.shade400;
    final all = ref.watch(trainingLoadProvider).value ?? const [];
    final points = all.length > _days ? all.sublist(all.length - _days) : all;
    final last = points.lastOrNull;
    final form = last == null ? 0.0 : last.ctl - last.atl;
    final formColor = switch (form) {
      > 15 => Colors.amber,
      > -10 => Colors.green,
      > -30 => Colors.teal,
      _ => theme.colorScheme.error,
    };

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
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MetricBox(
                    label: 'Fitness',
                    abbreviation: 'CTL',
                    value: '${last.ctl.round()}',
                    color: fitness,
                    info: EvalInfo.fitness,
                  ),
                  _MetricBox(
                    label: 'Fatigue',
                    abbreviation: 'ATL',
                    value: '${last.atl.round()}',
                    color: fatigue,
                    info: EvalInfo.fatigue,
                  ),
                  _MetricBox(
                    label: 'Form',
                    abbreviation: 'TSB',
                    value: '${form > 0 ? '+' : ''}${form.round()}',
                    color: formColor,
                    info: EvalInfo.form(form),
                  ),
                  if (last.acwr != null && last.ctl >= 15)
                    _MetricBox(
                      label: 'ACWR',
                      value: last.acwr!.toStringAsFixed(2),
                      color: theme.colorScheme.outline,
                      info: EvalInfo.acwr,
                    ),
                ],
              ),
              SizedBox(
                height: 120,
                child: LineChart(
                  LineChartData(
                    minY: 0,
                    // x is days from today (0), so weekly ticks end on today.
                    minX: -(points.length - 1).toDouble(),
                    maxX: 0,
                    lineBarsData: [
                      _line(points, (p) => p.ctl, fitness),
                      _line(points, (p) => p.atl, fatigue),
                    ],
                    gridData: FlGridData(
                      drawHorizontalLine: false,
                      verticalInterval: 7,
                      getDrawingVerticalLine: (_) => FlLine(
                        color: theme.colorScheme.outlineVariant,
                        strokeWidth: 0.5,
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    titlesData: FlTitlesData(
                      leftTitles: const AxisTitles(),
                      rightTitles: const AxisTitles(),
                      topTitles: const AxisTitles(),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          interval: 7,
                          reservedSize: 22,
                          getTitlesWidget: (x, meta) {
                            final i = points.length - 1 + x.round();
                            if (i < 0 || i >= points.length) {
                              return const SizedBox.shrink();
                            }
                            return SideTitleWidget(
                              meta: meta,
                              space: 6,
                              fitInside: SideTitleFitInsideData.fromTitleMeta(
                                meta,
                              ),
                              child: Text(
                                DateFormat('d MMM').format(points[i].day),
                                style: theme.textTheme.labelSmall,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    lineTouchData: const LineTouchData(enabled: false),
                  ),
                ),
              ),
              Row(
                spacing: 4,
                children: [
                  Icon(Icons.circle, size: 10, color: fitness),
                  Text('fitness', style: theme.textTheme.labelSmall),
                  const SizedBox(width: 8),
                  Icon(Icons.circle, size: 10, color: fatigue),
                  Text('fatigue', style: theme.textTheme.labelSmall),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  LineChartBarData _line(
    List<LoadPoint> points,
    double Function(LoadPoint) value,
    Color color,
  ) => LineChartBarData(
    spots: [
      for (var i = 0; i < points.length; i++)
        FlSpot((i - (points.length - 1)).toDouble(), value(points[i])),
    ],
    color: color,
    barWidth: 2,
    dotData: const FlDotData(show: false),
  );
}

/// Button-like value box with a colour accent; hover or tap explains it.
class _MetricBox extends StatelessWidget {
  const _MetricBox({
    required this.label,
    required this.value,
    required this.color,
    required this.info,
    this.abbreviation,
  });

  final String label;
  final String? abbreviation;
  final String value;
  final Color color;
  final String info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Info(
      info,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {},
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border(left: BorderSide(color: color, width: 4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  abbreviation == null ? label : '$label · $abbreviation',
                  style: theme.textTheme.labelSmall,
                ),
                Text(value, style: theme.textTheme.titleLarge),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
