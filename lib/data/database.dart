import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

enum ActivitySource { garmin, fitFile, manual }

enum FitnessSource { race, timeTrial, halfCooper, lthrTest, detected, manual }

enum WorkoutKind {
  easy,
  recovery,
  long,
  threshold,
  interval,
  repetition,
  marathonPace,
  test,
  strength,
  combined,
}

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
  IntColumn get goalId => integer().nullable().references(Goals, #id)();
  DateTimeColumn get date => dateTime()();
  TextColumn get kind => textEnum<WorkoutKind>()();
  TextColumn get title => text()();

  /// Structured steps (workout DSL) as JSON.
  TextColumn get stepsJson => text().withDefault(const Constant('[]'))();

  /// Strength focus areas (JSON list) for strength/combined sessions.
  TextColumn get focusAreasJson => text().nullable()();
  TextColumn get status =>
      textEnum<WorkoutStatus>().withDefault(Constant(WorkoutStatus.planned.name))();
  TextColumn get garminWorkoutId => text().nullable()();
  TextColumn get garminScheduleId => text().nullable()();
  IntColumn get activityId => integer().nullable().references(Activities, #id)();
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
  PlannedWorkouts,
  KeyValues,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'formforge'));

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) await m.createTable(activityStreams);
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

  Stream<List<Activity>> watchActivities() => (select(activities)
        ..orderBy([(t) => OrderingTerm.desc(t.startTime)]))
      .watch();

  Stream<List<PlannedWorkout>> watchPlanned(DateTime from, DateTime to) =>
      (select(plannedWorkouts)
            ..where((t) => t.date.isBetweenValues(from, to))
            ..orderBy([(t) => OrderingTerm.asc(t.date)]))
          .watch();
}
