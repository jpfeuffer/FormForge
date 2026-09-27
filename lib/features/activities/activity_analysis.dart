import 'package:training_core/training_core.dart';

import '../../data/database.dart';

class ZoneTime {
  const ZoneTime(this.zone, this.fraction);
  final Zone zone;
  final double fraction;
}

/// Derived metrics for one activity, based on its streams and the profile.
class ActivityAnalysis {
  const ActivityAnalysis({
    this.efficiencyFactor,
    this.decoupling,
    this.zoneModel,
    this.hrZones = const [],
    this.hrTss,
  });

  factory ActivityAnalysis.compute(
    Activity activity,
    List<Sample> samples,
    AthleteProfile? profile,
  ) {
    final lthr = profile?.lthr;
    final rest = profile?.restHr;
    final max = profile?.maxHr;
    final (model, zones) = switch ((lthr, rest, max)) {
      (final double l, _, _) => (
        'Friel, LTHR ${l.round()}',
        HeartRate.frielZones(l),
      ),
      (null, final double r, final double m) when m > r => (
        'Karvonen, ${r.round()}–${m.round()} bpm',
        HeartRate.karvonenZones(rest: r, max: m),
      ),
      _ => (null, const <Zone>[]),
    };
    final hasHr = samples.any((s) => s.hr != null);
    final avgHr = activity.avgHr;
    return ActivityAnalysis(
      efficiencyFactor: RunEvaluation.efficiencyFactor(samples),
      decoupling: RunEvaluation.aerobicDecoupling(samples),
      zoneModel: hasHr ? model : null,
      hrZones: hasHr
          ? [
              for (final z in zones)
                ZoneTime(
                  z,
                  RunEvaluation.timeInZone(samples, z, (s) => s.hr?.toDouble()),
                ),
            ]
          : const [],
      hrTss: switch ((avgHr, rest, max, lthr)) {
        (final double hr, final double r, final double m, final double l)
            when m > r =>
          Load.hrTss(
            duration: Duration(seconds: activity.durationS),
            avgHr: hr,
            restHr: r,
            maxHr: m,
            lthr: l,
            sex: profile?.sex == 'female' ? Sex.female : Sex.male,
          ),
        _ => null,
      },
    );
  }

  /// Metres per minute per heartbeat.
  final double? efficiencyFactor;

  /// Pa:HR in percent.
  final double? decoupling;
  final String? zoneModel;
  final List<ZoneTime> hrZones;
  final double? hrTss;
}
