import 'performance.dart';

class CriticalSpeedModel {
  const CriticalSpeedModel({required this.criticalSpeed, required this.dPrime});

  /// Asymptotic sustainable speed, m/s (≈ lactate threshold-ish, ~30–60 min).
  final double criticalSpeed;

  /// Finite distance (m) that can be covered above critical speed.
  final double dPrime;

  /// Predicted time for [meters]; only valid for ~2–30 min efforts.
  Duration predictTime(double meters) {
    final seconds = (meters - dPrime) / criticalSpeed;
    return Duration(microseconds: (seconds * 1e6).round());
  }

  /// Least-squares fit of distance = CS·t + D′ over ≥ 2 maximal efforts.
  static CriticalSpeedModel fit(List<RunPerformance> efforts) {
    if (efforts.length < 2) {
      throw ArgumentError('Need at least two efforts');
    }
    final n = efforts.length;
    final meanT = efforts.map((e) => e.seconds).reduce((a, b) => a + b) / n;
    final meanD = efforts.map((e) => e.meters).reduce((a, b) => a + b) / n;
    var num = 0.0, den = 0.0;
    for (final e in efforts) {
      num += (e.seconds - meanT) * (e.meters - meanD);
      den += (e.seconds - meanT) * (e.seconds - meanT);
    }
    if (den == 0) {
      throw ArgumentError('Efforts must have different durations');
    }
    final cs = num / den;
    return CriticalSpeedModel(criticalSpeed: cs, dPrime: meanD - cs * meanT);
  }
}
