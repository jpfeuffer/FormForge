import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) => raw
          ..execute(
            'CREATE TABLE activities (id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'source TEXT NOT NULL, external_id TEXT NULL UNIQUE, '
            'start_time INTEGER NOT NULL, sport TEXT NOT NULL, name TEXT, '
            'distance_m REAL, duration_s INTEGER NOT NULL, avg_hr REAL, '
            'max_hr REAL, avg_speed REAL, fit_path TEXT)',
          )
          ..execute(
            'CREATE TABLE planned_workouts (id INTEGER PRIMARY KEY '
            'AUTOINCREMENT, plan_id INTEGER, goal_id INTEGER, week_index '
            'INTEGER, date INTEGER NOT NULL, start_minute INTEGER, kind TEXT '
            'NOT NULL, title TEXT NOT NULL, workout_json TEXT NOT NULL, '
            'strength_json TEXT, is_key INTEGER NOT NULL DEFAULT 0, notes '
            "TEXT, status TEXT NOT NULL DEFAULT 'planned', garmin_workout_id "
            'TEXT, garmin_schedule_id TEXT, garmin_synced_hash TEXT, '
            'garmin_synced_at INTEGER, activity_id INTEGER REFERENCES '
            'activities (id), compliance_json TEXT, updated_at INTEGER NOT '
            "NULL DEFAULT (strftime('%s', 'now')))",
          )
          ..execute(
            "INSERT INTO activities VALUES (1, 'garmin', 'g1', 1790000000, "
            "'running', 'Run', 8000, 2400, 140, 160, 3.3, 'a.fit'), "
            "(2, 'garmin', 'g2', 1790100000, 'running', NULL, NULL, 1800, "
            'NULL, NULL, NULL, NULL)',
          )
          ..execute(
            "INSERT INTO planned_workouts (id, date, kind, title, "
            "workout_json, status, garmin_workout_id, activity_id, "
            "compliance_json) VALUES (1, 1790000000, 'easy', 'Easy', '{}', "
            "'done', 'w1', 1, '{\"v\":1}'), (2, 1790200000, 'long', 'Long', "
            "'{}', 'planned', NULL, NULL, NULL)",
          )
          ..execute('PRAGMA user_version = 4'),
      ),
    );
  });
  tearDown(() => db.close());

  test('v4 data survives and links are marked as automatic', () async {
    final activities = await db.select(db.activities).get();
    expect(activities, hasLength(2));
    final a = activities.first;
    expect((a.externalId, a.fitPath, a.distanceM), ('g1', 'a.fit', 8000));
    expect(a.workoutName, isNull);
    expect(a.garminWorkoutId, isNull);
    expect(a.workoutChecked, isFalse);
    expect(a.unplanned, isFalse);

    final planned = await db.select(db.plannedWorkouts).get();
    final linked = planned.firstWhere((p) => p.id == 1);
    expect(linked.activityId, 1);
    expect(linked.status, WorkoutStatus.done);
    expect(linked.complianceJson, '{"v":1}');
    expect(linked.garminWorkoutId, 'w1');
    expect(linked.linkSource, LinkSource.auto);
    expect(linked.linkScore, isNull);
    expect(planned.firstWhere((p) => p.id == 2).linkSource, isNull);
  });

  test('the suggestions table is foreign-key consistent', () async {
    Future<void> suggest(int activityId, int plannedId) => db
        .into(db.matchSuggestions)
        .insert(
          MatchSuggestionsCompanion.insert(
            activityId: activityId,
            plannedId: plannedId,
            score: 0.6,
          ),
        );

    await suggest(2, 2);
    await expectLater(suggest(99, 2), throwsA(anything));
    await expectLater(suggest(2, 99), throwsA(anything));
    await expectLater(suggest(2, 2), throwsA(anything));

    final row = await db.select(db.matchSuggestions).getSingle();
    expect(row.dismissed, isFalse);
    expect(row.reasonsJson, '[]');

    await (db.delete(db.activities)..where((t) => t.id.equals(2))).go();
    expect(await db.select(db.matchSuggestions).get(), isEmpty);
  });
}
