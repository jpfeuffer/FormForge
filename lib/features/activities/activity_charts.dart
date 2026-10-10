import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:training_core/training_core.dart';

import '../../data/activity_streams.dart';
import '../../util/format.dart';

const _leftAxis = 44.0;

/// Pace and HR charts with zone bands; dragging horizontally zooms both.
class ActivityCharts extends StatefulWidget {
  const ActivityCharts({
    super.key,
    required this.streams,
    required this.paces,
    required this.hrZones,
  });

  final ActivityStreamData streams;
  final PaceProfile? paces;
  final List<Zone> hrZones;

  @override
  State<ActivityCharts> createState() => _ActivityChartsState();
}

class _ActivityChartsState extends State<ActivityCharts> {
  (double, double)? _zoom;
  double? _selStart;
  double? _selEnd;

  ActivityStreamData get _s => widget.streams;
  double get _fullMin => _s.seconds.first / 60;
  double get _fullMax => _s.seconds.last / 60;

  void _endSelection() {
    final (a, b) = (_selStart, _selEnd);
    setState(() {
      // Ignore accidental taps/jitter shorter than 15 s.
      if (a != null && b != null && (a - b).abs() >= 0.25) {
        _zoom = (math.min(a, b), math.max(a, b));
      }
      _selStart = _selEnd = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_s.seconds.length < 2) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final (minX, maxX) = _zoom ?? (_fullMin, _fullMax);
    double paceY(double speed) => -Pace.secondsPerKm(speed);
    final pace = _downsample(
      _s.seconds,
      _s.speed,
      (v) => v >= 1 ? paceY(v) : null,
      from: minX,
      to: maxX,
    );
    final hr = _downsample(
      _s.seconds,
      _s.heartRate,
      (v) => v.toDouble(),
      from: minX,
      to: maxX,
    );
    // Race pace duplicates one of the others, so it gets no band.
    final paceZones = widget.paces == null
        ? const <Zone>[]
        : [
            for (final i in Intensity.values)
              if (i != Intensity.racePace) widget.paces!.speedFor(i),
          ];
    final selection = _selStart != null && _selEnd != null
        ? (_selStart!, _selEnd!)
        : null;

    Widget card(
      String title,
      List<FlSpot> spots,
      String Function(double) label,
      List<_Band> bands,
    ) => _ChartCard(
      title: title,
      spots: spots,
      color: theme.colorScheme.onSurface,
      label: label,
      bands: bands,
      minX: minX,
      maxX: maxX,
      selection: selection,
      onSelectStart: (x) => setState(() => _selStart = _selEnd = x),
      onSelectUpdate: (x) => setState(() => _selEnd = x),
      onSelectEnd: _endSelection,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        if (_zoom == null)
          Text(
            'Drag across a chart to zoom into a range.',
            style: theme.textTheme.bodySmall,
          )
        else
          _SelectionSummary(
            streams: _s,
            from: minX,
            to: maxX,
            onReset: () => setState(() => _zoom = null),
          ),
        if (pace.isNotEmpty)
          card(
            'Pace (min/km)',
            pace,
            (y) => Pace.format(1000 / -y),
            _bands(paceZones, (z) => (paceY(z.lower), paceY(z.upper))),
          ),
        if (hr.isNotEmpty)
          card(
            'Heart rate (bpm)',
            hr,
            (y) => y.round().toString(),
            _bands(widget.hrZones, (z) => (z.lower, z.upper)),
          ),
      ],
    );
  }
}

class _SelectionSummary extends StatelessWidget {
  const _SelectionSummary({
    required this.streams,
    required this.from,
    required this.to,
    required this.onReset,
  });

  final ActivityStreamData streams;
  final double from;
  final double to;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final s = streams;
    final idx = [
      for (var i = 0; i < s.seconds.length; i++)
        if (s.seconds[i] >= from * 60 && s.seconds[i] <= to * 60) i,
    ];
    final seconds = idx.isEmpty
        ? 0
        : s.seconds[idx.last] - s.seconds[idx.first];
    double? meters;
    final dist = [for (final i in idx) s.distance?[i]].nonNulls;
    if (dist.length >= 2) {
      meters = dist.last - dist.first;
    } else if (s.speed case final speed?) {
      var sum = 0.0;
      for (var k = 1; k < idx.length; k++) {
        final v = speed[idx[k]];
        if (v != null) {
          sum += v * (s.seconds[idx[k]] - s.seconds[idx[k - 1]]);
        }
      }
      meters = sum;
    }
    final hrs = [for (final i in idx) s.heartRate?[i]].nonNulls;
    final avgHr = hrs.isEmpty ? null : hrs.reduce((a, b) => a + b) / hrs.length;
    String clock(double minutes) =>
        formatDuration(Duration(seconds: (minutes * 60).round()));

    return Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '${clock(from)}–${clock(to)}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        Text(formatDuration(Duration(seconds: seconds))),
        if (meters != null && meters > 0) ...[
          Text(formatKm(meters)),
          if (seconds > 0) Text('${Pace.format(meters / seconds)} /km'),
        ],
        if (avgHr != null) Text('${avgHr.round()} bpm'),
        TextButton.icon(
          onPressed: onReset,
          icon: const Icon(Icons.zoom_out_map),
          label: const Text('Reset zoom'),
        ),
      ],
    );
  }
}

class _Band {
  const _Band(this.y1, this.y2, this.color, this.label);
  final double y1;
  final double y2;
  final Color color;
  final String label;
}

const _zonePalette = [
  Colors.blue,
  Colors.teal,
  Colors.green,
  Colors.amber,
  Colors.orange,
  Colors.deepOrange,
  Colors.red,
];

/// Zones ordered easy → hard, coloured cool → hot.
List<_Band> _bands(List<Zone> zones, (double, double) Function(Zone) toY) => [
  for (final (i, z) in zones.indexed)
    _Band(
      toY(z).$1,
      toY(z).$2,
      _zonePalette[zones.length < 2
          ? 0
          : (i * (_zonePalette.length - 1) / (zones.length - 1)).round()],
      z.name,
    ),
];

/// Averages [values] within [from]..[to] minutes into at most [buckets]
/// spots; x in minutes.
List<FlSpot> _downsample<T extends num>(
  List<int> seconds,
  List<T?>? values,
  double? Function(T) map, {
  required double from,
  required double to,
  int buckets = 300,
}) {
  if (values == null || seconds.isEmpty) return const [];
  var first = 0;
  while (first < seconds.length && seconds[first] < from * 60) {
    first++;
  }
  var last = seconds.length;
  while (last > first && seconds[last - 1] > to * 60) {
    last--;
  }
  final size = math.max(1, ((last - first) / buckets).ceil());
  final spots = <FlSpot>[];
  for (var start = first; start < last; start += size) {
    final end = math.min(start + size, last);
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

class _ChartCard extends StatefulWidget {
  const _ChartCard({
    required this.title,
    required this.spots,
    required this.color,
    required this.label,
    required this.bands,
    required this.minX,
    required this.maxX,
    required this.selection,
    required this.onSelectStart,
    required this.onSelectUpdate,
    required this.onSelectEnd,
  });

  final String title;
  final List<FlSpot> spots;
  final Color color;
  final String Function(double y) label;
  final List<_Band> bands;
  final double minX;
  final double maxX;
  final (double, double)? selection;
  final ValueChanged<double> onSelectStart;
  final ValueChanged<double> onSelectUpdate;
  final VoidCallback onSelectEnd;

  @override
  State<_ChartCard> createState() => _ChartCardState();
}

class _ChartCardState extends State<_ChartCard> {
  Offset? _down;
  var _selecting = false;

  double _xAt(double dx, double width) {
    final t = ((dx - _leftAxis) / (width - _leftAxis)).clamp(0.0, 1.0);
    return widget.minX + t * (widget.maxX - widget.minX);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.labelSmall;
    final ys = widget.spots.map((s) => s.y);
    final lo = ys.reduce(math.min), hi = ys.reduce(math.max);
    final pad = math.max((hi - lo) * 0.05, 1.0);
    final minY = lo - pad, maxY = hi + pad;
    final visible = [
      for (final b in widget.bands)
        if (math.max(b.y1, b.y2) > minY && math.min(b.y1, b.y2) < maxY) b,
    ];
    final sel = widget.selection;
    final span = widget.maxX - widget.minX;

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          SizedBox(
            height: 180,
            child: LayoutBuilder(
              builder: (context, box) => Listener(
                onPointerDown: (e) {
                  _down = e.localPosition;
                  _selecting = false;
                },
                onPointerMove: (e) {
                  final start = _down;
                  if (start == null) return;
                  final d = e.localPosition - start;
                  // Only horizontal drags select, so vertical page scrolling still works.
                  if (!_selecting &&
                      d.dx.abs() > 8 &&
                      d.dx.abs() > d.dy.abs()) {
                    _selecting = true;
                    widget.onSelectStart(_xAt(start.dx, box.maxWidth));
                  }
                  if (_selecting) {
                    widget.onSelectUpdate(
                      _xAt(e.localPosition.dx, box.maxWidth),
                    );
                  }
                },
                onPointerUp: (_) {
                  if (_selecting) widget.onSelectEnd();
                  _down = null;
                  _selecting = false;
                },
                onPointerCancel: (_) {
                  if (_selecting) widget.onSelectEnd();
                  _down = null;
                  _selecting = false;
                },
                child: LineChart(
                  duration: Duration.zero,
                  LineChartData(
                    minX: widget.minX,
                    maxX: widget.maxX,
                    minY: minY,
                    maxY: maxY,
                    clipData: const FlClipData.all(),
                    rangeAnnotations: RangeAnnotations(
                      horizontalRangeAnnotations: [
                        for (final b in visible)
                          HorizontalRangeAnnotation(
                            y1: math.max(math.min(b.y1, b.y2), minY),
                            y2: math.min(math.max(b.y1, b.y2), maxY),
                            color: b.color.withValues(alpha: 0.18),
                          ),
                      ],
                      verticalRangeAnnotations: [
                        if (sel != null)
                          VerticalRangeAnnotation(
                            x1: math.min(sel.$1, sel.$2),
                            x2: math.max(sel.$1, sel.$2),
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.25,
                            ),
                          ),
                      ],
                    ),
                    lineBarsData: [
                      LineChartBarData(
                        spots: widget.spots,
                        color: widget.color,
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
                          reservedSize: _leftAxis,
                          getTitlesWidget: (y, _) =>
                              Text(widget.label(y), style: small),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 22,
                          getTitlesWidget: (x, meta) =>
                              x == meta.min || x == meta.max
                              ? const SizedBox.shrink()
                              : Text(
                                  span > 15
                                      ? '${x.round()}′'
                                      : formatDuration(
                                          Duration(seconds: (x * 60).round()),
                                        ),
                                  style: small,
                                ),
                        ),
                      ),
                    ),
                    lineTouchData: LineTouchData(
                      touchTooltipData: LineTouchTooltipData(
                        getTooltipItems: (touched) => [
                          for (final t in touched)
                            LineTooltipItem(
                              '${widget.label(t.y)} @ ${formatDuration(Duration(seconds: (t.x * 60).round()))}',
                              const TextStyle(color: Colors.white),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (visible.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 2,
              children: [
                for (final b in visible)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 4,
                    children: [
                      Icon(Icons.square, size: 10, color: b.color),
                      Text(b.label, style: small),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
