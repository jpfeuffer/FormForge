import 'zone.dart';

abstract final class HeartRate {
  /// Friel 30-min solo time trial: average HR of the final 20 minutes.
  static double lthrFromFrielTest(List<({int second, int bpm})> samples) {
    final last20 = samples.where((s) => s.second >= 600).toList();
    if (last20.isEmpty) {
      throw ArgumentError('Samples must cover at least the 10–30 min window');
    }
    return last20.map((s) => s.bpm).reduce((a, b) => a + b) / last20.length;
  }

  /// Friel running zones as % of LTHR.
  static List<Zone> frielZones(double lthr) => [
        Zone('Z1 Recovery', 0, lthr * 0.85),
        Zone('Z2 Aerobic', lthr * 0.85, lthr * 0.89),
        Zone('Z3 Tempo', lthr * 0.90, lthr * 0.94),
        Zone('Z4 Sub-threshold', lthr * 0.95, lthr * 0.99),
        Zone('Z5a Super-threshold', lthr * 1.00, lthr * 1.02),
        Zone('Z5b Aerobic capacity', lthr * 1.03, lthr * 1.06),
        Zone('Z5c Anaerobic', lthr * 1.06, lthr * 1.15),
      ];

  /// Karvonen (heart-rate reserve) five-zone model.
  static List<Zone> karvonenZones({required double rest, required double max}) {
    double at(double f) => rest + (max - rest) * f;
    return [
      Zone('Z1', at(0.50), at(0.60)),
      Zone('Z2', at(0.60), at(0.70)),
      Zone('Z3', at(0.70), at(0.80)),
      Zone('Z4', at(0.80), at(0.90)),
      Zone('Z5', at(0.90), max),
    ];
  }

  /// Tanaka et al. age-predicted maximum.
  static double estimatedMax(int age) => 208 - 0.7 * age;
}
