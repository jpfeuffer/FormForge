import 'zone.dart';

/// Maximal Aerobic Speed (MAS / VMA) estimation and zones.
abstract final class Mas {
  /// Half-Cooper test: distance covered in 6 minutes at max effort.
  static double fromHalfCooper(double meters) => meters / 360;

  /// Léger's approximation (ml/kg/min), MAS in km/h * 3.5.
  static double estimatedVo2max(double masMetersPerSecond) =>
      masMetersPerSecond * 3.6 * 3.5;

  /// %MAS bands common in French coaching (m/s).
  static List<Zone> zones(double mas) => [
        Zone('Recovery', mas * 0.60, mas * 0.65),
        Zone('Endurance', mas * 0.65, mas * 0.75),
        Zone('Active endurance', mas * 0.75, mas * 0.85),
        Zone('Threshold', mas * 0.85, mas * 0.90),
        Zone('Race / VO2', mas * 0.90, mas * 0.95),
        Zone('MAS intervals', mas * 0.95, mas * 1.05),
      ];
}
