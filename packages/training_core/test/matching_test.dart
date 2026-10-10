import 'package:test/test.dart';
import 'package:training_core/training_core.dart';

import 'synthetic_samples.dart';

void main() {
  final profile = PaceProfile.fromVdot(50, lthr: 170);
  final matcher = ActivityMatcher(profile);
  final easy = profile.speedFor(Intensity.easy).mid;
  final rep = profile.speedFor(Intensity.interval).mid;
  final repSeconds = (200 / rep).round();

  WorkoutStep run(int minutes, Intensity i, [StepKind k = StepKind.active]) =>
      WorkoutStep(
        kind: k,
        end: TimeEnd(Duration(minutes: minutes)),
        target: IntensityTarget(i),
      );

  Workout easyRun(int minutes, {String title = 'Easy run'}) => Workout(
        sport: Sport.run,
        title: title,
        elements: [run(minutes, Intensity.easy)],
      );

  // 10 min warm-up, 10 × 200 m / 60 s jog, 5 min cool-down.
  final intervals = Workout(
    sport: Sport.run,
    title: '10 × 200 m',
    elements: [
      run(10, Intensity.easy, StepKind.warmup),
      RepeatBlock(
        times: 10,
        elements: const [
          WorkoutStep(
            kind: StepKind.active,
            end: DistanceEnd(200),
            target: IntensityTarget(Intensity.interval),
          ),
          WorkoutStep(
            kind: StepKind.recovery,
            end: TimeEnd(Duration(seconds: 60)),
            target: IntensityTarget(Intensity.recovery),
          ),
        ],
      ),
      run(5, Intensity.easy, StepKind.cooldown),
    ],
  );

  final strength = Workout(
    sport: Sport.strength,
    title: 'Core',
    elements: const [
      WorkoutStep(
        kind: StepKind.strength,
        end: LapButtonEnd(),
        estimate: Duration(minutes: 30),
      ),
    ],
  );

  // Monday of a week; day(0) = Mon.
  DateTime day(int offset) => DateTime(2026, 9, 14 + offset);

  PlannedCandidate planned(
    int id,
    int dayOffset,
    Workout w, {
    SessionKind kind = SessionKind.easy,
    int? startMinute,
    String? garminId,
  }) =>
      PlannedCandidate(
        id: id,
        day: day(dayOffset),
        startMinute: startMinute,
        kind: kind,
        workout: w,
        title: w.title,
        garminWorkoutId: garminId,
      );

  ActivityCandidate activity(
    int id,
    int dayOffset,
    List<Part> parts, {
    int startMinute = 7 * 60,
    bool laps = false,
    String? name,
    String? garminId,
  }) {
    final samples = synth(parts);
    return ActivityCandidate(
      id: id,
      day: day(dayOffset),
      startMinute: startMinute,
      durationS: samples.last.second,
      distanceM: samples.last.distance,
      isRun: true,
      samples: samples,
      pauses: Pauses.detect(
        [for (final s in samples) s.second],
        [for (final s in samples) s.speed],
      ),
      workoutName: name,
      garminWorkoutId: garminId,
    );
  }

  List<Part> intervalParts() => [
        part(600, easy),
        for (var i = 0; i < 10; i++) ...[
          part(repSeconds, 200 / repSeconds),
          if (i < 9) part(60, 2.3),
        ],
        part(300, easy),
      ];

  List<Part> easyParts(int minutes) => [part(minutes * 60, easy)];

  group('score', () {
    test('intervals are told apart from an easy run of the same length', () {
      final plan = planned(1, 0, intervals, kind: SessionKind.interval);
      final done = activity(1, 0, intervalParts());
      final jog = activity(
        2,
        0,
        easyParts((done.durationS / 60).round()),
      );
      expect(matcher.score(plan, done).score, greaterThan(0.9));
      expect(matcher.score(plan, jog).score, lessThan(0.6));

      final easyPlan = planned(2, 0, easyRun((done.durationS / 60).round()));
      expect(
        matcher.score(easyPlan, jog).score,
        greaterThan(matcher.score(easyPlan, done).score + 0.1),
      );
    });

    test('day proximity lowers the score', () {
      final plan = planned(1, 1, easyRun(40));
      final same = matcher.score(plan, activity(1, 1, easyParts(40))).score;
      final next = matcher.score(plan, activity(1, 2, easyParts(40))).score;
      final far = matcher.score(plan, activity(1, 5, easyParts(40))).score;
      expect(same, greaterThan(next));
      expect(next, greaterThan(far));
    });

    test('strength and runs never match each other', () {
      final run = activity(1, 0, easyParts(30));
      expect(
        matcher
            .score(planned(1, 0, strength, kind: SessionKind.strength), run)
            .score,
        0,
      );
      final lift = ActivityCandidate(
        id: 2,
        day: day(0),
        startMinute: 600,
        durationS: 1800,
        isRun: false,
      );
      expect(matcher.score(planned(2, 0, easyRun(30)), lift).score, 0);
      expect(
        matcher
            .score(planned(1, 0, strength, kind: SessionKind.strength), lift)
            .score,
        greaterThan(0.9),
      );
    });

    test('combined workouts compare their run part', () {
      final combined = Workout(
        sport: Sport.combined,
        title: 'Run + core',
        elements: [
          run(30, Intensity.easy),
          const WorkoutStep(
            kind: StepKind.strength,
            end: LapButtonEnd(),
            estimate: Duration(minutes: 20),
          ),
        ],
      );
      final s = matcher.score(
        planned(1, 0, combined, kind: SessionKind.combined),
        activity(1, 0, easyParts(30)),
      );
      expect(s.score, greaterThan(0.9));
    });

    test('lap structure is used when the lap count fits the steps', () {
      final done = activity(1, 0, intervalParts());
      var start = 0;
      final laps = <LapSegment>[];
      for (final p in intervalParts()) {
        laps.add(
          LapSegment(
            startSecond: start,
            durationS: p.seconds,
            distanceM: p.speed * p.seconds,
          ),
        );
        start += p.seconds;
      }
      final withLaps = ActivityCandidate(
        id: done.id,
        day: done.day,
        startMinute: done.startMinute,
        durationS: done.durationS,
        distanceM: done.distanceM,
        isRun: true,
        laps: laps,
      );
      final s = matcher.score(planned(1, 0, intervals), withLaps);
      expect(s.score, greaterThan(0.9));
    });
  });

  group('assign', () {
    test('swapped days get the crossing assignment', () {
      final result = matcher.assign(
        planned: [
          planned(1, 2, easyRun(45)), // Wed easy
          planned(2, 3, easyRun(90, title: 'Long run'), kind: SessionKind.long),
        ],
        activities: [
          activity(10, 2, easyParts(90)), // Wed: the long run
          activity(11, 3, easyParts(45)), // Thu: the easy run
        ],
      );
      final byPlanned = {for (final r in result.results) r.plannedId: r};
      expect(byPlanned[1]!.activityId, 11);
      expect(byPlanned[2]!.activityId, 10);
      expect(result.high, hasLength(2));
      expect(result.unmatchedActivityIds, isEmpty);
    });

    test('two runs on one day find their own planned workout by time', () {
      final result = matcher.assign(
        planned: [
          planned(1, 1, easyRun(30), startMinute: 7 * 60),
          planned(2, 1, easyRun(30), startMinute: 18 * 60),
        ],
        activities: [
          activity(10, 1, easyParts(30), startMinute: 18 * 60 + 5),
          activity(11, 1, easyParts(30), startMinute: 7 * 60 + 5),
        ],
      );
      final byPlanned = {for (final r in result.results) r.plannedId: r};
      expect(byPlanned[1]!.activityId, 11);
      expect(byPlanned[2]!.activityId, 10);
    });

    test('an extra unplanned run stays unmatched', () {
      final result = matcher.assign(
        planned: [planned(1, 1, easyRun(40))],
        activities: [
          activity(10, 1, easyParts(40), startMinute: 7 * 60),
          activity(11, 1, easyParts(12), startMinute: 19 * 60),
        ],
      );
      expect(result.results.single.activityId, 10);
      expect(result.results.single.confidence, MatchConfidence.high);
      expect(result.unplannedActivityIds, [11]);
    });

    test('a missed workout stays unmatched', () {
      final result = matcher.assign(
        planned: [
          planned(1, 0, intervals, kind: SessionKind.interval),
          planned(2, 2, easyRun(45)),
        ],
        activities: [activity(10, 2, easyParts(45))],
      );
      expect(result.results.single.plannedId, 2);
      expect(result.unmatchedPlannedIds, [1]);
    });

    test('the Garmin workout id wins over equally plausible days', () {
      final plans = [
        planned(1, 1, easyRun(40), garminId: 'g1'),
        planned(2, 3, easyRun(40), garminId: 'g2'),
      ];
      final withId = matcher.assign(
        planned: plans,
        activities: [activity(10, 2, easyParts(40), garminId: 'g2')],
      );
      expect(withId.results.single.plannedId, 2);
      expect(withId.results.single.confidence, MatchConfidence.high);
      expect(withId.results.single.reasons.first, contains('pushed Garmin'));

      final without = matcher.assign(
        planned: plans,
        activities: [activity(10, 2, easyParts(40))],
      );
      expect(without.results.single.confidence, MatchConfidence.medium);
    });

    test('an activity started as another workout is not its look-alike', () {
      final result = matcher.assign(
        planned: [
          planned(1, 2, easyRun(40), garminId: 'g1'),
          planned(2, 2, easyRun(40), garminId: 'g2'),
        ],
        activities: [activity(10, 2, easyParts(40), garminId: 'g2')],
      );
      expect(result.results.single.plannedId, 2);
    });

    test('a matching workout name raises the score', () {
      final plan = planned(1, 1, intervals, kind: SessionKind.interval);
      final jog = activity(1, 2, easyParts(30));
      final named = activity(1, 2, easyParts(30), name: '10 × 200 m [FF]');
      expect(
        matcher.score(plan, named).score,
        greaterThan(matcher.score(plan, jog).score),
      );
      expect(
        matcher.score(plan, named).reasons.first,
        contains('workout name'),
      );
    });

    test('look-alike sessions on different days are ambiguous', () {
      final result = matcher.assign(
        planned: [planned(1, 1, easyRun(40)), planned(2, 3, easyRun(40))],
        activities: [activity(10, 2, easyParts(40))],
      );
      expect(result.results.single.confidence, MatchConfidence.medium);
      expect(result.alternatives[10]!.map((r) => r.plannedId).toSet(), {1, 2});
    });

    test('a rejected pair is not proposed again', () {
      final result = matcher.assign(
        planned: [planned(1, 1, easyRun(40)), planned(2, 3, easyRun(40))],
        activities: [activity(10, 2, easyParts(40))],
        excluded: {(10, 1), (10, 2)},
      );
      expect(result.results, isEmpty);
      expect(result.unplannedActivityIds, [10]);
    });

    test('a run that is nothing like the plan is unplanned', () {
      final result = matcher.assign(
        planned: [planned(1, 0, easyRun(40))],
        activities: [activity(10, 6, easyParts(8))],
      );
      expect(result.unplannedActivityIds, [10]);
    });

    test('empty inputs', () {
      final result = matcher.assign(planned: const [], activities: const []);
      expect(result.results, isEmpty);
    });
  });
}
