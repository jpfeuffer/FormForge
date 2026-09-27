import 'dart:math';

import '../strength.dart';
import '../workout.dart';
import 'dates.dart';
import 'feasibility.dart';
import 'plan.dart';
import 'request.dart';
import 'rules.dart';
import 'templates.dart';

/// Deterministic, rule-based plan generator (pure; no randomness).
abstract final class PlanGenerator {
  static TrainingPlan generate(PlanRequest request) =>
      _Generator(request).run();
}

const _noCap = 24 * 60;
const _minRun = 20;
const _minQualityWithStrength = 45;

class _Generator {
  _Generator(this.req)
      : cat = RaceCategory.of(req.goalMeters),
        weekCount = req.weekCount,
        feasibility = Feasibility.assess(req) {
    profile = PaceProfile.fromFitness(
        vdot: req.fitness.vdot,
        mas: req.fitness.mas,
        raceSpeed: feasibility.raceSpeed,
        lthr: req.fitness.lthr);
    phases = PlanRules.phases(weekCount, cat);
    recoveryWeeks = PlanRules.recoveryWeeks(phases, req.experience);
    tests = _testWeeks();
    longIdx = _longRunIndex();
  }

  final PlanRequest req;
  final RaceCategory cat;
  final int weekCount;
  final Feasibility feasibility;
  late final PaceProfile profile;
  late final List<Phase> phases;
  late final Set<int> recoveryWeeks;
  late final Map<int, TestType> tests;

  /// Day index (0 = plan start weekday) of the long run in every week.
  late final int longIdx;

  final warnings = <PlanWarning>[];
  final weeks = <PlanWeek>[];

  // Carry-over between weeks, in minutes.
  double prevActual = 0;
  double lastBuildActual = 0;
  double lastLong = 0;
  bool prevLastDayKey = false;
  int droppedStrength = 0;

  late final double startVolume;
  late final double peakVolume;

  int? get raceOffset => req.raceDayOffset;

  bool _isRaceWeek(int w) => raceOffset != null && w == weekCount - 1;

  TrainingPlan run() {
    final current = _currentVolume();
    startVolume = max(current, 60.0);
    peakVolume = max(
        PlanRules.peakVolume(cat, req.experience).inMinutes.toDouble(),
        startVolume);
    final longest = _minutesOf(req.longestRecentRun, req.longestRecentRunKm);
    lastLong = longest > 0 ? longest : startVolume * 0.3;
    _initialWarnings(current);
    for (var w = 0; w < weekCount; w++) {
      weeks.add(_week(w));
    }
    if (droppedStrength > 0) {
      warnings.add(PlanWarning('strength_dropped',
          '$droppedStrength strength sessions did not fit the availability'));
    }
    return TrainingPlan(
        request: req,
        profile: profile,
        feasibility: feasibility,
        weeks: weeks,
        warnings: warnings);
  }

  double _minutesOf(Duration? d, double? km) {
    if (d != null) return d.inSeconds / 60;
    if (km != null) {
      return km * 1000 / profile.speedFor(Intensity.easy).mid / 60;
    }
    return 0;
  }

  double _currentVolume() {
    final v = _minutesOf(req.currentWeeklyDuration, req.currentWeeklyKm);
    if (v > 0) return v;
    return _minutesOf(req.longestRecentRun, req.longestRecentRunKm) * 2.5;
  }

  void _initialWarnings(double current) {
    final minWeeks = PlanRules.minPlanWeeks(cat);
    if (weekCount < minWeeks) {
      warnings.add(PlanWarning('plan_short',
          '$weekCount weeks is short for this distance (recommended ≥ $minWeeks)'));
    }
    final f = feasibility;
    if (!f.isRealistic) {
      warnings.add(PlanWarning(
          'target_unrealistic',
          'Target needs VDOT ${f.requiredVdot!.toStringAsFixed(1)} vs current '
              '${f.currentVdot.toStringAsFixed(1)}; ~${f.achievableVdot.toStringAsFixed(1)} '
              'is realistic in $weekCount weeks. Race pace uses the realistic value.'));
    } else if (f.targetTime != null && f.targetTime! > f.predictedTime * 1.02) {
      warnings.add(const PlanWarning('target_conservative',
          'Target is slower than current fitness predicts'));
    }
    if (current < startVolume) {
      warnings.add(PlanWarning('low_base',
          'Current volume ${current.round()} min/week is low; plan starts at ${startVolume.round()} min'));
    }
    final pref = req.availability.longRunWeekday;
    if (pref != null && !req.availability[pref].available) {
      warnings.add(const PlanWarning('long_run_day',
          'Preferred long-run day is not available; another day is used'));
    }
    final days = req.availability.availableWeekdays.length;
    if (days < 3 || (cat.isUltra && days < 4)) {
      warnings.add(PlanWarning(
          'few_days', 'Only $days training days per week limits the plan'));
    }
  }

  int _longRunIndex() {
    final a = req.availability;
    int idxOf(int weekday) => (weekday - req.startDate.weekday) % 7;
    final pref = a.longRunWeekday;
    if (pref != null && a[pref].available) return idxOf(pref);
    int cap(int wd) => a[wd].maxDuration?.inMinutes ?? _noCap;
    int rank(int wd) => wd == DateTime.sunday
        ? 9
        : wd == DateTime.saturday
            ? 8
            : wd;
    final best = a.availableWeekdays.reduce((x, y) {
      if (cap(x) != cap(y)) return cap(x) > cap(y) ? x : y;
      return rank(x) >= rank(y) ? x : y;
    });
    return idxOf(best);
  }

  Map<int, TestType> _testWeeks() {
    final defaults = cat.isShort
        ? const [TestType.timeTrial3k, TestType.halfCooper]
        : const [TestType.timeTrial5k, TestType.friel30];
    final prefs = req.preferredTests;
    final result = <int, TestType>{};
    var last = 0;
    for (final w in recoveryWeeks.toList()..sort()) {
      if (w + 1 - last >= 4) {
        result[w] = prefs.isEmpty
            ? defaults.first
            : prefs[result.length % prefs.length];
        last = w + 1;
      }
    }
    return result;
  }

  double _target(int w, Phase phase, bool recovery) {
    if (w == 0) return startVolume;
    if (phase == Phase.taper) {
      final factors = PlanRules.taperFactors(cat, weekCount);
      final taperStart = phases.indexOf(Phase.taper);
      final n = weekCount - taperStart;
      return prevActual * factors[factors.length - n + (w - taperStart)];
    }
    if (recovery) return lastBuildActual * PlanRules.recoveryVolumeFactor;
    final ref = weeks[w - 1].isRecovery ? lastBuildActual : prevActual;
    return min(ref * (1 + PlanRules.weeklyGrowth(req.experience)),
        max(peakVolume, ref));
  }

  int _qualityCount(Phase phase, bool recovery, bool testWeek, int? raceIdx) {
    if (raceIdx != null) return raceIdx >= 3 ? 1 : 0;
    if (testWeek) return 0;
    if (recovery || phase == Phase.taper) return 1;
    return switch (req.experience) {
      Experience.beginner => 1,
      Experience.intermediate => 2,
      Experience.advanced => phase == Phase.base ? 2 : 3,
    };
  }

  List<StrengthSession> _strengthSessions(
      Phase phase, bool recovery, bool raceWeek) {
    final g = req.strength;
    if (!g.isActive) return const [];
    var count = g.sessionsPerWeek;
    var rpe = g.kind == StrengthGoalKind.secondaryGoal ? 8 : 7;
    var minutes = g.sessionDuration.inMinutes.toDouble();
    var areas = g.effectiveFocusAreas;
    if (raceWeek) {
      count = 1;
      rpe = 4;
      minutes *= 0.5;
      areas = const [FocusArea.mobility];
    } else if (phase == Phase.taper || recovery) {
      count = max(1, count - 1);
      rpe = 5;
      minutes *= 0.75;
    }
    final duration = Duration(minutes: max(15, minutes.round()));
    final sessions = [
      for (var i = 0; i < count; i++)
        StrengthSession(
            focusAreas: _roundRobin(areas, i, count),
            duration: duration,
            rpe: rpe,
            style: g.style)
    ];
    // Heavy sessions are placed first; they have the stricter rules.
    return [
      ...sessions.where((s) => s.isHeavyLowerBody),
      ...sessions.where((s) => !s.isHeavyLowerBody),
    ];
  }

  static List<FocusArea> _roundRobin(List<FocusArea> areas, int i, int n) {
    final part = [
      for (var j = 0; j < areas.length; j++)
        if (j % n == i) areas[j]
    ];
    return part.isEmpty ? areas : part;
  }

  static StrengthSession _lighten(StrengthSession s) => s.copyWith(
      rpe: min(s.rpe, 6),
      focusAreas: {
        for (final f in s.focusAreas)
          ...(f == FocusArea.fullBody
              ? const [FocusArea.upperPush, FocusArea.upperPull, FocusArea.core]
              : [f])
      }.toList());

  PlanWeek _week(int w) {
    final phase = phases[w];
    final recovery = recoveryWeeks.contains(w);
    final testType = tests[w];
    final raceIdx = _isRaceWeek(w) ? raceOffset! % 7 : null;
    final weekStart = addDays(req.startDate, 7 * w);
    final dates = [for (var i = 0; i < 7; i++) addDays(weekStart, i)];
    DayAvailability day(int i) => req.availability[dates[i].weekday];
    bool avail(int i) =>
        i >= 0 && i < 7 && (raceIdx == null || i < raceIdx) && day(i).available;
    int capOf(int i) => day(i).maxDuration?.inMinutes ?? _noCap;
    final target = _target(w, phase, recovery);

    // 1. Day roles: long run, test, quality, easy.
    final roles = List<SessionKind?>.filled(7, null);
    final keys = <int>{if (raceIdx != null) raceIdx};
    final nextWeekKeyAtStart = w + 1 < weekCount &&
        (_isRaceWeek(w + 1) ? raceOffset! % 7 == 0 : longIdx == 0);
    bool canKey(int i) =>
        avail(i) &&
        roles[i] == null &&
        !keys.contains(i) &&
        !keys.contains(i - 1) &&
        !keys.contains(i + 1) &&
        !(i == 0 && prevLastDayKey) &&
        !(i == 6 && nextWeekKeyAtStart);
    void setKey(int i, SessionKind k) {
      roles[i] = k;
      keys.add(i);
    }

    int runRoleCount() => roles.where((r) => r != null).length;
    final availCount = [
      for (var i = 0; i < 7; i++)
        if (avail(i)) i
    ].length;
    var runDays = min(min(availCount, PlanRules.maxRunDays(req.experience)),
        raceIdx != null ? 5 : 6);
    // Prefer fewer, ≥ 30 min runs so a quality session still fits.
    while ((runDays > 3 && target / runDays < 30) ||
        (runDays > 2 && target / runDays < _minRun + 2)) {
      runDays--;
    }

    final hasLong = raceIdx == null && canKey(longIdx);
    if (hasLong) setKey(longIdx, SessionKind.long);

    final testWorkout =
        testType == null ? null : SessionTemplates.test(testType, profile);
    final testMinutes = testWorkout == null
        ? 0.0
        : testWorkout.estimatedDuration(profile).inSeconds / 60;
    if (testWorkout != null && testMinutes <= target) {
      for (var i = 6; i >= 0; i--) {
        if (canKey(i) && capOf(i) >= testMinutes) {
          setKey(i, SessionKind.test);
          break;
        }
      }
    }

    final q = [
      _qualityCount(phase, recovery, testWorkout != null, raceIdx),
      PlanRules.maxQualityPerWeek(req.experience),
      runDays - 1 - runRoleCount(),
    ].reduce(min);
    final kinds = raceIdx != null
        ? const [SessionKind.racePace]
        : SessionTemplates.qualityOrder(cat, phase);
    for (final kind in kinds.take(max(0, q))) {
      final candidates = [
        for (var i = 0; i < 7; i++)
          if (canKey(i)) i
      ];
      if (candidates.isEmpty) break;
      setKey(
          raceIdx != null
              ? _closest(candidates, raceIdx - 3)
              : _spread(candidates, keys, circular: true),
          kind);
    }

    var need = runDays - runRoleCount();
    int? b2b;
    if (cat.isUltra &&
        hasLong &&
        !recovery &&
        (phase == Phase.build || phase == Phase.peak) &&
        need > 0) {
      for (final c in [longIdx + 1, longIdx - 1]) {
        if (avail(c) && roles[c] == null && !keys.contains(c)) {
          roles[c] = SessionKind.easy;
          b2b = c;
          need--;
          break;
        }
      }
    }
    for (; need > 0; need--) {
      final candidates = [
        for (var i = 0; i < 7; i++)
          if (avail(i) && roles[i] == null && !keys.contains(i)) i
      ];
      if (candidates.isEmpty) break;
      final runSet = {
        for (var i = 0; i < 7; i++)
          if (roles[i] != null) i
      };
      roles[_spread(candidates, runSet)] = SessionKind.easy;
    }

    // 2. Strength placement (before sizing so runs leave room for it).
    final strength = List<StrengthSession?>.filled(7, null);
    bool isQualityDay(int i) =>
        roles[i]?.isQuality == true && roles[i] != SessionKind.test;
    bool isEasyDay(int i) => roles[i] == SessionKind.easy && i != b2b;
    int sessionDays() => [
          for (var i = 0; i < 7; i++)
            if (roles[i] != null || strength[i] != null || i == raceIdx) i
        ].length;
    bool fits(int i, StrengthSession s, int runMinutes) =>
        capOf(i) - s.duration.inMinutes >= runMinutes;
    bool freeDay(int i, StrengthSession s) =>
        avail(i) &&
        roles[i] == null &&
        strength[i] == null &&
        sessionDays() < 6 &&
        fits(i, s, 0);

    int? placeHeavy(StrengthSession s) {
      for (var i = 0; i < 7; i++) {
        if (isQualityDay(i) &&
            strength[i] == null &&
            fits(i, s, _minQualityWithStrength)) {
          return i;
        }
      }
      // Otherwise ≥ 48 h before the next key session, within this week.
      for (var i = 0; i <= 4; i++) {
        if (keys.contains(i) || keys.contains(i + 1) || keys.contains(i + 2)) {
          continue;
        }
        if ((isEasyDay(i) && strength[i] == null && fits(i, s, _minRun)) ||
            freeDay(i, s)) {
          return i;
        }
      }
      return null;
    }

    int? placeLight(StrengthSession s) {
      for (var i = 0; i < 7; i++) {
        if (isEasyDay(i) && strength[i] == null && fits(i, s, _minRun)) {
          return i;
        }
      }
      for (var i = 0; i < 7; i++) {
        if (freeDay(i, s)) return i;
      }
      for (var i = 0; i < 7; i++) {
        if (isQualityDay(i) &&
            strength[i] == null &&
            fits(i, s, _minQualityWithStrength)) {
          return i;
        }
      }
      return null;
    }

    for (var s in _strengthSessions(phase, recovery, raceIdx != null)) {
      int? i;
      if (s.isHeavyLowerBody) {
        i = placeHeavy(s);
        if (i == null) s = _lighten(s);
      }
      i ??= placeLight(s);
      if (i == null) {
        droppedStrength++;
      } else {
        strength[i] = s;
      }
    }

    // 3. Sizing in whole minutes.
    int capFor(int i) => capOf(i) - (strength[i]?.duration.inMinutes ?? 0);
    var longMin = 0;
    if (hasLong) {
      longMin = [
        target * PlanRules.longRunShareCap(runRoleCount(), cat),
        PlanRules.longRunCap(cat).inMinutes.toDouble(),
        capFor(longIdx).toDouble(),
        recovery || phase == Phase.taper
            ? lastLong
            : lastLong + PlanRules.longRunStep(cat),
      ].reduce(min).floor();
    }
    final testMin = roles.contains(SessionKind.test) ? testMinutes : 0.0;
    if (hasLong) {
      longMin = min(longMin, (target - testMin).floor());
    }
    var b2bMin = 0;
    if (b2b != null) {
      b2bMin = min(longMin * 0.5, capFor(b2b).toDouble()).floor();
      if (b2bMin < _minRun) {
        roles[b2b] = null;
        b2b = null;
        b2bMin = 0;
      }
    }
    final easyMax =
        min(cat.isUltra ? 120 : 90, hasLong ? max(longMin, _minRun) : _noCap);
    final budgets = <int, int>{};
    while (true) {
      budgets.clear();
      final qs = [
        for (var i = 0; i < 7; i++)
          if (isQualityDay(i)) i
      ];
      final es = [
        for (var i = 0; i < 7; i++)
          if (isEasyDay(i)) i
      ];
      final rest = target - longMin - testMin - b2bMin;
      final others = qs.length + es.length;
      final base = others == 0 ? 0.0 : rest / others;
      final factor = es.isEmpty ? 1.0 : 1.15;
      for (final i in qs) {
        budgets[i] =
            [base * factor, 80.0, capFor(i).toDouble()].reduce(min).floor();
      }
      final qSum = budgets.values.fold(0, (a, b) => a + b);
      final easy = es.isEmpty ? 0 : ((rest - qSum) / es.length).floor();
      if (es.isNotEmpty && easy < _minRun) {
        roles[es.last] = null;
        continue;
      }
      // Water-fill: volume capped on one day flows to the others.
      var pool = rest - qSum;
      final byCap = [...es]..sort(
          (a, b) => min(easyMax, capFor(a)).compareTo(min(easyMax, capFor(b))));
      for (var k = 0; k < byCap.length; k++) {
        final i = byCap[k];
        final share = (pool / (byCap.length - k)).floor();
        budgets[i] = min(share, min(easyMax, capFor(i)));
        pool -= budgets[i]!;
      }
      break;
    }

    // 4. Workouts.
    final runs = <int, ({SessionKind kind, Workout workout, bool key})>{};
    final taperLike = recovery || phase == Phase.taper;
    var stridesGiven = taperLike || raceIdx != null;
    bool afterKey(int i) => i == 0 ? prevLastDayKey : keys.contains(i - 1);
    for (var i = 0; i < 7; i++) {
      final role = roles[i];
      final budget = Duration(minutes: budgets[i] ?? 0);
      if (role == null || role == SessionKind.long) continue;
      if (role == SessionKind.test) {
        runs[i] = (kind: role, workout: testWorkout!, key: true);
      } else if (i == b2b) {
        runs[i] = (
          kind: SessionKind.easy,
          workout: SessionTemplates.easy(Duration(minutes: b2bMin),
              title: 'Back-to-back long run',
              note: 'Time on feet on tired legs, keep it easy'),
          key: false
        );
      } else if (isQualityDay(i)) {
        final wo = raceIdx != null
            ? SessionTemplates.sharpener(budget, profile, cat)
            : SessionTemplates.quality(role,
                budget: budget,
                profile: profile,
                category: cat,
                phase: phase,
                weeklyVolume: Duration(minutes: target.floor()),
                light: taperLike);
        if (wo != null) {
          runs[i] = (kind: role, workout: wo, key: true);
        } else if (budget.inMinutes >= _minRun) {
          runs[i] = (
            kind: SessionKind.easy,
            workout: SessionTemplates.easy(budget, strides: true),
            key: false
          );
        }
      } else if (budget.inMinutes >= _minRun) {
        final recoveryRun = afterKey(i);
        final strides = !recoveryRun && !stridesGiven;
        stridesGiven |= strides;
        runs[i] = (
          kind: recoveryRun ? SessionKind.recovery : SessionKind.easy,
          workout: SessionTemplates.easy(budget,
              intensity: recoveryRun ? Intensity.recovery : Intensity.easy,
              strides: strides),
          key: false
        );
      }
    }

    // Long-run share cap against the final week.
    Workout? longWorkout;
    if (hasLong) {
      final others = runs.values.fold(0.0,
          (a, r) => a + r.workout.estimatedRunDuration(profile).inSeconds / 60);
      final share = PlanRules.longRunShareCap(runs.length + 1, cat);
      longMin = min(longMin, (share * others / (1 - share)).floor());
      if (longMin > 0) longWorkout = _longWorkout(longMin, phase, recovery);
    }

    // 5. Assemble in date order; strength goes after the run.
    final sessions = <PlannedSession>[];
    for (var i = 0; i < 7; i++) {
      final date = dates[i];
      final s = strength[i];
      final r = runs[i];
      if (i == longIdx && longWorkout != null) {
        sessions.add(PlannedSession(
            date: date,
            kind: SessionKind.long,
            workout: longWorkout,
            isKey: true));
      }
      if (r != null && s != null && !r.key && i != b2b) {
        final intensity = r.kind == SessionKind.recovery
            ? Intensity.recovery
            : Intensity.easy;
        sessions.add(PlannedSession(
            date: date,
            kind: SessionKind.combined,
            workout: s.combineWithRun(r.workout.estimatedRunDuration(profile),
                placement: s.style == StrengthStyle.calisthenics
                    ? StrengthPlacement.during
                    : StrengthPlacement.after,
                intensity: intensity),
            strength: s));
        continue;
      }
      if (r != null) {
        sessions.add(PlannedSession(
            date: date, kind: r.kind, workout: r.workout, isKey: r.key));
      }
      if (s != null) {
        sessions.add(PlannedSession(
            date: date,
            kind: SessionKind.strength,
            workout: s.toWorkout(),
            strength: s));
      }
      if (i == raceIdx) {
        sessions.add(PlannedSession(
            date: date,
            kind: SessionKind.race,
            workout: SessionTemplates.race(req.goalMeters),
            isKey: true));
      }
    }

    final week = PlanWeek(
        index: w,
        startDate: weekStart,
        phase: phase,
        isRecovery: recovery,
        targetVolume: Duration(minutes: target.floor()),
        sessions: sessions);
    final actual = week.runningVolume(profile).inSeconds / 60;
    prevActual = actual;
    if (!recovery && phase != Phase.taper) {
      lastBuildActual = actual;
      if (hasLong) lastLong = longMin.toDouble();
    }
    final lastDay = dayNumber(dates[6]);
    // Heavy strength on the last day also blocks a key session next morning.
    prevLastDayKey = sessions.any((s) =>
        dayNumber(s.date) == lastDay &&
        (s.isKey || (s.strength?.isHeavyLowerBody ?? false)));
    return week;
  }

  Workout _longWorkout(int minutes, Phase phase, bool recovery) {
    var finish = 0;
    var intensity = Intensity.marathon;
    final sharp = !recovery && (phase == Phase.build || phase == Phase.peak);
    if (sharp && cat == RaceCategory.marathon) {
      finish = phase == Phase.peak
          ? min(minutes * 0.35, 70).floor()
          : min(minutes * 0.2, 40).floor();
    } else if (sharp && cat == RaceCategory.half && phase == Phase.peak) {
      finish = min(minutes * 0.2, 25).floor();
      intensity = Intensity.racePace;
    }
    return SessionTemplates.long(Duration(minutes: minutes),
        finish: Duration(minutes: finish),
        finishIntensity: intensity,
        timeOnFeet: cat.isUltra);
  }

  /// Candidate furthest from [taken]; ties go to the earlier day.
  static int _spread(List<int> candidates, Set<int> taken,
      {bool circular = false}) {
    if (taken.isEmpty) return candidates.first;
    int dist(int a, int b) {
      final d = (a - b).abs();
      return circular ? min(d, 7 - d) : d;
    }

    var best = candidates.first, bestScore = -1;
    for (final c in candidates) {
      final score = taken.map((t) => dist(c, t)).reduce(min);
      if (score > bestScore) {
        best = c;
        bestScore = score;
      }
    }
    return best;
  }

  static int _closest(List<int> candidates, int to) =>
      candidates.reduce((a, b) => (b - to).abs() < (a - to).abs() ? b : a);
}
