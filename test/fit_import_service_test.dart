import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:fit_io/fit_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/activity_streams.dart';
import 'package:formforge/data/database.dart';
import 'package:formforge/features/activities/activity_analysis.dart';
import 'package:formforge/integrations/fit/fit_import_service.dart';

import 'fit_fixtures.dart';

void main() {
  late AppDatabase db;
  late Directory dir;
  late FitImportService service;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dir = await Directory.systemTemp.createTemp('formforge_fit_');
    service = FitImportService(db, storageDir: () async => dir);
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('imports an activity with summary, streams and file copy', () async {
    final bytes = syntheticRunFit();
    final summary = await service.importAll([(name: 'run.fit', bytes: bytes)]);
    expect(summary.failed, isEmpty);
    expect(summary.imported, hasLength(1));

    final a = await db.select(db.activities).getSingle();
    expect(a.source, ActivitySource.fitFile);
    expect(a.externalId, 'fit:1234:${toFitDateTime(runStart)}');
    expect(a.startTime.toUtc(), runStart);
    expect(a.sport, 'running');
    expect(a.name, 'Running');
    expect(a.distanceM, 3600);
    expect(a.durationS, 1200);
    expect(a.avgHr, 143);
    expect(a.maxHr, 147);
    expect(a.avgSpeed, 3.0);
    expect(await File(a.fitPath!).readAsBytes(), bytes);

    final row = await (db.select(
      db.activityStreams,
    )..where((t) => t.activityId.equals(a.id))).getSingle();
    final streams = ActivityStreamData.fromRow(row);
    expect(row.sampleCount, 1201);
    expect(streams.seconds.last, 1200);
    expect(streams.speed!.first, 3.0);
    expect(streams.heartRate!.last, 147);
    expect(streams.distance![100], 300);
    expect(streams.latitude![1], 574000001);
    expect(streams.altitude, isNull);

    final analysis = ActivityAnalysis.compute(a, streams.toSamples(), null);
    expect(analysis.efficiencyFactor, closeTo(180 / 143.5, 0.05));
    expect(analysis.decoupling, closeTo(4.8, 0.3));
    expect(analysis.hrZones, isEmpty);
  });

  test('re-importing the same recording is reported as duplicate', () async {
    final bytes = syntheticRunFit();
    await service.importAll([(name: 'a.fit', bytes: bytes)]);
    final summary = await service.importAll([
      (name: 'a.fit', bytes: bytes),
      (name: 'b.fit', bytes: syntheticRunFit(serialNumber: 99)),
    ]);
    expect(summary.duplicates, ['a.fit']);
    expect(summary.imported, hasLength(1));
    expect(await db.select(db.activities).get(), hasLength(2));
    expect(summary.message, 'Imported 1 · 1 already imported');
  });

  test('skips workout and invalid files with a reason', () async {
    final workout = const FitWorkout(
      name: 'Easy',
      steps: [FitWorkoutStep(duration: FitTimeDuration(Duration(minutes: 30)))],
    ).encode();
    final summary = await service.importAll([
      (name: 'plan.fit', bytes: workout),
      (name: 'notes.txt', bytes: Uint8List.fromList('hello world!'.codeUnits)),
    ]);
    expect(summary.imported, isEmpty);
    expect(summary.failed.map((f) => f.file), ['plan.fit', 'notes.txt']);
    expect(summary.failed[0].reason, 'not an activity file (workout)');
    expect(summary.failed[1].reason, startsWith('not a FIT file'));
    expect(await db.select(db.activities).get(), isEmpty);
    expect(dir.listSync(recursive: true).whereType<File>(), isEmpty);
  });

  test('analysis uses profile zones and hrTSS', () async {
    await service.importAll([(name: 'run.fit', bytes: syntheticRunFit())]);
    final a = await db.select(db.activities).getSingle();
    final streams = ActivityStreamData.fromRow(
      await db.select(db.activityStreams).getSingle(),
    );
    final profile = AthleteProfile(
      id: 1,
      sex: 'male',
      restHr: 50,
      maxHr: 190,
      lthr: 170,
      updatedAt: DateTime(2026),
    );
    final analysis = ActivityAnalysis.compute(a, streams.toSamples(), profile);
    expect(analysis.zoneModel, startsWith('Friel'));
    expect(analysis.hrZones, hasLength(7));
    // 140–147 bpm is below 85 % of LTHR (144.5) for the first half → Z1/Z2.
    expect(
      analysis.hrZones[0].fraction + analysis.hrZones[1].fraction,
      closeTo(1, 0.01),
    );
    expect(analysis.hrTss, inInclusiveRange(10, 25));
  });
}
