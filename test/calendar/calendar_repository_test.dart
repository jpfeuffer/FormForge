import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/database.dart';
import 'package:formforge/features/calendar/calendar_models.dart';
import 'package:formforge/features/calendar/calendar_repository.dart';
import 'package:formforge/features/calendar/workout_spec.dart';
import 'package:training_core/training_core.dart';

void main() {
  late AppDatabase db;
  late CalendarRepository repo;
  var clock = DateTime(2026, 10, 1, 12);
  final profile = fallbackPaceProfile;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = CalendarRepository(db, now: () => clock);
  });
  tearDown(() => db.close());

  Future<int> seed(
    Workout w, {
    SessionKind kind = SessionKind.easy,
    DateTime? date,
    StrengthSession? strength,
  }) => repo.upsertManual(
    kind: kind,
    date: date ?? DateTime(2026, 10, 6),
    title: w.title,
    workout: w,
    strength: strength,
  );

  Future<PlannedWorkout> row(int id) => repo.get(id).then((r) => r!);

  test(
    'upsertManual inserts a manual workout and updates it in place',
    () async {
      final spec = WorkoutSpec(SessionKind.easy)..runMinutes = 40;
      final w = spec.build(profile);
      final id = await repo.upsertManual(
        kind: SessionKind.easy,
        date: DateTime(2026, 10, 6, 15, 30),
        startMinute: 7 * 60,
        title: w.title,
        workout: w,
        notes: 'flat',
      );
      var r = await row(id);
      expect(r.planId, isNull);
      expect(r.date, DateTime(2026, 10, 6));
      expect(r.startMinute, 420);
      expect(r.updatedAt, clock);
      expect(
        Workout.fromJson(jsonDecode(r.workoutJson) as Map<String, Object?>)
            .title,
        'Easy run',
      );

      clock = clock.add(const Duration(hours: 1));
      spec.runMinutes = 55;
      final w2 = spec.build(profile, title: 'Morning jog');
      await repo.upsertManual(
        id: id,
        kind: SessionKind.easy,
        date: DateTime(2026, 10, 7),
        title: w2.title,
        workout: w2,
      );
      r = await row(id);
      expect(await db.select(db.plannedWorkouts).get(), hasLength(1));
      expect(r.title, 'Morning jog');
      expect(r.startMinute, isNull);
      expect(
        CalendarEntry(r).workout.estimatedDuration(profile),
        const Duration(minutes: 55),
      );
    },
  );

  test(
    'move changes the day and updatedAt but leaves Garmin fields alone',
    () async {
      final id = await seed(plain(SessionKind.easy));
      final synced = DateTime(2026, 10, 2);
      await (db.update(
        db.plannedWorkouts,
      )..where((t) => t.id.equals(id))).write(
        PlannedWorkoutsCompanion(
          garminWorkoutId: const Value('w1'),
          garminScheduleId: const Value('s1'),
          garminSyncedHash: const Value('h'),
          garminSyncedAt: Value(synced),
        ),
      );
      expect(CalendarEntry(await row(id)).garmin, GarminSync.synced);

      clock = DateTime(2026, 10, 3);
      await repo.move(id, DateTime(2026, 10, 9, 18));
      final r = await row(id);
      expect(r.date, DateTime(2026, 10, 9));
      expect(r.updatedAt, clock);
      expect(
        [
          r.garminWorkoutId,
          r.garminScheduleId,
          r.garminSyncedHash,
          r.garminSyncedAt,
        ],
        ['w1', 's1', 'h', synced],
      );
      expect(CalendarEntry(r).garmin, GarminSync.changed);
    },
  );

  test('duplicate copies content without sync state or status', () async {
    final id = await seed(plain(SessionKind.easy));
    await repo.setStatus(id, WorkoutStatus.done);
    final copy = await repo.duplicate(id, DateTime(2026, 10, 13));
    final r = await row(copy);
    expect(copy, isNot(id));
    expect(r.date, DateTime(2026, 10, 13));
    expect(r.status, WorkoutStatus.planned);
    expect(r.garminScheduleId, isNull);
    expect(r.workoutJson, (await row(id)).workoutJson);
  });

  test('setStatus and delete', () async {
    final id = await seed(plain(SessionKind.easy));
    await repo.setStatus(id, WorkoutStatus.skipped);
    expect((await row(id)).status, WorkoutStatus.skipped);
    await repo.delete(id);
    expect(await repo.get(id), isNull);
  });

  test('watchRange only returns workouts in the range', () async {
    await seed(plain(SessionKind.easy), date: DateTime(2026, 10, 5));
    await seed(plain(SessionKind.easy), date: DateTime(2026, 10, 11));
    await seed(plain(SessionKind.easy), date: DateTime(2026, 10, 12));
    final rows = await repo
        .watchRange(DateTime(2026, 10, 5), DateTime(2026, 10, 11))
        .first;
    expect(rows, hasLength(2));
  });

  group('strength block', () {
    final session = StrengthSession(
      focusAreas: const [FocusArea.core, FocusArea.upperPull],
      duration: const Duration(minutes: 20),
      rpe: 5,
    );

    test('is inserted in the middle of a run and removed again', () async {
      final run = plain(SessionKind.recovery, minutes: 60);
      final id = await seed(run, kind: SessionKind.recovery);

      await repo.addStrengthBlock(
        id,
        session,
        StrengthPlacement.during,
        profile,
      );
      var r = await row(id);
      var e = CalendarEntry(r);
      expect(r.kind, SessionKind.combined);
      expect(e.workout.sport, Sport.combined);
      expect(
        [for (final s in e.workout.steps) s.kind],
        [StepKind.active, StepKind.strength, StepKind.active],
      );
      expect(
        e.workout.estimatedRunDuration(profile),
        const Duration(minutes: 60),
      );
      expect(e.strength?.focusAreas, session.focusAreas);
      expect(e.focusAreas, contains(FocusArea.core));

      await repo.removeStrengthBlock(id);
      r = await row(id);
      e = CalendarEntry(r);
      expect(r.kind, SessionKind.recovery);
      expect(r.strengthJson, isNull);
      expect(e.workout.sport, Sport.run);
      expect(e.workout.steps, hasLength(1));
      expect(e.workout.estimatedDuration(profile), const Duration(minutes: 60));
      expect(r.title, 'Recovery run');
    });

    test('a long run keeps its kind', () async {
      final id = await seed(plain(SessionKind.long), kind: SessionKind.long);
      await repo.addStrengthBlock(
        id,
        session,
        StrengthPlacement.after,
        profile,
      );
      final r = await row(id);
      expect(r.kind, SessionKind.long);
      expect(CalendarEntry(r).workout.steps.last.kind, StepKind.strength);
    });

    test('rejects workouts that are not plain runs', () async {
      final id = await seed(
        session.toWorkout(),
        kind: SessionKind.strength,
        strength: session,
      );
      expect(
        () => repo.addStrengthBlock(
          id,
          session,
          StrengthPlacement.before,
          profile,
        ),
        throwsStateError,
      );
    });
  });

  group('WorkoutSpec', () {
    test('quality sessions build and parse back', () {
      final s = WorkoutSpec(SessionKind.interval)
        ..reps = 6
        ..repSize = 1000
        ..recoverySeconds = 120;
      final w = s.build(profile);
      expect(w.title, '6 × 1000 m interval');
      expect(w.steps.where((x) => x.kind == StepKind.active), hasLength(6));

      final parsed = WorkoutSpec.tryParse(SessionKind.interval, w, null)!;
      expect(
        (
          parsed.reps,
          parsed.byDistance,
          parsed.repSize,
          parsed.recoverySeconds,
        ),
        (6, true, 1000, 120),
      );
      expect(parsed.build(profile).toJson(), w.toJson());
    });

    test('combined sessions parse placement and run length', () {
      final s = WorkoutSpec(SessionKind.combined)
        ..runMinutes = 50
        ..strength.placement = StrengthPlacement.after;
      final w = s.build(profile);
      final parsed = WorkoutSpec.tryParse(
        SessionKind.combined,
        w,
        s.strengthSession,
      )!;
      expect(parsed.runMinutes, 50);
      expect(parsed.strength.placement, StrengthPlacement.after);
    });

    test('unknown structures are not parsed', () {
      final w = SessionTemplates.easy(
        const Duration(minutes: 40),
        strides: true,
      );
      expect(WorkoutSpec.tryParse(SessionKind.easy, w, null), isNull);
    });
  });

  test('CalendarData previews the issues a move would cause', () async {
    // Mon 2026-10-05: threshold; Wed: long run. Moving the long run to Tue is consecutive.
    final t = await seed(
      plain(SessionKind.threshold),
      kind: SessionKind.threshold,
      date: DateTime(2026, 10, 5),
    );
    final l = await seed(
      plain(SessionKind.long, minutes: 50),
      kind: SessionKind.long,
      date: DateTime(2026, 10, 7),
    );
    final data = CalendarData([await row(t), await row(l)], profile, null);
    expect(data.issues, isEmpty);
    final preview = data.previewMove(l, DateTime(2026, 10, 6));
    expect(preview.map((i) => i.code), contains('consecutive_key_days'));
    expect(data.previewMove(l, DateTime(2026, 10, 9)), isEmpty);
  });
}

Workout plain(SessionKind kind, {int? minutes}) {
  final s = WorkoutSpec(kind);
  if (minutes != null) s.runMinutes = minutes;
  return s.build(fallbackPaceProfile);
}
