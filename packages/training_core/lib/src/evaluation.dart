import 'zone.dart';

/// One recorded data point of an activity stream.
class Sample {
  const Sample({required this.second, this.speed, this.hr, this.distance});

  /// Seconds since activity start.
  final int second;

  /// m/s
  final double? speed;

  /// bpm
  final int? hr;

  /// Metres since activity start; when absent, speed is integrated.
  final double? distance;
}

/// Post-run analysis of HR and pace streams.
abstract final class RunEvaluation {
  /// Fraction (0–1) of time where [value] of a sample lies within [zone].
  static double timeInZone(
      List<Sample> samples, Zone zone, double? Function(Sample) value) {
    var inside = 0, total = 0;
    for (var i = 1; i < samples.length; i++) {
      final dt = samples[i].second - samples[i - 1].second;
      final v = value(samples[i]);
      if (dt <= 0 || v == null) continue;
      total += dt;
      if (zone.contains(v)) inside += dt;
    }
    return total == 0 ? 0 : inside / total;
  }

  static double paceCompliance(List<Sample> samples, Zone speedZone) =>
      timeInZone(samples, speedZone, (s) => s.speed);

  static double hrCompliance(List<Sample> samples, Zone hrZone) =>
      timeInZone(samples, hrZone, (s) => s.hr?.toDouble());

  /// Efficiency factor: metres per minute per heartbeat. Rising EF at equal
  /// effort signals improving aerobic fitness.
  static double? efficiencyFactor(List<Sample> samples) {
    var speedSum = 0.0, hrSum = 0.0, weight = 0;
    for (var i = 1; i < samples.length; i++) {
      final s = samples[i];
      final dt = s.second - samples[i - 1].second;
      if (dt <= 0 || s.speed == null || s.hr == null || s.hr == 0) continue;
      speedSum += s.speed! * dt;
      hrSum += s.hr! * dt;
      weight += dt;
    }
    if (weight == 0 || hrSum == 0) return null;
    return (speedSum / weight * 60) / (hrSum / weight);
  }

  /// Aerobic decoupling (Pa:HR) in percent: EF drop from first to second half.
  /// Below ~5 % on a steady long run indicates good aerobic endurance.
  static double? aerobicDecoupling(List<Sample> samples) {
    if (samples.length < 4) return null;
    final midTime = (samples.first.second + samples.last.second) / 2;
    final first = samples.where((s) => s.second <= midTime).toList();
    final second = samples.where((s) => s.second >= midTime).toList();
    final ef1 = efficiencyFactor(first);
    final ef2 = efficiencyFactor(second);
    if (ef1 == null || ef2 == null) return null;
    return (ef1 - ef2) / ef1 * 100;
  }
}
