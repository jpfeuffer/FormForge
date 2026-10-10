import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/database.dart';
import 'package:formforge/features/adaptation/matching_service.dart';
import 'package:formforge/integrations/fit/fit_import_service.dart';
import 'package:formforge/integrations/garmin/garmin_auth.dart';
import 'package:formforge/integrations/garmin/garmin_client.dart';
import 'package:formforge/integrations/garmin/garmin_models.dart';
import 'package:formforge/integrations/garmin/garmin_sync_service.dart';
import 'package:formforge/integrations/garmin/garmin_tokens.dart';
import 'package:training_core/training_core.dart' hide TrainingPlan;

import '../fit_fixtures.dart';
import 'helpers.dart';

void main() {
  late AppDatabase db;
  late Directory dir;
  late FitImportService fitImport;
  late GarminSyncService sync;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dir = await Directory.systemTemp.createTemp('formforge_merge_');
    final matcher = MatchingService(
      db,
      clock: () => DateTime(2026, 10, 1),
      lapLoader: (_) async => [],
    );
    fitImport = FitImportService(
      db,
      storageDir: () async => dir,
      matcher: matcher,
    );
    sync = GarminSyncService(
      db,
      GarminClient(store: InMemoryGarminTokenStore(), auth: GarminAuth()),
      matcher: matcher,
      storageDir: () async => dir,
    );
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  GarminActivitySummary garmin({
    int id = 7,
    Duration offset = const Duration(seconds: 90),
    String type = 'running',
  }) => GarminActivitySummary(
    activityId: id,
    typeKey: type,
    startTime: runStart.add(offset),
    durationS: 1200,
    distanceM: 3600,
    avgHr: 143,
    maxHr: 147,
    avgSpeed: 3,
  );

  Future<List<Activity>> activities() => db.select(db.activities).get();

  Future<ActivityStream?> streamsOf(int id) => (db.select(
    db.activityStreams,
  )..where((t) => t.activityId.equals(id))).getSingleOrNull();

  test('a Garmin activity absorbs the FIT import of the same run', () async {
    final bytes = syntheticRunFit();
    final summary = await fitImport.importAll([
      (name: 'run.fit', bytes: bytes),
    ]);
    final fitId = summary.imported.single;
    final fitPath = (await activities()).single.fitPath!;

    await db
        .into(db.fitnessSnapshots)
        .insert(
          FitnessSnapshotsCompanion.insert(
            date: runStart,
            source: FitnessSource.race,
            vdot: const Value(50),
            activityId: Value(fitId),
          ),
        );
    final plannedId = await addPlanned(
      db,
      date: dayOf(runStart),
      workout: SessionTemplates.easy(const Duration(minutes: 20)),
      status: WorkoutStatus.done,
    );
    await (db.update(db.plannedWorkouts)..where((t) => t.id.equals(plannedId)))
        .write(PlannedWorkoutsCompanion(activityId: Value(fitId)));

    expect(await sync.upsert([garmin()]), 1);

    final rows = await activities();
    expect(rows, hasLength(1));
    final a = rows.single;
    expect(a.source, ActivitySource.garmin);
    expect(a.externalId, '7');
    expect(a.id, isNot(fitId));
    expect(a.fitPath, fitPath);
    expect(await File(fitPath).exists(), isTrue);
    expect((await streamsOf(a.id))!.sampleCount, 1201);
    expect((await db.select(db.fitnessSnapshots).getSingle()).activityId, a.id);
    expect((await db.select(db.plannedWorkouts).getSingle()).activityId, a.id);
  });

  test(
    'different sport or start more than two minutes apart stay apart',
    () async {
      await fitImport.importAll([(name: 'run.fit', bytes: syntheticRunFit())]);
      await sync.upsert([garmin(id: 8, type: 'cycling')]);
      await sync.upsert([garmin(id: 9, offset: const Duration(minutes: 3))]);
      expect(await activities(), hasLength(3));
    },
  );

  test('a FIT import of a synced run enriches the Garmin row', () async {
    await sync.upsert([garmin()]);
    final garminId = (await activities()).single.id;
    expect(await streamsOf(garminId), isNull);

    final bytes = syntheticRunFit();
    final summary = await fitImport.importAll([
      (name: 'run.fit', bytes: bytes),
    ]);
    expect(summary.imported, [garminId]);

    final a = (await activities()).single;
    expect(a.source, ActivitySource.garmin);
    expect(await File(a.fitPath!).readAsBytes(), bytes);
    expect((await streamsOf(garminId))!.sampleCount, 1201);

    final again = await fitImport.importAll([(name: 'run.fit', bytes: bytes)]);
    expect(again.duplicates, ['run.fit']);
    expect(await activities(), hasLength(1));
    expect(dir.listSync(recursive: true).whereType<File>(), hasLength(1));
  });

  test('importing a FIT file links it to the planned session', () async {
    await setFitness(db, 50);
    final plannedId = await addPlanned(
      db,
      date: dayOf(runStart),
      workout: SessionTemplates.easy(const Duration(minutes: 20)),
    );
    final summary = await fitImport.importAll([
      (name: 'run.fit', bytes: syntheticRunFit()),
    ]);
    final p = await (db.select(
      db.plannedWorkouts,
    )..where((t) => t.id.equals(plannedId))).getSingle();
    expect(p.activityId, summary.imported.single);
    expect(p.status, WorkoutStatus.done);
    expect(p.complianceJson, isNotNull);
  });
}
