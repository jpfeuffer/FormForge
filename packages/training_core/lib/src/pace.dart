/// Pace/speed conversions. Speeds are always m/s internally.
abstract final class Pace {
  static double secondsPerKm(double metersPerSecond) => 1000 / metersPerSecond;

  static double speedFromSecondsPerKm(double secondsPerKm) =>
      1000 / secondsPerKm;

  static double kmh(double metersPerSecond) => metersPerSecond * 3.6;

  /// Formats a speed as `m:ss` per km.
  static String format(double metersPerSecond) {
    final total = secondsPerKm(metersPerSecond).round();
    final m = total ~/ 60;
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// Parses `m:ss` (per km) into m/s.
  static double parse(String pace) {
    final parts = pace.trim().split(':');
    if (parts.length != 2) {
      throw FormatException('Expected m:ss', pace);
    }
    final seconds = int.parse(parts[0]) * 60 + int.parse(parts[1]);
    return speedFromSecondsPerKm(seconds.toDouble());
  }
}
