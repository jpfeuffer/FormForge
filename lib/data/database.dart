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
  Goals,
  PlannedWorkouts,
  KeyValues,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'formforge'));

  @override
  int get schemaVersion => 1;

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
