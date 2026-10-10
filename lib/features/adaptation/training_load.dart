import 'package:training_core/training_core.dart';

import '../../data/database.dart';
import '../../data/sports.dart';

/// hrTSS when the profile has rest/max HR and LTHR; otherwise runs are
/// estimated at 55 TSS per hour and other sports without HR count nothing.
double? activityLoad(Activity a, AthleteProfile? profile) {
  final hr = a.avgHr;
  final rest = profile?.restHr, max = profile?.maxHr, lthr = profile?.lthr;
  if (hr != null && rest != null && max != null && lthr != null && max > rest) {
    return Load.hrTss(
      duration: Duration(seconds: a.durationS),
      avgHr: hr,
      restHr: rest,
      maxHr: max,
      lthr: lthr,
      sex: profile?.sex == 'female' ? Sex.female : Sex.male,
    );
  }
  return isRunSport(a.sport) ? a.durationS / 3600 * 55 : null;
}
