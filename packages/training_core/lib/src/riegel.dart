import 'dart:math';

import 'performance.dart';

/// Riegel's endurance model: T2 = T1 · (D2/D1)^k.
abstract final class Riegel {
  static const defaultExponent = 1.06;

  static Duration predict(RunPerformance from, double toMeters,
      {double exponent = defaultExponent}) {
    final seconds = from.seconds * pow(toMeters / from.meters, exponent);
    return Duration(microseconds: (seconds * 1e6).round());
  }

  /// Personal fatigue exponent from two maximal efforts at different distances.
  static double fitExponent(RunPerformance a, RunPerformance b) {
    if (a.meters == b.meters) {
      throw ArgumentError('Distances must differ');
    }
    return log(b.seconds / a.seconds) / log(b.meters / a.meters);
  }
}
