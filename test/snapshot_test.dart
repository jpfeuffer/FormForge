import 'dart:io';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/database.dart';
import 'package:formforge/data/file_sync.dart';
import 'package:formforge/data/snapshot.dart';

void main() {
  late AppDatabase db;
  late Directory directory;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    directory = await Directory.systemTemp.createTemp(
      'formforge-snapshot-test-',
    );
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test('revision decisions do not overwrite independent changes', () {
    expect(snapshotAction('a', 'a', null), SnapshotAction.unchanged);
    expect(snapshotAction('b', 'a', 'a'), SnapshotAction.upload);
    expect(snapshotAction('a', 'b', 'a'), SnapshotAction.restore);
    expect(snapshotAction('b', 'c', 'a'), SnapshotAction.conflict);
    expect(snapshotAction('b', 'c', null), SnapshotAction.conflict);
  });

  test(
    'connection baseline survives restart without false conflicts',
    () async {
      final sync = FileSync(db, directory);
      await db.setSetting('value', 'saved');
      await sync.connect(
        '${directory.path}${Platform.pathSeparator}shared.formforge',
        create: true,
      );
      final restarted = FileSync(db, directory);
      await restarted.load();
      expect(restarted.target, sync.target);
      expect(restarted.baseline, sync.baseline);
      expect(
        await restarted.sync((_) async => fail('Unexpected conflict')),
        'Already up to date',
      );
    },
  );

  test('compression materially reduces repetitive recordings', () async {
    final id = await db
        .into(db.activities)
        .insert(
          ActivitiesCompanion.insert(
            source: ActivitySource.manual,
            startTime: DateTime(2026),
            sport: 'running',
            durationS: 3600,
          ),
        );
    await db
        .into(db.activityStreams)
        .insert(
          ActivityStreamsCompanion.insert(
            activityId: Value(id),
            sampleCount: 3600,
            seconds: Uint8List(3600 * 4),
            speed: Value(Uint8List(3600 * 4)),
            heartRate: Value(Uint8List.fromList(List.filled(3600, 150))),
          ),
        );
    final snapshot = await Snapshot.capture(db);
    expect(
      snapshot.encode().length,
      lessThan(utf8.encode(jsonEncode(snapshot.payload)).length ~/ 4),
    );
    expect(
      (await Snapshot.decode(snapshot.encode())).revision,
      snapshot.revision,
    );
  });

  test(
    'compressed round trip preserves blobs, references and remaps FIT paths',
    () async {
      final fit = File(
        '${directory.path}${Platform.pathSeparator}original.fit',
      );
      await fit.writeAsBytes([1, 2, 3, 4]);
      final id = await db
          .into(db.activities)
          .insert(
            ActivitiesCompanion.insert(
              source: ActivitySource.fitFile,
              startTime: DateTime(2026),
              sport: 'running',
              durationS: 60,
              fitPath: Value(fit.path),
            ),
          );
      await db
          .into(db.activityStreams)
          .insert(
            ActivityStreamsCompanion.insert(
              activityId: Value(id),
              sampleCount: 1,
              seconds: Uint8List.fromList([0, 0, 0, 0]),
            ),
          );
      await db.setSetting('llm.model', 'test');
      final original = await Snapshot.capture(db);
      final decoded = await Snapshot.decode(original.encode());
      await decoded.validate();
      await decoded.apply(
        db,
        Directory('${directory.path}${Platform.pathSeparator}restored'),
      );
      final row = await db.select(db.activities).getSingle();
      expect(row.fitPath, isNot(fit.path));
      expect(await File(row.fitPath!).readAsBytes(), [1, 2, 3, 4]);
      expect((await db.select(db.activityStreams).getSingle()).seconds, [
        0,
        0,
        0,
        0,
      ]);
      expect((await Snapshot.capture(db)).revision, original.revision);
    },
  );

  test('invalid references roll back replacement', () async {
    await db.setSetting('keep', 'safe');
    final snapshot = await Snapshot.capture(db);
    final tables = snapshot.payload['tables']! as Map<String, Object?>;
    tables['activity_streams'] = [
      {
        'activity_id': 999,
        'sample_count': 1,
        'seconds': {'blob': 'AAAAAA=='},
        'speed': null,
        'heart_rate': null,
        'distance': null,
        'latitude': null,
        'longitude': null,
        'altitude': null,
        'timer_stops': null,
      },
    ];
    await expectLater(snapshot.apply(db, null), throwsFormatException);
    expect(await db.getSetting('keep'), 'safe');
  });

  test('missing FIT originals fail visibly', () async {
    await db
        .into(db.activities)
        .insert(
          ActivitiesCompanion.insert(
            source: ActivitySource.fitFile,
            startTime: DateTime(2026),
            sport: 'running',
            durationS: 60,
            fitPath: Value(
              '${directory.path}${Platform.pathSeparator}missing.fit',
            ),
          ),
        );
    await expectLater(
      Snapshot.capture(db),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'one-button upload, restore and conflict cancellation with recovery',
    () async {
      final shared =
          '${directory.path}${Platform.pathSeparator}shared.formforge';
      final sync = FileSync(db, directory);
      await db.setSetting('value', 'first');
      await sync.connect(shared, create: true);
      await db.setSetting('value', 'second');
      expect(
        await sync.sync((_) async => fail('Unexpected restore')),
        startsWith('Shared file updated'),
      );
      final baseline = sync.baseline;
      await db.setSetting('value', 'remote');
      await File(shared).writeAsBytes((await Snapshot.capture(db)).encode());
      await db.setSetting('value', 'second');
      expect(
        await sync.sync((action) async {
          expect(action, SnapshotAction.restore);
          return SnapshotAction.restore;
        }),
        startsWith('Backup restored'),
      );
      expect(await db.getSetting('value'), 'remote');
      expect(sync.baseline, isNot(baseline));
      await db.setSetting('value', 'other');
      await File(shared).writeAsBytes((await Snapshot.capture(db)).encode());
      await db.setSetting('value', 'local');
      expect(
        await sync.sync((action) async {
          expect(action, SnapshotAction.conflict);
          return null;
        }),
        startsWith('Cancelled'),
      );
      expect(await db.getSetting('value'), 'local');
      expect(
        await Directory('${directory.path}${Platform.pathSeparator}recovery')
            .list()
            .length,
        greaterThanOrEqualTo(3),
      );
    },
  );

  test('local edits during restore confirmation are not lost', () async {
    final shared = '${directory.path}${Platform.pathSeparator}shared.formforge';
    final sync = FileSync(db, directory);
    await db.setSetting('value', 'base');
    await sync.connect(shared, create: true);
    await db.setSetting('value', 'remote');
    await File(shared).writeAsBytes((await Snapshot.capture(db)).encode());
    await db.setSetting('value', 'base');
    await expectLater(
      sync.sync((_) async {
        await db.setSetting('value', 'concurrent');
        return SnapshotAction.restore;
      }),
      throwsStateError,
    );
    expect(await db.getSetting('value'), 'concurrent');
  });

  test('remote edits during confirmation are not overwritten', () async {
    final shared = '${directory.path}${Platform.pathSeparator}shared.formforge';
    final sync = FileSync(db, directory);
    await db.setSetting('value', 'base');
    await sync.connect(shared, create: true);
    await db.setSetting('value', 'remote');
    await File(shared).writeAsBytes((await Snapshot.capture(db)).encode());
    await db.setSetting('value', 'local');
    await expectLater(
      sync.sync((_) async {
        await db.setSetting('value', 'new-remote');
        await File(shared).writeAsBytes((await Snapshot.capture(db)).encode());
        await db.setSetting('value', 'local');
        return SnapshotAction.upload;
      }),
      throwsStateError,
    );
    expect(await db.getSetting('value'), 'local');
    final remote = await Snapshot.decode(await File(shared).readAsBytes());
    expect(jsonEncode(remote.payload), contains('new-remote'));
  });

  test('recovery remains usable and requires confirmation', () async {
    final sync = FileSync(db, directory);
    await db.setSetting('value', 'saved');
    final file = await sync.recovery(await Snapshot.capture(db));
    await db.setSetting('value', 'current');
    expect(
      await sync.restoreRecovery(file, () async => false),
      startsWith('Cancelled'),
    );
    expect(await db.getSetting('value'), 'current');
    expect(
      await sync.restoreRecovery(file, () async => true),
      startsWith('Backup restored'),
    );
    expect(await db.getSetting('value'), 'saved');
    expect((await sync.recoveryFiles()).length, 2);
  });

  test(
    'invalid format and blob lengths are rejected before replacement',
    () async {
      await expectLater(
        Snapshot.decode(gzip.encode(utf8.encode('{"format":999}'))),
        throwsFormatException,
      );
      final snapshot = await Snapshot.capture(db);
      final tables = snapshot.payload['tables']! as Map<String, Object?>;
      tables['activity_streams'] = [
        {
          'activity_id': 1,
          'sample_count': 2,
          'seconds': {'blob': 'AAAAAA=='},
          'speed': null,
          'heart_rate': null,
          'distance': null,
          'latitude': null,
          'longitude': null,
          'altitude': null,
          'timer_stops': null,
        },
      ];
      await db
          .into(db.activities)
          .insert(
            ActivitiesCompanion.insert(
              source: ActivitySource.manual,
              startTime: DateTime(2026),
              sport: 'running',
              durationS: 60,
            ),
          );
      final withActivity = await Snapshot.capture(db);
      tables['activities'] =
          (withActivity.payload['tables']! as Map)['activities'];
      await expectLater(snapshot.validate(), throwsFormatException);
      expect((await db.select(db.activities).get()).length, 1);
    },
  );
}
