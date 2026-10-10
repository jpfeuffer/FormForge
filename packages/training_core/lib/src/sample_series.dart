import 'dart:math';

import 'evaluation.dart';
import 'zone.dart';

/// Time-indexed view of [Sample]s with cumulative distance and window queries.
final class SampleSeries {
  SampleSeries._(
      this.t, this.d, this.hr, this.speed, this._gapStart, this.maxGap);

  /// Samples with non-increasing seconds are dropped. Distance comes from
  /// [Sample.distance] when any is present, else from integrating speed.
  /// Gaps longer than [maxGap] seconds (pauses, dropouts) add no distance and
  /// invalidate effort windows spanning them.
  factory SampleSeries(List<Sample> samples, {int maxGap = 60}) {
    final t = <double>[],
        d = <double>[],
        speed = <double?>[],
        gapStart = <int>[];
    final hr = <int?>[];
    final hasDistance = samples.any((s) => s.distance != null);
    var dist = 0.0;
    double? lastSpeed;
    for (final s in samples) {
      if (t.isNotEmpty && s.second <= t.last) continue;
      final dt = t.isEmpty ? 0.0 : s.second - t.last;
      double? v = s.speed;
      if (hasDistance) {
        final next = max(dist, s.distance ?? dist);
        v ??= dt > 0 && dt <= maxGap ? (next - dist) / dt : null;
        dist = next;
      } else if (dt > 0 && dt <= maxGap) {
        dist += (v ?? lastSpeed ?? 0) * dt;
      }
      lastSpeed = v ?? lastSpeed;
      gapStart.add(dt > maxGap ? t.length : (gapStart.lastOrNull ?? 0));
      t.add(s.second.toDouble());
      d.add(dist);
      speed.add(v);
      hr.add(s.hr == null || s.hr == 0 ? null : s.hr);
    }
    return SampleSeries._(t, d, hr, speed, gapStart, maxGap);
  }

  /// Seconds since start.
  final List<double> t;

  /// Cumulative metres.
  final List<double> d;
  final List<int?> hr;
  final List<double?> speed;
  final int maxGap;

  /// Per index: index of the latest sample that follows a gap (0 if none).
  final List<int> _gapStart;

  int get length => t.length;
  bool get isEmpty => t.isEmpty;
  double get duration => isEmpty ? 0 : t.last - t.first;
  double get totalDistance => isEmpty ? 0 : d.last - d.first;

  /// Index of the first sample with `t >= second` (length if none).
  int _lowerBound(double second) {
    var lo = 0, hi = t.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (t[mid] < second) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  double distanceAt(double second) {
    if (isEmpty) return 0;
    if (second <= t.first) return d.first;
    if (second >= t.last) return d.last;
    final j = _lowerBound(second);
    if (t[j] == second) return d[j];
    final f = (second - t[j - 1]) / (t[j] - t[j - 1]);
    return d[j - 1] + f * (d[j] - d[j - 1]);
  }

  /// Second at which cumulative distance first reaches [meters]; `null` if never.
  double? secondAtDistance(double meters) {
    if (isEmpty || meters > d.last) return null;
    if (meters <= d.first) return t.first;
    var lo = 0, hi = length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (d[mid] < meters) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final seg = d[lo] - d[lo - 1];
    return seg <= 0
        ? t[lo]
        : t[lo - 1] + (meters - d[lo - 1]) / seg * (t[lo] - t[lo - 1]);
  }

  /// Fastest continuous [meters]; `null` if never covered without a gap.
  ({double start, double end})? fastestDistance(double meters) {
    ({double start, double end})? best;
    var j = 0;
    for (var i = 0; i < length; i++) {
      if (j < i) j = i;
      while (j < length && d[j] - d[i] < meters) {
        j++;
      }
      if (j == length) break;
      if (_gapStart[j] > i) continue;
      final seg = d[j] - d[j - 1];
      final end = seg <= 0
          ? t[j]
          : t[j - 1] + (meters - (d[j - 1] - d[i])) / seg * (t[j] - t[j - 1]);
      if (best == null || end - t[i] < best.end - best.start) {
        best = (start: t[i], end: end);
      }
    }
    return best;
  }

  /// Window of [seconds] with the most distance; `null` if no gap-free window.
  ({double start, double end, double meters})? farthestIn(double seconds) {
    ({double start, double end, double meters})? best;
    for (var i = 0; i < length; i++) {
      final end = t[i] + seconds;
      if (end > t.last) break;
      final k = _lowerBound(end);
      if (_gapStart[k] > i) continue;
      final meters = distanceAt(end) - d[i];
      if (best == null || meters > best.meters) {
        best = (start: t[i], end: end, meters: meters);
      }
    }
    return best;
  }

  /// Time-weighted mean HR in the window.
  double? avgHr(double from, double to) {
    var sum = 0.0, weight = 0.0;
    for (var i = 1; i < length; i++) {
      final h = hr[i];
      if (h == null || t[i] - t[i - 1] > maxGap) continue;
      final w = min(t[i], to) - max(t[i - 1], from);
      if (w <= 0) continue;
      sum += h * w;
      weight += w;
    }
    return weight == 0 ? null : sum / weight;
  }

  /// Mean speed over distance covered in the window (m/s).
  double? avgSpeed(double from, double to) {
    if (to <= from || isEmpty || to <= t.first || from >= t.last) return null;
    return (distanceAt(to) - distanceAt(from)) / (to - from);
  }

  /// Seconds inside [zone] and seconds with data in the window.
  ({double inside, double total}) timeInBand(
    double from,
    double to,
    Zone zone, {
    required bool heartRate,
  }) {
    var inside = 0.0, total = 0.0;
    for (var i = 1; i < length; i++) {
      final v = heartRate ? hr[i]?.toDouble() : speed[i];
      if (v == null || t[i] - t[i - 1] > maxGap) continue;
      final w = min(t[i], to) - max(t[i - 1], from);
      if (w <= 0) continue;
      total += w;
      if (zone.contains(v)) inside += w;
    }
    return (inside: inside, total: total);
  }
}
