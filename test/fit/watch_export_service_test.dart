import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fit_io/fit_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/database.dart';
import 'package:formforge/integrations/fit/watch_export_service.dart';
import 'package:formforge/integrations/fit/workout_fit_export.dart';
import 'package:training_core/training_core.dart';

import '../garmin/workout_fixtures.dart';

Directory _sub(Directory d, [String? a, String? b]) =>
    Directory([d.path, ?a, ?b].join(Platform.pathSeparator));

void main() {
  late AppDatabase db;
  late Directory tmp;

  final now = DateTime(2026, 10, 10, 9);
  DateTime day(int offset) => DateTime(2026, 10, 10 + offset);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('ff_watch_');
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<void> addRow(
    DateTime date, {
    Workout? workout,
    WorkoutStatus status = WorkoutStatus.planned,
    String? json,
  }) async {
    final w = workout ?? easyRun();
    await db
        .into(db.plannedWorkouts)
        .insert(
          PlannedWorkoutsCompanion.insert(
            date: date,
            kind: SessionKind.easy,
            title: w.title,
            workoutJson: json ?? workoutJsonString(w),
            status: Value(status),
          ),
        );
  }

  WatchExportService service({
    List<Directory> volumes = const [],
    Future<String?> Function()? pickFolder,
  }) => WatchExportService(
    db,
    paceProfile: testProfile,
    usb: WatchUsbExporter(volumes: () => volumes),
    pickFolder: pickFolder,
    clock: () => now,
  );

  group('WatchUsbExporter', () {
    Directory volume(String name, [List<String> sub = const []]) {
      final dir = _sub(tmp, name)..createSync();
      var path = dir;
      for (final s in sub) {
        path = _sub(path, s);
      }
      path.createSync(recursive: true);
      return dir;
    }

    test('finds only volumes with GARMIN/NewFiles, ignoring case', () {
      final watch = volume('watch', ['Garmin', 'newfiles']);
      final noNewFiles = volume('partial', ['GARMIN', 'Activity']);
      final other = volume('usbstick');
      final missing = _sub(tmp, 'gone');

      final found = WatchUsbExporter(
        volumes: () => [other, noNewFiles, missing, watch],
      ).findNewFilesDirs();

      expect(
        [for (final d in found) d.path],
        [_sub(_sub(watch, 'Garmin'), 'newfiles').path],
      );
    });

    test('copies files into the target', () async {
      final target = _sub(
        volume('watch', ['GARMIN', 'NewFiles']),
        'GARMIN',
        'NewFiles',
      );

      final count = await WatchUsbExporter().copyFiles(target, [
        FitWorkoutFile('a.fit', Uint8List.fromList([1, 2, 3])),
        FitWorkoutFile('b.fit', Uint8List.fromList([4])),
      ]);

      expect(count, 2);
      expect(File(_sub(target, 'a.fit').path).readAsBytesSync(), [1, 2, 3]);
      expect(File(_sub(target, 'b.fit').path).readAsBytesSync(), [4]);
    });
  });

  group('WatchExportService', () {
    test('reports when there is nothing to export', () async {
      await addRow(day(-1));
      await addRow(day(1), status: WorkoutStatus.skipped);
      await addRow(day(30));

      final result = await service().exportFitForRange(day(-3), day(14));

      expect(result, isA<ExportNothing>());
    });

    test('copies into a mounted watch without asking for a folder', () async {
      final newFiles = _sub(tmp, 'GARMIN', 'NewFiles')
        ..createSync(recursive: true);
      await addRow(day(1));

      final result = await service(
        volumes: [tmp],
        pickFolder: () async => fail('must not ask'),
      ).exportFitForRange(day(0), day(14));

      expect(result, isA<ExportedToWatch>());
      expect((result as ExportedToWatch).count, 1);
      final bytes = File(_sub(newFiles, 'FF_20261011_Easy_run.fit').path)
          .readAsBytesSync();
      final fit = FitWorkout.fromFile(
        const FitDecoder(crcCheck: CrcCheck.strict).decode(bytes),
      )!;
      expect(fit.name, 'Easy run');
    });

    test('falls back to a user-chosen folder and numbers duplicates', () async {
      await addRow(day(1));
      await addRow(day(1));
      await addRow(day(2), workout: nestedIntervals());
      await addRow(day(-1));
      await addRow(day(0), status: WorkoutStatus.done);
      final out = _sub(tmp, 'out')..createSync();

      final result = await service(pickFolder: () async => out.path)
          .exportFitForRange(day(-3), day(14));

      expect(result, isA<ExportedToFolder>());
      final folder = result as ExportedToFolder;
      expect((folder.count, folder.directory), (3, out.path));
      expect(folder.instructions, contains('GARMIN/NewFiles'));
      expect(
        out.listSync().map((e) => e.uri.pathSegments.last).toList()..sort(),
        [
          'FF_20261011_Easy_run.fit',
          'FF_20261011_Easy_run_2.fit',
          'FF_20261012_Pyramid_2x_3x400.fit',
        ],
      );
    });

    test('reports a cancelled folder picker', () async {
      await addRow(day(1));

      final result = await service(pickFolder: () async => null)
          .exportFitForRange(day(0), day(14));

      expect(result, isA<ExportCancelled>());
    });

    test('reports corrupt workouts instead of throwing', () async {
      await addRow(day(1), json: '{"v": 99}');

      final result = await service(pickFolder: () async => tmp.path)
          .exportFitForRange(day(0), day(14));

      expect(result, isA<ExportFailed>());
    });
  });
}
