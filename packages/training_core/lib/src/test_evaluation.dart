import 'dart:math';

import 'evaluation.dart';
import 'mas.dart';
import 'performance.dart';
import 'sample_series.dart';
import 'vdot.dart';
import 'workout.dart';

/// Fitness derived from a test workout recording.
final class TestEvaluation {
  const TestEvaluation({
    required this.type,
    required this.startSecond,
    required this.endSecond,
    required this.distanceM,
    this.vdot,
    this.masMps,
    this.lthr,
    this.avgHr,
  });

  final TestType type;

  /// The detected effort within the recording, in sample seconds.
  final double startSecond;
  final double endSecond;
  final double distanceM;
  final double? vdot;

  /// m/s
  final double? masMps;
  final double? lthr;
  final double? avgHr;

  Duration get duration =>
      Duration(milliseconds: ((endSecond - startSecond) * 1000).round());
}

/// A race-like effort found inside an activity.
final class DetectedEffort {
  const DetectedEffort({
    required this.distanceM,
    required this.startSecond,
    required this.endSecond,
    required this.vdot,
    required this.pacingVariation,
    this.avgHr,
    this.hrFractionOfMax,
  });

  /// Nominal distance (3000, 5000, 10000 or 21097.5).
  final double distanceM;
  final double startSecond;
  final double endSecond;
  final double vdot;

  /// Largest relative deviation of a quarter's speed from the mean speed.
  final double pacingVariation;
  final double? avgHr;

  /// Average HR / max HR; null when either is unknown (HR check skipped).
  final double? hrFractionOfMax;

  Duration get time =>
      Duration(milliseconds: ((endSecond - startSecond) * 1000).round());

  RunPerformance get performance =>
      RunPerformance(meters: distanceM, time: time);
}

abstract final class TestEvaluator {
  static const raceDistances = [3000.0, 5000.0, 10000.0, 21097.5];

  /// Minimum average HR as a share of max HR for a race effort.
  static double minHrFraction(double meters) => meters <= 5000
      ? 0.90
      : meters <= 10000
          ? 0.87
          : 0.84;

  /// Largest quarter-to-mean speed deviation of a plausible race effort.
  static const maxPacingVariation = 0.12;

  /// Largest variation of 1-minute speeds (std / mean) of a race effort.
  static const maxSpeedCv = 0.15;

  static const minVdot = 25.0;
  static const maxVdot = 85.0;

  /// Evaluates the best effort matching [type] anywhere in [samples], so
  /// warm-up and cool-down need no alignment. `null` if the effort is missing
  /// (too short, gaps) or the HR data is.
  static TestEvaluation? evaluate(TestType type, List<Sample> samples) {
    final series = SampleSeries(samples);
    switch (type) {
      case TestType.timeTrial3k:
      case TestType.timeTrial5k:
        final meters = type == TestType.timeTrial3k ? 3000.0 : 5000.0;
        final w = series.fastestDistance(meters);
        if (w == null) return null;
        return TestEvaluation(
          type: type,
          startSecond: w.start,
          endSecond: w.end,
          distanceM: meters,
          vdot: Vdot.fromPerformance(
            RunPerformance(
              meters: meters,
              time: Duration(milliseconds: ((w.end - w.start) * 1000).round()),
            ),
          ),
          avgHr: series.avgHr(w.start, w.end),
        );
      case TestType.halfCooper:
        final w = series.farthestIn(360);
        if (w == null) return null;
        return TestEvaluation(
          type: type,
          startSecond: w.start,
          endSecond: w.end,
          distanceM: w.meters,
          masMps: Mas.fromHalfCooper(w.meters),
          avgHr: series.avgHr(w.start, w.end),
        );
      case TestType.friel30:
        final w = series.farthestIn(1800);
        if (w == null) return null;
        final lthr = series.avgHr(w.start + 600, w.end);
        if (lthr == null) return null;
        return TestEvaluation(
          type: type,
          startSecond: w.start,
          endSecond: w.end,
          distanceM: w.meters,
          lthr: lthr,
          avgHr: series.avgHr(w.start, w.end),
        );
    }
  }

  /// Best 3k/5k/10k/half-marathon efforts that look like races: steady pace,
  /// HR near max when [maxHr] and HR data exist, VDOT in a sane range. Of
  /// overlapping candidates only the longest is kept. Sorted by distance.
  static List<DetectedEffort> detectHardEfforts(
    List<Sample> samples, {
    double? maxHr,
  }) {
    final series = SampleSeries(samples);
    final found = <DetectedEffort>[];
    for (final meters in raceDistances.reversed) {
      final w = series.fastestDistance(meters);
      if (w == null) continue;
      if (found.any((e) => w.start < e.endSecond && e.startSecond < w.end)) {
        continue;
      }
      final seconds = w.end - w.start;
      final vdot = Vdot.fromPerformance(
        RunPerformance(
          meters: meters,
          time: Duration(milliseconds: (seconds * 1000).round()),
        ),
      );
      if (vdot < minVdot || vdot > maxVdot) continue;

      final avg = meters / seconds;
      var variation = 0.0;
      for (var q = 0; q < 4; q++) {
        final v = series.avgSpeed(
          w.start + seconds * q / 4,
          w.start + seconds * (q + 1) / 4,
        );
        if (v != null) variation = max(variation, (v / avg - 1).abs());
      }
      if (variation > maxPacingVariation) continue;
      if (_speedCv(series, w.start, w.end) > maxSpeedCv) continue;

      final avgHr = series.avgHr(w.start, w.end);
      final fraction = maxHr == null || avgHr == null ? null : avgHr / maxHr;
      if (fraction != null && fraction < minHrFraction(meters)) continue;

      found.add(
        DetectedEffort(
          distanceM: meters,
          startSecond: w.start,
          endSecond: w.end,
          vdot: vdot,
          pacingVariation: variation,
          avgHr: avgHr,
          hrFractionOfMax: fraction,
        ),
      );
    }
    return found..sort((a, b) => a.distanceM.compareTo(b.distanceM));
  }

  /// Coefficient of variation of 1-minute speeds; high for fartlek/intervals.
  static double _speedCv(SampleSeries series, double start, double end) {
    final speeds = <double>[];
    for (var t = start; t + 60 <= end + 1e-6; t += 60) {
      final v = series.avgSpeed(t, t + 60);
      if (v != null) speeds.add(v);
    }
    if (speeds.length < 2) return 0;
    final mean = speeds.reduce((a, b) => a + b) / speeds.length;
    final variance =
        speeds.fold(0.0, (a, v) => a + (v - mean) * (v - mean)) / speeds.length;
    return mean == 0 ? 0 : sqrt(variance) / mean;
  }
}
