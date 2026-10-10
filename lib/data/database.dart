import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:training_core/training_core.dart' show SessionKind;

export 'package:training_core/training_core.dart' show SessionKind;

part 'database.g.dart';

enum ActivitySource { garmin, fitFile, manual }

enum FitnessSource { race, timeTrial, halfCooper, lthrTest, detected, manual }

enum WorkoutStatus { planned, done, partial, skipped }

class AthleteProfiles extends Table {
  IntColumn get id => integer()();
  IntColumn get birthYear => integer().nullable()();
  TextColumn get sex => text().withDefault(const Constant('male'))();
  RealColumn get restHr => real().nullable()();
  RealColumn get maxHr => real().nullable()();
  RealColumn get lthr => real().nullable()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// A point-in-time estimate of running fitness (from a test, race or detection).
class FitnessSnapshots extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get date => dateTime()();
  TextColumn get source => textEnum<FitnessSource>()();
  RealColumn get distanceM => real().nullable()();
  IntColumn get durationS => integer().nullable()();
  RealColumn get vdot => real().nullable()();
  RealColumn get masMps => real().nullable()();
  RealColumn get lthr => real().nullable()();
  IntColumn get activityId => integer().nullable().references(Activities, #id)();
  TextColumn get notes => text().nullable()();
}

class Activities extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get source => textEnum<ActivitySource>()();
  TextColumn get externalId => text().nullable().unique()();
  DateTimeColumn get startTime => dateTime()();
  TextColumn get sport => text()();
  TextColumn get name => text().nullable()();
  RealColumn get distanceM => real().nullable()();
  IntColumn get durationS => integer()();
  RealColumn get avgHr => real().nullable()();
  RealColumn get maxHr => real().nullable()();
  RealColumn get avgSpeed => real().nullable()();
  TextColumn get fitPath => text().nullable()();
}

/// Per-second streams of an activity, packed little-endian (see
/// `activity_streams.dart`). Missing values: NaN (floats), 0 (HR),
/// 0x7FFFFFFF (positions).
class ActivityStreams extends Table {
  IntColumn get activityId => integer().references(Activities, #id)();
  IntColumn get sampleCount => integer()();

  /// Int32 seconds since start.
  BlobColumn get seconds => blob()();

  /// Float32 m/s.
  BlobColumn get speed => blob().nullable()();

  /// Uint8 bpm.
  BlobColumn get heartRate => blob().nullable()();

  /// Float32 metres since start.
  BlobColumn get distance => blob().nullable()();

  /// Int32 semicircles.
  BlobColumn get latitude => blob().nullable()();
  BlobColumn get longitude => blob().nullable()();

  /// Float32 metres.
  BlobColumn get altitude => blob().nullable()();

  /// Int32 pairs of watch timer stop/start seconds; empty = none, null = unknown.
  BlobColumn get timerStops => blob().nullable()();

  @override
  Set<Column> get primaryKey => {activityId};
}

class Goals extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  RealColumn get distanceM => real()();
  IntColumn get targetTimeS => integer().nullable()();
  DateTimeColumn get raceDate => dateTime().nullable()();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
}

class PlannedWorkouts extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Null for manually added workouts.
  IntColumn get planId => integer().nullable().references(TrainingPlans, #id)();
  IntColumn get goalId => integer().nullable().references(Goals, #id)();
  IntColumn get weekIndex => integer().nullable()();

  /// Local calendar day (midnight); see [startMinute] for an optional time.
  DateTimeColumn get date => dateTime()();
  IntColumn get startMinute => integer().nullable()();
  TextColumn get kind => textEnum<SessionKind>()();
  TextColumn get title => text()();

  /// training_core `Workout.toJson()` (versioned).
  TextColumn get workoutJson => text()();

  /// training_core strength session JSON for strength/combined sessions.
  TextColumn get strengthJson => text().nullable()();
  BoolColumn get isKey => boolean().withDefault(const Constant(false))();
  TextColumn get notes => text().nullable()();
  TextColumn get status =>
      textEnum<WorkoutStatus>().withDefault(Constant(WorkoutStatus.planned.name))();
  TextColumn get garminWorkoutId => text().nullable()();
  TextColumn get garminScheduleId => text().nullable()();

  /// Hash of the workout as last pushed to Garmin, to detect stale pushes.
  TextColumn get garminSyncedHash => text().nullable()();
  DateTimeColumn get garminSyncedAt => dateTime().nullable()();
  IntColumn get activityId => integer().nullable().references(Activities, #id)();

  /// Evaluation of the matched activity against the plan (JSON).
  TextColumn get complianceJson => text().nullable()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

class TrainingPlans extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get goalId => integer().nullable().references(Goals, #id)();
  TextColumn get name => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get startDate => dateTime()();
  DateTimeColumn get endDate => dateTime()();

  /// Serialized training_core `PlanRequest`, to regenerate/adapt the plan.
  TextColumn get requestJson => text()();
  TextColumn get warningsJson => text().withDefault(const Constant('[]'))();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
}

/// Non-secret app settings. Secrets live in secure storage.
class KeyValues extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [
  AthleteProfiles,
  FitnessSnapshots,
  Activities,
  ActivityStreams,
  Goals,
  TrainingPlans,
  PlannedWorkouts,
  KeyValues,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'formforge'));

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) await m.createTable(activityStreams);
          if (from < 3) {
            // No UI could create planned workouts before v3, so recreate.
            await m.deleteTable(plannedWorkouts.actualTableName);
            await m.createTable(trainingPlans);
            await m.createTable(plannedWorkouts);
          }
          if (from < 4) {
            // Tables created above already have the column.
            if (from >= 2) {
              await m.addColumn(activityStreams, activityStreams.timerStops);
              // Sample-based Garmin streams used timer time, which hides
              // pauses; dropping them makes the next sync refetch them.
              await customStatement(
                'DELETE FROM activity_streams WHERE activity_id IN '
                "(SELECT id FROM activities WHERE source = 'garmin' "
                'AND fit_path IS NULL)',
              );
            }
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  Future<String?> getSetting(String key) async =>
      (await (select(keyValues)..where((t) => t.key.equals(key)))
              .getSingleOrNull())
          ?.value;

  Future<void> setSetting(String key, String value) => into(keyValues)
      .insertOnConflictUpdate(KeyValuesCompanion.insert(key: key, value: value));

  Stream<AthleteProfile?> watchProfile() =>
      (select(athleteProfiles)..where((t) => t.id.equals(1)))
          .watchSingleOrNull();

  Future<void> saveProfile(AthleteProfilesCompanion profile) =>
      into(athleteProfiles)
          .insertOnConflictUpdate(profile.copyWith(id: const Value(1)));

  Stream<FitnessSnapshot?> watchLatestFitness() => (select(fitnessSnapshots)
        ..orderBy([(t) => OrderingTerm.desc(t.date)])
        ..limit(1))
      .watchSingleOrNull();

  /// Latest snapshot that can pace workouts (has VDOT or MAS).
  Stream<FitnessSnapshot?> watchLatestPacingFitness() =>
      (select(fitnessSnapshots)
            ..where((t) => t.vdot.isNotNull() | t.masMps.isNotNull())
            ..orderBy([(t) => OrderingTerm.desc(t.date)])
            ..limit(1))
          .watchSingleOrNull();

  Stream<List<Activity>> watchActivities() => (select(activities)
        ..orderBy([(t) => OrderingTerm.desc(t.startTime)]))
      .watch();

  Stream<List<PlannedWorkout>> watchPlanned(DateTime from, DateTime to) =>
      (select(plannedWorkouts)
            ..where((t) => t.date.isBetweenValues(from, to))
            ..orderBy([(t) => OrderingTerm.asc(t.date)]))
          .watch();
}
