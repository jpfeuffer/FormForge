import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/database.dart';
import 'package:formforge/features/adaptation/matching_service.dart';
import 'package:training_core/training_core.dart' hide TrainingPlan;

import 'helpers.dart';

void main() {
  late AppDatabase db;
  late MatchingService matcher;
  final now = DateTime(2026, 10, 10, 12);
  final today = DateTime(2026, 10, 10);
  final profile = PaceProfile.fromVdot(50);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await setFitness(db, 50);
    matcher = MatchingService(db, clock: () => now, lapLoader: (_) async => []);
  });
  tearDown(() => db.close());

  Future<PlannedWorkout> row(int id) => (db.select(
    db.plannedWorkouts,
  )..where((t) => t.id.equals(id))).getSingle();

  SessionCompliance complianceOf(PlannedWorkout p) =>
      SessionCompliance.fromJson(
        (jsonDecode(p.complianceJson!) as Map).cast<String, Object?>(),
      );

  Workout easyRun(int minutes) =>
      SessionTemplates.easy(Duration(minutes: minutes));

  test('links the activity of the same day and evaluates it', () async {
    final p = await addPlanned(db, date: today, workout: easyRun(40));
    final a = await addActivity(
      db,
      start: DateTime(2026, 10, 10, 7),
      legs: [leg(2400, 3.1, 140)],
    );

    expect(await matcher.matchAll(), 1);
    final r = await row(p);
    expect(r.activityId, a);
    expect(r.status, WorkoutStatus.done);
    expect(complianceOf(r).verdict, SessionVerdict.onTarget);
    expect(await matcher.matchAll(), 0);
  });

  test('flags an easy run that was too fast', () async {
    final p = await addPlanned(db, date: today, workout: easyRun(40));
    await addActivity(
      db,
      start: DateTime(2026, 10, 10, 7),
      legs: [leg(2400, 3.9, 160)],
    );
    await matcher.matchAll();
    expect(complianceOf(await row(p)).verdict, SessionVerdict.tooHard);
  });

  test('among several candidates takes the closest duration', () async {
    final long = await addPlanned(
      db,
      date: today,
      kind: SessionKind.long,
      workout: SessionTemplates.long(const Duration(minutes: 90)),
    );
    final easy = await addPlanned(db, date: today, workout: easyRun(30));
    final shortRun = await addActivity(
      db,
      start: DateTime(2026, 10, 10, 6),
      legs: [leg(1920, 3.1)],
    );
    final longRun = await addActivity(
      db,
      start: DateTime(2026, 10, 10, 9),
      legs: [leg(5700, 3.0)],
    );

    expect(await matcher.matchAll(), 2);
    expect((await row(long)).activityId, longRun);
    expect((await row(easy)).activityId, shortRun);
  });

  test('a lone short jog still matches the only planned session', () async {
    final p = await addPlanned(db, date: today, workout: easyRun(40));
    final jog = await addActivity(
      db,
      start: DateTime(2026, 10, 10, 7),
      legs: [leg(1200, 3.1)],
    );
    await matcher.matchAll();
    final r = await row(p);
    expect(r.activityId, jog);
    expect(r.status, WorkoutStatus.partial);
    expect(complianceOf(r).verdict, SessionVerdict.incomplete);
  });

  test('ignores recordings under five minutes and other sports', () async {
    final p = await addPlanned(db, date: today, workout: easyRun(40));
    await addActivity(
      db,
      start: DateTime(2026, 10, 10, 7),
      legs: [leg(200, 3)],
    );
    await addActivity(
      db,
      start: DateTime(2026, 10, 10, 8),
      sport: 'cycling',
      durationS: 3600,
    );
    expect(await matcher.matchAll(), 0);
    expect((await row(p)).activityId, isNull);
  });

  group('day shift', () {
    test('a session of an earlier day matches the next day', () async {
      final p = await addPlanned(
        db,
        date: DateTime(2026, 10, 8),
        workout: easyRun(40),
      );
      final a = await addActivity(
        db,
        start: DateTime(2026, 10, 9, 7),
        legs: [leg(2400, 3.1)],
      );
      await matcher.matchAll();
      expect((await row(p)).activityId, a);
    });

    test('a same-day match wins over a shifted one', () async {
      final p = await addPlanned(
        db,
        date: DateTime(2026, 10, 8),
        workout: easyRun(40),
      );
      await addActivity(
        db,
        start: DateTime(2026, 10, 9, 7),
        legs: [leg(2400, 3.1)],
      );
      final same = await addActivity(
        db,
        start: DateTime(2026, 10, 8, 7),
        legs: [leg(1500, 3.1)],
      );
      await matcher.matchAll();
      expect((await row(p)).activityId, same);
    });

    test("today's session does not grab yesterday's run", () async {
      final p = await addPlanned(db, date: today, workout: easyRun(40));
      await addActivity(
        db,
        start: DateTime(2026, 10, 9, 7),
        legs: [leg(2400, 3.1)],
      );
      await matcher.matchAll();
      expect((await row(p)).activityId, isNull);
    });

    test('sessions older than a week are not shifted', () async {
      final p = await addPlanned(
        db,
        date: DateTime(2026, 10, 1),
        workout: easyRun(40),
      );
      await addActivity(
        db,
        start: DateTime(2026, 10, 2, 7),
        legs: [leg(2400, 3.1)],
      );
      await matcher.matchAll();
      expect((await row(p)).activityId, isNull);
    });
  });

  test('a past session without activity is left as planned', () async {
    final p = await addPlanned(
      db,
      date: DateTime(2026, 10, 7),
      workout: easyRun(40),
    );
    await matcher.matchAll();
    final r = await row(p);
    expect(r.status, WorkoutStatus.planned);
    expect(r.activityId, isNull);
  });

  test('an activity is linked to one session only', () async {
    final a = await addPlanned(db, date: today, workout: easyRun(40));
    final b = await addPlanned(db, date: today, workout: easyRun(40));
    await addActivity(
      db,
      start: DateTime(2026, 10, 10, 7),
      legs: [leg(2400, 3.1)],
    );
    expect(await matcher.matchAll(), 1);
    final linked = [(await row(a)).activityId, (await row(b)).activityId];
    expect(linked.whereType<int>(), hasLength(1));
  });

  test('strength sessions match strength activities only', () async {
    final w = Workout(
      sport: Sport.strength,
      title: 'Core',
      elements: const [
        WorkoutStep(
          kind: StepKind.strength,
          end: LapButtonEnd(),
          estimate: Duration(minutes: 20),
        ),
      ],
    );
    final p = await addPlanned(
      db,
      date: today,
      kind: SessionKind.strength,
      workout: w,
    );
    await addActivity(
      db,
      start: DateTime(2026, 10, 10, 7),
      legs: [leg(1200, 3.1)],
    );
    expect(await matcher.matchAll(), 0);

    final s = await addActivity(
      db,
      start: DateTime(2026, 10, 10, 18),
      sport: 'strength_training',
      durationS: 1300,
    );
    expect(await matcher.matchAll(), 1);
    final r = await row(p);
    expect(r.activityId, s);
    expect(r.status, WorkoutStatus.done);
    expect(r.complianceJson, isNull);
  });

  test('evaluates once streams arrive after the link', () async {
    final p = await addPlanned(db, date: today, workout: easyRun(40));
    final a = await addActivity(
      db,
      start: DateTime(2026, 10, 10, 7),
      durationS: 2400,
    );
    await matcher.matchAll();
    expect((await row(p)).activityId, a);
    expect((await row(p)).complianceJson, isNull);
    expect((await row(p)).status, WorkoutStatus.done);

    await db
        .into(db.activityStreams)
        .insert(streamOf([leg(2400, 3.1)]).toCompanion(a));
    expect(await matcher.matchAll(), 0);
    expect(complianceOf(await row(p)).verdict, SessionVerdict.onTarget);
  });

  group('test workouts', () {
    Future<List<FitnessSnapshot>> snapshots() => (db.select(
      db.fitnessSnapshots,
    )..where((t) => t.source.equalsValue(FitnessSource.manual).not())).get();

    test('a 3k time trial becomes a fitness snapshot', () async {
      final p = await addPlanned(
        db,
        date: today,
        kind: SessionKind.test,
        workout: SessionTemplates.test(TestType.timeTrial3k, profile),
      );
      final a = await addActivity(
        db,
        start: DateTime(2026, 10, 10, 7),
        legs: [leg(900, 3.0, 130), leg(667, 4.5, 178), leg(300, 2.8, 140)],
      );
      await matcher.matchAll();
      expect((await row(p)).activityId, a);

      final s = (await snapshots()).single;
      expect(s.source, FitnessSource.timeTrial);
      expect(s.activityId, a);
      expect(s.distanceM, 3000);
      expect(
        s.vdot,
        closeTo(
          Vdot.fromPerformance(
            const RunPerformance(meters: 3000, time: Duration(seconds: 667)),
          ),
          0.2,
        ),
      );

      await matcher.matchAll();
      expect(await snapshots(), hasLength(1));
    });

    test('a Friel 30 min test updates LTHR and the profile', () async {
      await addPlanned(
        db,
        date: today,
        kind: SessionKind.test,
        workout: SessionTemplates.test(TestType.friel30, profile),
      );
      await addActivity(
        db,
        start: DateTime(2026, 10, 10, 7),
        legs: [
          leg(900, 3.0, 125),
          leg(600, 3.6, 158),
          leg(1200, 3.6, 168),
          leg(300, 2.5, 140),
        ],
      );
      await matcher.matchAll();
      final s = (await snapshots()).single;
      expect(s.source, FitnessSource.lthrTest);
      expect(s.lthr, closeTo(168, 0.5));
      expect((await db.watchProfile().first)!.lthr, closeTo(168, 0.5));
    });

    test('a half-Cooper test gives MAS', () async {
      await addPlanned(
        db,
        date: today,
        kind: SessionKind.test,
        workout: SessionTemplates.test(TestType.halfCooper, profile),
      );
      await addActivity(
        db,
        start: DateTime(2026, 10, 10, 7),
        legs: [leg(900, 3.0, 130), leg(360, 4.8, 185), leg(300, 2.5, 150)],
      );
      await matcher.matchAll();
      final s = (await snapshots()).single;
      expect(s.source, FitnessSource.halfCooper);
      expect(s.masMps, closeTo(4.8, 0.02));
    });
  });
}
