import 'dart:math';

enum Sex { male, female }

/// Training load and fitness/fatigue modelling.
abstract final class Load {
  /// Banister TRIMP for a session at a steady average HR.
  static double banisterTrimp({
    required Duration duration,
    required double avgHr,
    required double restHr,
    required double maxHr,
    Sex sex = Sex.male,
  }) {
    final hrr = ((avgHr - restHr) / (maxHr - restHr)).clamp(0.0, 1.0);
    final (a, b) = sex == Sex.male ? (0.64, 1.92) : (0.86, 1.67);
    return duration.inSeconds / 60 * hrr * a * exp(b * hrr);
  }

  /// hrTSS: TRIMP normalised so one hour at LTHR scores 100.
  static double hrTss({
    required Duration duration,
    required double avgHr,
    required double restHr,
    required double maxHr,
    required double lthr,
    Sex sex = Sex.male,
  }) {
    final session = banisterTrimp(
        duration: duration,
        avgHr: avgHr,
        restHr: restHr,
        maxHr: maxHr,
        sex: sex);
    final hourAtLthr = banisterTrimp(
        duration: const Duration(hours: 1),
        avgHr: lthr,
        restHr: restHr,
        maxHr: maxHr,
        sex: sex);
    return session / hourAtLthr * 100;
  }

  /// Daily CTL (fitness), ATL (fatigue) and TSB (form) from daily loads.
  ///
  /// Days without an entry count as zero load. Keys are truncated to dates.
  static List<LoadPoint> performanceManagement(
    Map<DateTime, double> dailyLoad, {
    required DateTime from,
    required DateTime to,
    double ctlDays = 42,
    double atlDays = 7,
    double initialCtl = 0,
    double initialAtl = 0,
  }) {
    final byDay = <DateTime, double>{};
    dailyLoad.forEach((k, v) {
      final d = _day(k);
      byDay[d] = (byDay[d] ?? 0) + v;
    });

    final points = <LoadPoint>[];
    var ctl = initialCtl, atl = initialAtl;
    for (var d = _day(from); !d.isAfter(_day(to)); d = _nextDay(d)) {
      final tsb = ctl - atl;
      final load = byDay[d] ?? 0;
      ctl += (load - ctl) / ctlDays;
      atl += (load - atl) / atlDays;
      points.add(LoadPoint(day: d, load: load, ctl: ctl, atl: atl, tsb: tsb));
    }
    return points;
  }

  static DateTime _day(DateTime t) => DateTime.utc(t.year, t.month, t.day);

  static DateTime _nextDay(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day + 1);
}

class LoadPoint {
  const LoadPoint({
    required this.day,
    required this.load,
    required this.ctl,
    required this.atl,
    required this.tsb,
  });

  final DateTime day;
  final double load;
  final double ctl;
  final double atl;

  /// Form entering the day (yesterday's CTL − ATL).
  final double tsb;

  /// EWMA acute:chronic workload ratio; > ~1.3 indicates a risky ramp.
  double? get acwr => ctl > 0 ? atl / ctl : null;
}
