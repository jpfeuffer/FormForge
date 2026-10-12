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
    this.plannedSteps = const [],
  });

  final ActivityStreamData streams;
  final PaceProfile? paces;
  final List<Zone> hrZones;

  /// Steps of the linked planned workout; their targets are drawn as bars.
  final List<StepCompliance> plannedSteps;

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
    final pauses = _s.pauses;
    double paceY(double speed) => -Pace.secondsPerKm(speed);
    final pace = _downsample(
      _s.seconds,
      _s.speed,
      (v) => v >= 1 ? paceY(v) : null,
      from: minX,
      to: maxX,
      pauses: pauses,
    );
    final hr = _downsample(
      _s.seconds,
      _s.heartRate,
      (v) => v.toDouble(),
      from: minX,
      to: maxX,
      pauses: pauses,
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

    // Step times are moving time; the axis is wall-clock minutes.
    List<_TargetBar> targets(
      Zone? Function(StepCompliance) zone,
      (double, double) Function(Zone) toY,
    ) => [
      for (final s in widget.plannedSteps)
        if (zone(s) case final z? when s.startSecond != null && s.endSecond != null)
          _TargetBar(
            _wallSeconds(s.startSecond!, pauses, end: false) / 60,
            _wallSeconds(s.endSecond!, pauses, end: true) / 60,
            toY(z).$1,
            toY(z).$2,
          ),
    ];

    Widget card(
      String title,
      List<FlSpot> spots,
      String Function(double) label,
      List<_Band> bands,
      List<_TargetBar> targets,
    ) => _ChartCard(
      title: title,
      spots: spots,
      color: theme.colorScheme.onSurface,
      label: label,
      bands: bands,
      targets: targets,
      pauses: pauses,
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
        if (_zoom == null) ...[
          _TimeSplitLine(
            Pauses.split(pauses, _s.seconds.first, _s.seconds.last),
            pauses,
          ),
          Text(
            'Drag across a chart to zoom into a range.',
            style: theme.textTheme.bodySmall,
          ),
        ] else
          _SelectionSummary(
            streams: _s,
            pauses: pauses,
            from: minX,
            to: maxX,
            onReset: () => setState(() => _zoom = null),
          ),
        if (pace.any((s) => !s.y.isNaN))
          card(
            'Pace (min/km)',
            pace,
            (y) => Pace.format(1000 / -y),
            _bands(paceZones, (z) => (paceY(z.lower), paceY(z.upper))),
            targets((s) => s.speedTarget, (z) => (paceY(z.lower), paceY(z.upper))),
          ),
        if (hr.any((s) => !s.y.isNaN))
          card(
            'Heart rate (bpm)',
            hr,
            (y) => y.round().toString(),
            _bands(widget.hrZones, (z) => (z.lower, z.upper)),
            targets((s) => s.hrTarget, (z) => (z.lower, z.upper)),
          ),
      ],
    );
  }
}

class _SelectionSummary extends StatelessWidget {
  const _SelectionSummary({
    required this.streams,
    required this.pauses,
    required this.from,
    required this.to,
    required this.onReset,
  });

  final ActivityStreamData streams;
  final List<Pause> pauses;
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
    final split = idx.isEmpty
        ? null
        : Pauses.split(pauses, s.seconds[idx.first], s.seconds[idx.last]);
    double? meters;
    final dist = [for (final i in idx) s.distance?[i]].nonNulls;
    if (dist.length >= 2) {
      meters = dist.last - dist.first;
    } else if (s.speed case final speed?) {
      var sum = 0.0;
      for (var k = 1; k < idx.length; k++) {
        final v = speed[idx[k]];
        final dt = s.seconds[idx[k]] - s.seconds[idx[k - 1]];
        if (v != null && dt <= Pauses.maxGap) sum += v * dt;
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
        if (split != null) _TimeSplitLine(split, pauses, inline: true),
        if (meters != null && meters > 0) ...[
          Text(formatKm(meters)),
          if (split != null && split.moving > 0)
            Text('${Pace.format(meters / split.moving)} /km'),
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

/// "Elapsed · moving · paused · standing" for a range.
class _TimeSplitLine extends StatelessWidget {
  const _TimeSplitLine(this.split, this.pauses, {this.inline = false});

  final TimeSplit split;
  final List<Pause> pauses;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    String t(int s) => formatDuration(Duration(seconds: s));
    final parts = [
      if (!inline || split.moving != split.elapsed) 'Elapsed ${t(split.elapsed)}',
      'Moving ${t(split.moving)}',
      if (split.paused > 0) 'Paused ${t(split.paused)}',
      if (split.stopped > 0) 'Standing ${t(split.stopped)}',
    ];
    final count = pauses.where((p) => p.kind == PauseKind.paused).length;
    return Text(
      [
        ...parts,
        if (!inline && count > 0) '$count× paused',
      ].join(' · '),
      style: inline ? null : Theme.of(context).textTheme.bodyMedium,
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

/// A planned target range of one step, on the chart's axes (x in minutes).
class _TargetBar {
  const _TargetBar(this.x1, this.x2, this.y1, this.y2);
  final double x1;
  final double x2;
  final double y1;
  final double y2;
}

/// Wall-clock seconds for [moving] seconds (paused intervals added back).
/// At a pause boundary a step start moves after it and a step end before it.
double _wallSeconds(double moving, List<Pause> pauses, {required bool end}) {
  var cut = 0;
  for (final p in pauses) {
    if (p.kind != PauseKind.paused) continue;
    final at = p.start - cut;
    if (end ? moving > at : moving >= at) {
      cut += p.seconds;
    } else {
      break;
    }
  }
  return moving + cut;
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
  List<Pause> pauses = const [],
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
  final pausedStarts = [
    for (final p in pauses)
      if (p.kind == PauseKind.paused) p.start,
  ];
  bool breakBefore(int i) =>
      seconds[i] - seconds[i - 1] > Pauses.maxGap ||
      pausedStarts.any((s) => s >= seconds[i - 1] && s < seconds[i]);

  final spots = <FlSpot>[];
  var sum = 0.0, n = 0, bucketStart = first;
  void flush(int end) {
    if (n > 0) {
      spots.add(FlSpot(seconds[(bucketStart + end) ~/ 2] / 60, sum / n));
    }
    sum = 0;
    n = 0;
    bucketStart = end;
  }

  for (var i = first; i < last; i++) {
    if (i > first && breakBefore(i)) {
      flush(i);
      if (spots.isNotEmpty && !spots.last.y.isNaN) spots.add(FlSpot.nullSpot);
    } else if (i - bucketStart >= size) {
      flush(i);
    }
    final v = values[i];
    final y = v == null ? null : map(v);
    if (y == null) continue;
    sum += y;
    n++;
  }
  flush(last);
  return spots;
}

class _ChartCard extends StatefulWidget {
  const _ChartCard({
    required this.title,
    required this.spots,
    required this.color,
    required this.label,
    required this.bands,
    required this.targets,
    required this.pauses,
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
  final List<_TargetBar> targets;
  final List<Pause> pauses;
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
    final ys = [
      ...widget.spots.map((s) => s.y).where((y) => !y.isNaN),
      // Targets of steps in view stay visible even when missed by a lot.
      for (final t in widget.targets)
        if (t.x2 > widget.minX && t.x1 < widget.maxX) ...[t.y1, t.y2],
    ];
    final lo = ys.reduce(math.min), hi = ys.reduce(math.max);
    final pad = math.max((hi - lo) * 0.05, 1.0);
    final minY = lo - pad, maxY = hi + pad;
    final visible = [
      for (final b in widget.bands)
        if (math.max(b.y1, b.y2) > minY && math.min(b.y1, b.y2) < maxY) b,
    ];
    final inView = [
      for (final t in widget.targets)
        if (t.x2 > widget.minX && t.x1 < widget.maxX) t,
    ];
    final targetColor = theme.colorScheme.primary;
    final bars = <LineChartBarData>[
      LineChartBarData(
        spots: widget.spots,
        color: widget.color,
        barWidth: 1.5,
        dotData: const FlDotData(show: false),
      ),
    ];
    final fills = <BetweenBarsData>[];
    for (final t in inView) {
      final from = bars.length;
      for (final y in [t.y1, t.y2]) {
        bars.add(
          LineChartBarData(
            spots: [FlSpot(t.x1, y), FlSpot(t.x2, y)],
            color: targetColor.withValues(alpha: 0.9),
            barWidth: 1.5,
            dashArray: const [6, 4],
            dotData: const FlDotData(show: false),
          ),
        );
      }
      fills.add(
        BetweenBarsData(
          fromIndex: from,
          toIndex: from + 1,
          // Stronger than the 0.18 of the zone bands.
          color: targetColor.withValues(alpha: 0.3),
        ),
      );
    }
    final shown = [
      for (final p in widget.pauses)
        if (p.end / 60 > widget.minX && p.start / 60 < widget.maxX) p,
    ];
    final pausedColor = theme.colorScheme.onSurface.withValues(alpha: 0.22);
    final standingColor = theme.colorScheme.onSurface.withValues(alpha: 0.09);
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
                        for (final p in shown)
                          VerticalRangeAnnotation(
                            x1: math.max(p.start / 60, widget.minX),
                            x2: math.min(p.end / 60, widget.maxX),
                            color: p.kind == PauseKind.paused
                                ? pausedColor
                                : standingColor,
                          ),
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
                    lineBarsData: bars,
                    betweenBarsData: fills,
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
                      // Only the recorded line is touchable, not the target bars.
                      getTouchedSpotIndicator: (bar, indexes) =>
                          bar.dashArray != null
                          ? const []
                          : defaultTouchedIndicators(bar, indexes),
                      touchTooltipData: LineTouchTooltipData(
                        getTooltipItems: (touched) => [
                          for (final t in touched)
                            t.barIndex != 0
                                ? null
                                : LineTooltipItem(
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
          if (visible.isNotEmpty || shown.isNotEmpty || inView.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 2,
              children: [
                for (final (color, label) in [
                  for (final b in visible) (b.color, b.label),
                  if (inView.isNotEmpty) (targetColor, 'planned target'),
                  if (shown.any((p) => p.kind == PauseKind.paused))
                    (pausedColor, 'paused'),
                  if (shown.any((p) => p.kind == PauseKind.stopped))
                    (standingColor, 'standing'),
                ])
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 4,
                    children: [
                      Icon(Icons.square, size: 10, color: color),
                      Text(label, style: small),
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
