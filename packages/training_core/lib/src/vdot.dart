import 'dart:math';

import 'performance.dart';
import 'zone.dart';

enum DanielsIntensity { easy, marathon, threshold, interval, repetition }

/// Jack Daniels' VDOT model (Daniels & Gilbert oxygen-cost equations).
abstract final class Vdot {
  /// VO2 (ml/kg/min) required to run at [metersPerMinute].
  static double oxygenCost(double metersPerMinute) =>
      -4.60 +
      0.182258 * metersPerMinute +
      0.000104 * metersPerMinute * metersPerMinute;

  /// Fraction of VO2max sustainable for a race lasting [minutes].
  static double fractionSustainable(double minutes) =>
      0.8 +
      0.1894393 * exp(-0.012778 * minutes) +
      0.2989558 * exp(-0.1932605 * minutes);

  static double fromPerformance(RunPerformance p) {
    final minutes = p.seconds / 60;
    return oxygenCost(p.meters / minutes) / fractionSustainable(minutes);
  }

  /// Speed (m/s) whose oxygen cost equals [vo2].
  static double speedForVo2(double vo2) {
    const a = 0.000104, b = 0.182258;
    final c = -(4.60 + vo2);
    final metersPerMinute = (-b + sqrt(b * b - 4 * a * c)) / (2 * a);
    return metersPerMinute / 60;
  }

  /// Equivalent race time for [meters] at the given [vdot].
  static Duration predictTime(double vdot, double meters) {
    var lo = 0.5, hi = 2000.0; // minutes
    for (var i = 0; i < 80; i++) {
      final mid = (lo + hi) / 2;
      final v = fromPerformance(RunPerformance(
          meters: meters,
          time: Duration(microseconds: (mid * 60e6).round())));
      // VDOT falls as time grows.
      if (v > vdot) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return Duration(microseconds: ((lo + hi) / 2 * 60e6).round());
  }

  /// Daniels training paces as speed bands (m/s).
  static Map<DanielsIntensity, Zone> trainingZones(double vdot) {
    Zone byFraction(String name, double lo, double hi) =>
        Zone(name, speedForVo2(vdot * lo), speedForVo2(vdot * hi));
    Zone aroundRace(String name, double meters) {
      final v = meters / (predictTime(vdot, meters).inMilliseconds / 1000);
      return Zone(name, v * 0.985, v * 1.015);
    }

    return {
      DanielsIntensity.easy: byFraction('Easy', 0.59, 0.74),
      DanielsIntensity.marathon: aroundRace('Marathon', 42195),
      DanielsIntensity.threshold: byFraction('Threshold', 0.83, 0.88),
      DanielsIntensity.interval: byFraction('Interval', 0.95, 1.0),
      DanielsIntensity.repetition: aroundRace('Repetition', 1609.344),
    };
  }
}
