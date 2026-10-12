import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/activity_streams.dart';
import 'package:formforge/data/database.dart';
import 'package:formforge/features/adaptation/matching_service.dart';
import 'package:training_core/training_core.dart' hide TrainingPlan;

import '../fit_fixtures.dart';
import 'helpers.dart';

void main() {
  late AppDatabase db;
  late MatchingService matcher;
  final now = DateTime(2026, 10, 10, 12);
  final today = DateTime(2026, 10, 10);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await setFitness(db, 50);
    matcher = MatchingService(db, clock: () => now, lapLoader: (_) async => []);
  });
  tearDown(() => db.close());

  Future<PlannedWorkout> row(int id) => (db.select(
    db.plannedWorkouts,
  )..where((t) => t.id.equals(id))).getSingle();

  Future<List<MatchSuggestion>> suggestions() =>
      db.select(db.matchSuggestions).get();

  Workout easy(int minutes, [String? title]) {
    final w = SessionTemplates.easy(Duration(minutes: minutes));
    return title == null
        ? w
        : Workout(sport: w.sport, title: title, elements: w.elements);
  }

  Future<int> run(DateTime start, int seconds, [double speed = 3.1]) =>
      addActivity(db, start: start, legs: [leg(seconds, speed)]);

  test('a clear match is linked automatically with its score', () async {
    final p = await addPlanned(db, date: today, workout: easy(40));
    final a = await run(DateTime(2026, 10, 10, 7), 2400);

    expect(await matcher.matchAll(), 1);
    final r = await row(p);
    expect(r.activityId, a);
    expect(r.linkSource, LinkSource.auto);
    expect(r.linkScore, greaterThan(ActivityMatcher.highScore));
    expect(await suggestions(), isEmpty);
  });

  test('a long pause does not shrink the run', () async {
    final p = await addPlanned(db, date: today, workout: easy(40));
    // 20 min run, 20 min paused with the watch stopped, 20 min run; the
    // stored duration is timer time like Garmin's.
    final s = streamOf([leg(1200, 3.1), leg(1200, 3.1)]);
    final paused = ActivityStreamData(
      seconds: [for (final t in s.seconds) t > 1200 ? t + 1200 : t],
      speed: s.speed,
      heartRate: s.heartRate,
      distance: s.distance,
      timerStops: const [(1200, 2400)],
    );
    final a = await addActivity(
      db,
      start: DateTime(2026, 10, 10, 7),
      durationS: 2400,
    );
    await db.into(db.activityStreams).insert(paused.toCompanion(a));

    expect(await matcher.matchAll(), 1);
    final r = await row(p);
    expect(r.activityId, a);
    expect(r.linkScore, greaterThan(0.9));
  });

  test('swapped days are linked crosswise', () async {
    final wedEasy = await addPlanned(
      db,
      date: DateTime(2026, 10, 7),
      workout: easy(45),
    );
    final thuLong = await addPlanned(
      db,
      date: DateTime(2026, 10, 8),
      kind: SessionKind.long,
      workout: SessionTemplates.long(const Duration(minutes: 90)),
    );
    final wedRun = await run(DateTime(2026, 10, 7, 7), 5400, 3.0);
    final thuRun = await run(DateTime(2026, 10, 8, 7), 2700);

    expect(await matcher.matchAll(), 2);
    expect((await row(thuLong)).activityId, wedRun);
    expect((await row(wedEasy)).activityId, thuRun);
  });

  test('the Garmin workout id links with the garminWorkout source', () async {
    final p = await addPlanned(
      db,
      date: DateTime(2026, 10, 8),
      workout: easy(40),
    );
    await addPlanned(db, date: DateTime(2026, 10, 6), workout: easy(40));
    await (db.update(db.plannedWorkouts)..where((t) => t.id.equals(p))).write(
      const PlannedWorkoutsCompanion(garminWorkoutId: Value('w-8')),
    );
    final a = await run(DateTime(2026, 10, 7, 7), 2400);
    await (db.update(db.activities)..where((t) => t.id.equals(a))).write(
      const ActivitiesCompanion(garminWorkoutId: Value('w-8')),
    );

    expect(await matcher.matchAll(), 1);
    final r = await row(p);
    expect(r.activityId, a);
    expect(r.linkSource, LinkSource.garminWorkout);
  });

  test('the workout name in the FIT file is read once and identifies', () async {
    final dir = await Directory.systemTemp.createTemp('formforge_match_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/a.fit')
      ..writeAsBytesSync(syntheticRunFit(workoutName: 'Easy B [FF]'));

    await addPlanned(
      db,
      date: DateTime(2026, 10, 6),
      workout: easy(40, 'Easy A'),
    );
    final b = await addPlanned(
      db,
      date: DateTime(2026, 10, 8),
      workout: easy(40, 'Easy B'),
    );
    final a = await addActivity(
      db,
      start: DateTime(2026, 10, 7, 7),
      legs: [leg(2400, 3.1)],
      fitPath: file.path,
    );

    expect(await matcher.matchAll(), 1);
    final r = await row(b);
    expect(r.activityId, a);
    expect(r.linkSource, LinkSource.garminWorkout);
    final activity = await (db.select(
      db.activities,
    )..where((t) => t.id.equals(a))).getSingle();
    expect(activity.workoutName, 'Easy B [FF]');
    expect(activity.workoutChecked, isTrue);
  });

  test('an unreadable FIT file is checked only once', () async {
    var calls = 0;
    matcher = MatchingService(
      db,
      clock: () => now,
      lapLoader: (_) async => [],
      nameLoader: (_) async {
        calls++;
        return null;
      },
    );
    await addPlanned(db, date: today, workout: easy(40));
    await addActivity(
      db,
      start: DateTime(2026, 10, 10, 7),
      legs: [leg(1000, 3.1)],
      fitPath: 'missing.fit',
    );
    await matcher.matchAll();
    await matcher.matchAll();
    expect(calls, 1);
  });

  group('ambiguous matches', () {
    late int p1, p2, a;

    setUp(() async {
      p1 = await addPlanned(db, date: today, workout: easy(40));
      p2 = await addPlanned(db, date: today, workout: easy(40));
      a = await run(DateTime(2026, 10, 10, 7), 2400);
    });

    test('become suggestions and are refreshed, not duplicated', () async {
      expect(await matcher.matchAll(), 0);
      expect(await matcher.matchAll(), 0);
      final s = await suggestions();
      expect({for (final x in s) (x.activityId, x.plannedId)}, {
        (a, p1),
        (a, p2),
      });
      expect(s.every((x) => !x.dismissed && x.reasonsJson != '[]'), isTrue);
      expect((await row(p1)).activityId, isNull);
    });

    test('accepting links manually and clears the other proposals', () async {
      await matcher.matchAll();
      await matcher.acceptSuggestion(a, p2);
      final r = await row(p2);
      expect(r.activityId, a);
      expect(r.linkSource, LinkSource.manual);
      expect(r.status, WorkoutStatus.done);
      expect(r.complianceJson, isNotNull);
      expect(await suggestions(), isEmpty);
      expect(await matcher.matchAll(), 0);
      expect((await row(p1)).activityId, isNull);
    });

    test('dismissing keeps them from coming back', () async {
      await matcher.matchAll();
      await matcher.dismissSuggestions(a);
      expect(await matcher.matchAll(), 0);
      expect((await suggestions()).every((s) => s.dismissed), isTrue);
      expect((await row(p1)).activityId, isNull);
      expect((await row(p2)).activityId, isNull);
    });

    test('a rejected candidate is not proposed again', () async {
      await matcher.matchAll();
      await matcher.rejectSuggestion(a, p1);
      // The remaining candidate is unambiguous now.
      expect(await matcher.matchAll(), 1);
      expect((await row(p2)).activityId, a);
      expect((await row(p1)).activityId, isNull);
    });
  });

  group('manual control', () {
    test('unlink resets the workout and is not re-linked', () async {
      final p = await addPlanned(db, date: today, workout: easy(40));
      final a = await run(DateTime(2026, 10, 10, 7), 2400);
      await matcher.matchAll();
      expect((await row(p)).complianceJson, isNotNull);

      await matcher.unlink(p);
      final r = await row(p);
      expect(r.activityId, isNull);
      expect(r.status, WorkoutStatus.planned);
      expect(r.complianceJson, isNull);
      expect(r.linkSource, isNull);
      expect(r.linkScore, isNull);

      expect(await matcher.matchAll(), 0);
      expect((await row(p)).activityId, isNull);
      expect(a, isPositive);
    });

    test('a manual link is never overridden by the matcher', () async {
      final early = await addPlanned(
        db,
        date: DateTime(2026, 10, 8),
        workout: easy(40),
      );
      final same = await addPlanned(
        db,
        date: DateTime(2026, 10, 9),
        workout: easy(40),
      );
      final a = await run(DateTime(2026, 10, 9, 7), 2400);

      await matcher.link(a, early);
      expect(await matcher.matchAll(), 0);
      expect((await row(early)).activityId, a);
      expect((await row(early)).linkSource, LinkSource.manual);
      expect((await row(same)).activityId, isNull);
    });

    test('linking elsewhere frees the previous workout for good', () async {
      final p1 = await addPlanned(db, date: today, workout: easy(40));
      final p2 = await addPlanned(
        db,
        date: DateTime(2026, 10, 9),
        workout: easy(40),
      );
      final a = await run(DateTime(2026, 10, 10, 7), 2400);
      await matcher.matchAll();
      expect((await row(p1)).activityId, a);

      await matcher.link(a, p2);
      expect((await row(p1)).activityId, isNull);
      expect((await row(p1)).status, WorkoutStatus.planned);
      expect((await row(p2)).activityId, a);
      expect(await matcher.matchAll(), 0);
      expect((await row(p1)).activityId, isNull);
    });

    test('marking unplanned unlinks and stops all matching', () async {
      final p = await addPlanned(db, date: today, workout: easy(40));
      final a = await run(DateTime(2026, 10, 10, 7), 2400);
      await matcher.matchAll();
      expect((await row(p)).activityId, a);

      await matcher.markUnplanned(a);
      expect((await row(p)).activityId, isNull);
      expect((await row(p)).status, WorkoutStatus.planned);
      expect(await matcher.matchAll(), 0);
      expect((await row(p)).activityId, isNull);
      expect((await suggestions()).where((s) => !s.dismissed), isEmpty);
      final activity = await (db.select(
        db.activities,
      )..where((t) => t.id.equals(a))).getSingle();
      expect(activity.unplanned, isTrue);

      await matcher.link(a, p);
      expect((await row(p)).activityId, a);
      final again = await (db.select(
        db.activities,
      )..where((t) => t.id.equals(a))).getSingle();
      expect(again.unplanned, isFalse);
    });

    test('the planned workout can follow the activity to its day', () async {
      final p = await addPlanned(
        db,
        date: DateTime(2026, 10, 8),
        workout: easy(40),
      );
      final a = await run(DateTime(2026, 10, 9, 7), 2400);
      expect(await matcher.moveToActivityDay(p), isFalse);

      await matcher.link(a, p);
      expect(await matcher.moveToActivityDay(p), isTrue);
      expect((await row(p)).date, DateTime(2026, 10, 9));
      expect(await matcher.moveToActivityDay(p), isFalse);
    });

    test('link options rank nearby workouts by fit', () async {
      final good = await addPlanned(
        db,
        date: DateTime(2026, 10, 9),
        workout: easy(40),
      );
      final far = await addPlanned(
        db,
        date: DateTime(2026, 10, 5),
        workout: easy(90),
      );
      final a = await run(DateTime(2026, 10, 9, 7), 2400);
      final options = await matcher.linkOptions(a);
      expect(options.map((o) => o.planned.id), [good, far]);
      expect(options.first.score, greaterThan(options.last.score));
      expect(options.first.reasons, contains('Same day'));
    });
  });

  test('a workout of today only matches a run of today', () async {
    final p = await addPlanned(db, date: today, workout: easy(40));
    await run(DateTime(2026, 10, 9, 7), 2400);
    expect(await matcher.matchAll(), 0);
    expect((await row(p)).activityId, isNull);
    expect(await suggestions(), isEmpty);
  });
}
