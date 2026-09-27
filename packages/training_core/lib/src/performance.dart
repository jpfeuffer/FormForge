/// A maximal (race or time-trial) effort over a known distance.
class RunPerformance {
  const RunPerformance({required this.meters, required this.time})
      : assert(meters > 0);

  final double meters;
  final Duration time;

  double get seconds => time.inMicroseconds / Duration.microsecondsPerSecond;

  /// Average speed in m/s.
  double get speed => meters / seconds;

  @override
  String toString() => 'RunPerformance(${meters}m in $time)';
}
