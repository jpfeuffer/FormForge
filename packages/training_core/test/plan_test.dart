import 'dart:convert';

import 'package:test/test.dart';
import 'package:training_core/training_core.dart';

const distances = [5000.0, 10000.0, 21097.5, 42195.0, 50000.0, 100000.0];

WeeklyAvailability availability(int days, {Duration? weekdayMax}) {
  final pattern = switch (days) {
    3 => [DateTime.tuesday, DateTime.thursday, DateTime.sunday],
    4 => [
        DateTime.tuesday,
        DateTime.thursday,
        DateTime.saturday,
        DateTime.sunday
      ],
    5 => [1, 2, 4, 6, 7],
    6 => [1, 2, 3, 4, 6, 7],
    _ => [1, 2, 3, 4, 5, 6, 7],
  };
  return WeeklyAvailability({
    for (final d in pattern)
      d: DayAvailability(
          maxDuration: d >= DateTime.saturday ? null : weekdayMax)
  });
}

PlanRequest request({
  double meters = 42195,
  int weeks = 16,
  bool raceDate = true,
  int days = 5,
  Experience experience = Experience.intermediate,
  StrengthGoal strength = const StrengthGoal.none(),
  Duration? target,
  Duration? weekdayMax,
  DateTime? start,
  List<TestType> tests = const [],
  double vdot = 45,
}) {
  final s = start ?? DateTime(2026, 3, 2);
  return PlanRequest(
    goalMeters: meters,
    startDate: s,
    raceDate:
        raceDate ? DateTime(s.year, s.month, s.day + weeks * 7 - 1) : null,
    weeks: raceDate ? null : weeks,
    targetTime: target,
    fitness: CurrentFitness(vdot: vdot, lthr: 168),
    availability: availability(days, weekdayMax: weekdayMax),
    currentWeeklyDuration: Duration(
        minutes: switch (experience) {
      Experience.beginner => 100,
      Experience.intermediate => 200,
      Experience.advanced => 330,
    }),
    longestRecentRun: const Duration(minutes: 70),
    experience: experience,
    strength: strength,
    preferredTests: tests,
  );
}

List<PlanViolation> errors(TrainingPlan p) => PlanValidator.validate(p)
    .where((v) => v.severity == Severity.error)
    .toList();

int day(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 86400000;

void main() {
  group('periodization', () {
    test('phases are ordered and sum to plan length', () {
      for (final c in RaceCategory.values) {
        for (var weeks = 2; weeks <= 24; weeks++) {
          final phases = PlanRules.phases(weeks, c);
          expect(phases.length, weeks);
          final sorted = [...phases]
            ..sort((a, b) => a.index.compareTo(b.index));
          expect(phases, sorted);
          expect(phases.last, Phase.taper);
        }
      }
    });

    test('taper length by distance', () {
      int taper(RaceCategory c, int w) =>
          PlanRules.phases(w, c).where((p) => p == Phase.taper).length;
      expect(taper(RaceCategory.fiveK, 12), 1);
      expect(taper(RaceCategory.tenK, 12), 1);
      expect(taper(RaceCategory.half, 12), 2);
      expect(taper(RaceCategory.marathon, 12), 2);
      expect(taper(RaceCategory.marathon, 18), 3);
      expect(taper(RaceCategory.ultra100, 24), 4);
    });

    test('recovery every 3rd (beginner) / 4th week, not before taper', () {
      final phases = PlanRules.phases(16, RaceCategory.marathon);
      expect(
          PlanRules.recoveryWeeks(phases, Experience.beginner), {2, 5, 8, 11});
      expect(PlanRules.recoveryWeeks(phases, Experience.advanced), {3, 7, 11});
      final short = PlanRules.phases(9, RaceCategory.tenK);
      expect(PlanRules.recoveryWeeks(short, Experience.advanced), {3});
    });

    test('race category buckets', () {
      expect(RaceCategory.of(3000), RaceCategory.fiveK);
      expect(RaceCategory.of(15000), RaceCategory.tenK);
      expect(RaceCategory.of(30000), RaceCategory.half);
      expect(RaceCategory.of(42195), RaceCategory.marathon);
      expect(RaceCategory.of(60000), RaceCategory.ultra50);
      expect(RaceCategory.of(100000), RaceCategory.ultra100);
    });
  });

  group('feasibility', () {
    test('realistic target sets race pace from target time', () {
      final r = request(
          meters: 10000, weeks: 12, target: const Duration(minutes: 45));
      final f = Feasibility.assess(r);
      expect(f.currentVdot, 45);
      expect(f.isRealistic, isTrue);
      expect(f.raceSpeed, closeTo(10000 / 2700, 1e-9));
      expect(f.requiredGain, closeTo(45.3 - 45, 0.3));
    });

    test('unrealistic target warns and caps race pace', () {
      final r =
          request(meters: 10000, weeks: 8, target: const Duration(minutes: 36));
      final plan = PlanGenerator.generate(r);
      expect(plan.feasibility.isRealistic, isFalse);
      expect(plan.warnings.map((w) => w.code), contains('target_unrealistic'));
      expect(plan.feasibility.raceSpeed, lessThan(10000 / 2160));
      final predicted = 10000 /
          Vdot.predictTime(plan.feasibility.achievableVdot, 10000).inSeconds;
      expect(plan.profile.speedFor(Intensity.racePace).mid,
          closeTo(predicted, 0.01));
    });

    test('MAS-only fitness works', () {
      final r = PlanRequest(
          goalMeters: 5000,
          weeks: 8,
          startDate: DateTime(2026, 1, 5),
          fitness: const CurrentFitness(mas: 4.6),
          availability: availability(4));
      final plan = PlanGenerator.generate(r);
      expect(plan.feasibility.currentVdot,
          closeTo(PaceProfile.vdotFromMas(4.6), 1e-9));
      expect(errors(plan), isEmpty);
    });

    test('invalid requests throw', () {
      expect(
          () => PlanRequest(
              goalMeters: 5000,
              startDate: DateTime(2026),
              fitness: const CurrentFitness(vdot: 40),
              availability: availability(3)),
          throwsArgumentError);
      expect(
          () => PlanRequest(
              goalMeters: 5000,
              weeks: 8,
              startDate: DateTime(2026),
              fitness: const CurrentFitness(),
              availability: availability(3)),
          throwsArgumentError);
    });
  });

  group('generator', () {
    final marathon = PlanGenerator.generate(request(
        strength: const StrengthGoal(
            kind: StrengthGoalKind.runningSupport, sessionsPerWeek: 2)));

    test('covers start to race day with the race on race day', () {
      final r = marathon.request;
      expect(marathon.weeks.length, 16);
      final race = marathon.sessions.where((s) => s.kind == SessionKind.race);
      expect(race.length, 1);
      expect(day(race.single.date), day(r.raceDate!));
      expect(marathon.sessions.every((s) => !s.date.isBefore(r.startDate)),
          isTrue);
      expect(
          marathon.sessions.every((s) => !s.date.isAfter(r.raceDate!)), isTrue);
    });

    test('is deterministic', () {
      String dump(TrainingPlan p) => jsonEncode([
            for (final s in p.sessions)
              [s.date.toIso8601String(), s.kind.name, s.workout.toJson()]
          ]);
      final again = PlanGenerator.generate(marathon.request);
      expect(dump(again), dump(marathon));
    });

    test('volume builds then tapers', () {
      final v = [
        for (final w in marathon.weeks)
          w.runningVolume(marathon.profile).inMinutes
      ];
      final peak = v.reduce((a, b) => a > b ? a : b);
      expect(peak, greaterThan(v.first));
      final taper = marathon.weeks.where((w) => w.phase == Phase.taper);
      for (final w in taper) {
        expect(v[w.index], lessThan(v[w.index - 1]));
      }
    });

    test('recovery weeks cut volume by ~25%', () {
      final p = marathon.profile;
      for (final w in marathon.weeks.where((w) => w.isRecovery)) {
        final before = marathon.weeks[w.index - 1].runningVolume(p).inMinutes;
        final vol = w.runningVolume(p).inMinutes;
        expect(vol, lessThanOrEqualTo(before * 0.76));
        expect(vol, greaterThan(before * 0.5));
      }
    });

    test('tests at end of recovery weeks every 4–6 weeks, none in taper', () {
      final testWeeks = [
        for (final w in marathon.weeks)
          if (w.sessions.any((s) => s.kind == SessionKind.test)) w
      ];
      expect(testWeeks, isNotEmpty);
      for (final w in testWeeks) {
        expect(w.isRecovery, isTrue);
        expect(w.phase, isNot(Phase.taper));
        final t = w.sessions.firstWhere((s) => s.kind == SessionKind.test);
        expect(t.workout.test, TestType.timeTrial5k);
        expect(t.isKey, isTrue);
      }
      for (var i = 1; i < testWeeks.length; i++) {
        final gap = testWeeks[i].index - testWeeks[i - 1].index;
        expect(gap, inInclusiveRange(4, 6));
      }
    });

    test('test type by goal and preference', () {
      TestType? firstTest(TrainingPlan p) =>
          p.sessions.firstWhere((s) => s.kind == SessionKind.test).workout.test;
      expect(
          firstTest(PlanGenerator.generate(request(meters: 5000, weeks: 12))),
          TestType.timeTrial3k);
      expect(
          firstTest(PlanGenerator.generate(
              request(meters: 5000, weeks: 12, tests: [TestType.halfCooper]))),
          TestType.halfCooper);
      expect(
          firstTest(PlanGenerator.generate(
              request(meters: 21097.5, weeks: 12, tests: [TestType.friel30]))),
          TestType.friel30);
    });

    test('workouts use symbolic intensity targets', () {
      for (final s in marathon.sessions) {
        for (final step in s.workout.flatten()) {
          expect(step.target, isNot(isA<SpeedTarget>()));
          expect(step.target, isNot(isA<HeartRateTarget>()));
        }
      }
    });

    test('marathon plan has marathon-pace work and long runs ≤ 3 h', () {
      expect(marathon.sessions.any((s) => s.kind == SessionKind.marathonPace),
          isTrue);
      final longs = marathon.sessions.where((s) => s.kind == SessionKind.long);
      expect(longs.length, greaterThan(10));
      for (final l in longs) {
        expect(l.workout.estimatedRunDuration(marathon.profile),
            lessThanOrEqualTo(const Duration(hours: 3)));
      }
    });

    test('ultra plans schedule back-to-back long runs', () {
      final plan = PlanGenerator.generate(request(
          meters: 100000, weeks: 20, days: 6, experience: Experience.advanced));
      expect(
          plan.sessions.any((s) => s.workout.title == 'Back-to-back long run'),
          isTrue);
      expect(errors(plan), isEmpty);
    });

    test('5K plan has intervals and race-pace work', () {
      final plan = PlanGenerator.generate(request(meters: 5000, weeks: 10));
      final kinds = plan.sessions.map((s) => s.kind).toSet();
      expect(kinds, containsAll([SessionKind.interval, SessionKind.racePace]));
    });

    test('at least one rest day and only available days', () {
      final plan = PlanGenerator.generate(
          request(days: 7, experience: Experience.advanced));
      for (final w in plan.weeks) {
        final days = w.sessions.map((s) => day(s.date)).toSet();
        expect(days.length, lessThan(7));
      }
      final three = PlanGenerator.generate(request(days: 3));
      final allowed = {DateTime.tuesday, DateTime.thursday, DateTime.sunday};
      for (final s in three.sessions.where((s) => s.kind != SessionKind.race)) {
        expect(allowed, contains(s.date.weekday));
      }
    });

    test('respects max duration per day', () {
      final plan = PlanGenerator.generate(
          request(weekdayMax: const Duration(minutes: 50), days: 5));
      for (final s in plan.sessions) {
        if (s.date.weekday < DateTime.saturday) {
          expect(s.workout.estimatedDuration(plan.profile).inSeconds,
              lessThanOrEqualTo(50 * 60 + 60));
        }
      }
      expect(errors(plan), isEmpty);
    });

    test('preferred long-run weekday is used', () {
      final r = request();
      final plan = PlanGenerator.generate(PlanRequest(
          goalMeters: r.goalMeters,
          weeks: 12,
          startDate: r.startDate,
          fitness: r.fitness,
          availability: WeeklyAvailability.on([1, 2, 4, 6, 7],
              longRunWeekday: DateTime.saturday),
          currentWeeklyDuration: const Duration(minutes: 200)));
      final longs = plan.sessions.where((s) => s.kind == SessionKind.long);
      expect(longs.every((s) => s.date.weekday == DateTime.saturday), isTrue);
    });
  });

  group('strength scheduling', () {
    TrainingPlan plan(StrengthGoal g, {int days = 5}) =>
        PlanGenerator.generate(request(strength: g, days: days));

    test('respects sessions per week and reduces in recovery/taper', () {
      final p = plan(const StrengthGoal(
          kind: StrengthGoalKind.secondaryGoal,
          sessionsPerWeek: 3,
          style: StrengthStyle.gym));
      for (final w in p.weeks) {
        final n = w.sessions.where((s) => s.strength != null).length;
        expect(n, lessThanOrEqualTo(3));
        if (w.isRecovery || w.phase == Phase.taper) {
          expect(n, lessThanOrEqualTo(2));
          for (final s in w.sessions.where((s) => s.strength != null)) {
            expect(s.strength!.rpe, lessThanOrEqualTo(5));
          }
        }
      }
    });

    test('calisthenics sandwiched into easy runs', () {
      final p = plan(const StrengthGoal(
          kind: StrengthGoalKind.runningSupport,
          focusAreas: [FocusArea.core, FocusArea.upperPull],
          sessionsPerWeek: 2));
      final combined = p.sessions.where((s) => s.kind == SessionKind.combined);
      expect(combined, isNotEmpty);
      for (final s in combined) {
        expect(s.workout.sport, Sport.combined);
        expect(s.isKey, isFalse);
        expect(s.workout.flatten().map((e) => e.kind).toList(),
            [StepKind.active, StepKind.strength, StepKind.active]);
      }
    });

    test('heavy lower-body never the day before a key session', () {
      for (final days in [3, 4, 5, 6, 7]) {
        final p = plan(
            const StrengthGoal(
                kind: StrengthGoalKind.secondaryGoal,
                focusAreas: [FocusArea.lowerBody, FocusArea.plyometrics],
                sessionsPerWeek: 2),
            days: days);
        final keyDays = {
          for (final s in p.sessions)
            if (s.isKey) day(s.date)
        };
        final heavy =
            p.sessions.where((s) => s.strength?.isHeavyLowerBody ?? false);
        expect(heavy, isNotEmpty);
        for (final s in heavy) {
          expect(keyDays, isNot(contains(day(s.date) + 1)));
        }
      }
    });
  });

  group('validator', () {
    final base = PlanGenerator.generate(request(weeks: 12));

    TrainingPlan withWeek(
            int index, List<PlannedSession> Function(PlanWeek) f) =>
        TrainingPlan(
            request: base.request,
            profile: base.profile,
            feasibility: base.feasibility,
            warnings: base.warnings,
            weeks: [
              for (final w in base.weeks)
                w.index == index
                    ? PlanWeek(
                        index: w.index,
                        startDate: w.startDate,
                        phase: w.phase,
                        isRecovery: w.isRecovery,
                        targetVolume: w.targetVolume,
                        sessions: f(w))
                    : w
            ]);

    Set<String> codes(TrainingPlan p) => errors(p).map((v) => v.code).toSet();

    PlannedSession session(DateTime d, SessionKind k, Duration dur,
            {bool key = false, StrengthSession? strength}) =>
        PlannedSession(
            date: d,
            kind: k,
            workout: SessionTemplates.easy(dur),
            isKey: key,
            strength: strength);

    test('generated plan is clean', () {
      expect(errors(base), isEmpty);
    });

    test('detects consecutive key days', () {
      final p = withWeek(2, (w) {
        final long = w.sessions.firstWhere((s) => s.kind == SessionKind.long);
        return [
          ...w.sessions,
          session(DateTime(long.date.year, long.date.month, long.date.day - 1),
              SessionKind.threshold, const Duration(minutes: 20),
              key: true),
        ];
      });
      expect(codes(p), contains('consecutive_key_days'));
    });

    test('detects volume ramp and long-run caps', () {
      final p = withWeek(1, (w) {
        final long = w.sessions.firstWhere((s) => s.kind == SessionKind.long);
        return [
          for (final s in w.sessions)
            if (s != long) s,
          PlannedSession(
              date: long.date,
              kind: SessionKind.long,
              workout: SessionTemplates.long(const Duration(hours: 4)),
              isKey: true),
        ];
      });
      expect(codes(p),
          containsAll(['volume_ramp', 'long_run_share', 'long_run_duration']));
    });

    test('detects missing rest day and unavailable days', () {
      final p = withWeek(
          3,
          (w) => [
                for (var i = 0; i < 7; i++)
                  session(w.startDate.add(Duration(days: i)), SessionKind.easy,
                      const Duration(minutes: 20)),
              ]);
      expect(codes(p), containsAll(['no_rest_day', 'unavailable_day']));
    });

    test('detects max duration and heavy strength before key', () {
      final r = request(weeks: 12, weekdayMax: const Duration(minutes: 40));
      final plan = PlanGenerator.generate(r);
      expect(errors(plan), isEmpty);
      final week = plan.weeks[1];
      final long = week.sessions.firstWhere((s) => s.kind == SessionKind.long);
      final dayBefore =
          DateTime(long.date.year, long.date.month, long.date.day - 1);
      final heavy = StrengthSession(
          focusAreas: const [FocusArea.lowerBody],
          duration: const Duration(minutes: 60),
          rpe: 8);
      final bad = TrainingPlan(
          request: r,
          profile: plan.profile,
          feasibility: plan.feasibility,
          warnings: const [],
          weeks: [
            for (final w in plan.weeks)
              w.index == 1
                  ? PlanWeek(
                      index: 1,
                      startDate: w.startDate,
                      phase: w.phase,
                      isRecovery: w.isRecovery,
                      targetVolume: w.targetVolume,
                      sessions: [
                          ...w.sessions,
                          PlannedSession(
                              date: dayBefore,
                              kind: SessionKind.strength,
                              workout: heavy.toWorkout(),
                              strength: heavy),
                          session(
                              DateTime(long.date.year, long.date.month,
                                  long.date.day - 5),
                              SessionKind.easy,
                              const Duration(minutes: 90)),
                        ])
                  : w
          ]);
      expect(codes(bad),
          containsAll(['heavy_strength_before_key', 'max_duration']));
    });

    test('detects non-decreasing taper and missing race', () {
      final last = base.weeks.last;
      final p = withWeek(
          last.index,
          (w) => [
                for (var i = 0; i < 5; i++)
                  if (i.isEven)
                    session(w.startDate.add(Duration(days: i)),
                        SessionKind.easy, const Duration(minutes: 200)),
              ]);
      expect(codes(p), containsAll(['taper_not_decreasing', 'race_missing']));
    });
  });

  group('guardrails hold across parameter space', () {
    for (final meters in distances) {
      test('${meters ~/ 1000} km', () {
        final failures = <String>[];
        var plans = 0;
        for (final weeks in [6, 8, 10, 12, 14, 16, 20, 24]) {
          for (final days in [3, 4, 5, 6, 7]) {
            for (final experience in Experience.values) {
              for (final (i, strength) in const [
                StrengthGoal.none(),
                StrengthGoal(
                    kind: StrengthGoalKind.runningSupport, sessionsPerWeek: 2),
                StrengthGoal(
                    kind: StrengthGoalKind.secondaryGoal,
                    sessionsPerWeek: 3,
                    style: StrengthStyle.gym,
                    sessionDuration: Duration(minutes: 45)),
              ].indexed) {
                final r = request(
                  meters: meters,
                  weeks: weeks,
                  days: days,
                  experience: experience,
                  strength: strength,
                  raceDate: (weeks + days + i).isEven,
                  weekdayMax: i == 2 ? const Duration(minutes: 75) : null,
                  start: DateTime(2026, 3, 2 + (weeks + days) % 7),
                  vdot: 35 + (days + i) * 3,
                );
                final plan = PlanGenerator.generate(r);
                plans++;
                for (final e in errors(plan)) {
                  failures.add('w$weeks d$days ${experience.name} s$i: $e');
                }
              }
            }
          }
        }
        expect(plans, 8 * 5 * 3 * 3);
        expect(failures, isEmpty, reason: failures.take(20).join('\n'));
      });
    }
  });
}
