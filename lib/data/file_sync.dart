import 'dart:convert';
import 'dart:io';

import 'database.dart';
import 'snapshot.dart';
import 'snapshot_store.dart';

enum SnapshotAction { unchanged, upload, restore, conflict }

SnapshotAction snapshotAction(String local, String remote, String? baseline) {
  if (local == remote) return SnapshotAction.unchanged;
  if (baseline == null) return SnapshotAction.conflict;
  if (remote == baseline) return SnapshotAction.upload;
  if (local == baseline) return SnapshotAction.restore;
  return SnapshotAction.conflict;
}

class FileSync {
  FileSync(this.db, this.directory, {SnapshotStore? store})
    : store = store ?? FileSnapshotStore();
  final AppDatabase db;
  final Directory directory;
  final SnapshotStore store;
  String? target;
  String? baseline;
  bool busy = false;
  int restoreGeneration = 0;
  DateTime? lastSync;

  Future<void> load() async {
    final state = File(
      '${directory.path}${Platform.pathSeparator}${store.stateFileName}',
    );
    if (!await state.exists()) return;
    final value =
        jsonDecode(await state.readAsString()) as Map<String, dynamic>;
    target = value['target'] as String?;
    baseline = value['baseline'] as String?;
    lastSync = value['lastSync'] == null
        ? null
        : DateTime.parse(value['lastSync'] as String);
  }

  Future<void> save() async {
    await directory.create(recursive: true);
    await File(
      '${directory.path}${Platform.pathSeparator}${store.stateFileName}',
    ).writeAsString(
      jsonEncode({
        'target': target,
        'baseline': baseline,
        'lastSync': lastSync?.toIso8601String(),
      }),
      flush: true,
    );
  }

  Future<File> recovery(Snapshot snapshot) async {
    final dir = Directory('${directory.path}${Platform.pathSeparator}recovery');
    await dir.create(recursive: true);
    final file = File(
      '${dir.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}.formforge',
    );
    await file.writeAsBytes(snapshot.encode(), flush: true);
    return file;
  }

  Future<List<File>> recoveryFiles() async {
    final dir = Directory('${directory.path}${Platform.pathSeparator}recovery');
    if (!await dir.exists()) return [];
    final files = await dir
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.formforge'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  Future<String> restoreRecovery(
    File file,
    Future<bool> Function() confirm,
  ) async {
    if (busy) throw StateError('Another snapshot operation is running');
    busy = true;
    try {
      final local = await Snapshot.capture(db);
      if (await file.length() > snapshotLimit) {
        throw const FormatException('Backup is too large');
      }
      final backup = await Snapshot.decode(await file.readAsBytes());
      await backup.validate();
      if (!await confirm()) return 'Cancelled; no data changed';
      await recovery(local);
      await db.transaction(() async {
        if ((await Snapshot.capture(db)).revision != local.revision) {
          throw StateError('Local data changed during restore. Please retry.');
        }
        await backup.apply(
          db,
          Directory('${directory.path}${Platform.pathSeparator}restored-fit'),
        );
      });
      restoreGeneration++;
      baseline = null;
      lastSync = null;
      await save();
      return 'Backup restored. Sync will ask which snapshot to keep.';
    } finally {
      busy = false;
    }
  }

  Future<void> connect(String path, {required bool create}) async {
    if (create) {
      final local = await Snapshot.capture(db);
      await recovery(local);
      await store.write(path, local, null);
      final check = await store.read(path);
      if (check?.snapshot.revision != local.revision) {
        throw StateError('Backup write verification failed');
      }
      baseline = local.revision;
      lastSync = DateTime.now();
    } else {
      final remote = await store.read(path);
      if (remote == null) throw StateError('No backup found');
      await remote.snapshot.validate();
      baseline = null;
      lastSync = null;
    }
    target = path;
    await save();
  }

  Future<String> sync(
    Future<SnapshotAction?> Function(SnapshotAction action) choose,
  ) async {
    if (busy) throw StateError('Another snapshot operation is running');
    final path = target;
    if (path == null) throw StateError('Choose a shared file first');
    busy = true;
    try {
      final local = await Snapshot.capture(db);
      final remote = await store.read(path);
      if (remote != null) await remote.snapshot.validate();
      if (remote == null && baseline != null) {
        throw StateError(
          'The previous cloud backup is missing. Use Reset Google backup connection to explicitly start a new backup history.',
        );
      }
      var action = remote == null
          ? SnapshotAction.upload
          : snapshotAction(local.revision, remote.snapshot.revision, baseline);
      if (action == SnapshotAction.restore ||
          action == SnapshotAction.conflict) {
        final selected = await choose(action);
        if (selected == null) return 'Cancelled; no data changed';
        if (selected != SnapshotAction.restore &&
            selected != SnapshotAction.upload) {
          throw StateError('Invalid snapshot choice');
        }
        action = selected;
      }
      final latest = await store.read(path);
      if (latest?.version != remote?.version) {
        throw StateError('Shared file changed during sync. Please retry.');
      }
      if (action == SnapshotAction.upload) {
        await recovery(local);
        if (remote != null) await recovery(remote.snapshot);
        await store.write(path, local, remote);
        final check = await store.read(path);
        if (check?.snapshot.revision != local.revision) {
          throw StateError('Backup write verification failed');
        }
        baseline = local.revision;
      } else if (action == SnapshotAction.restore) {
        await recovery(local);
        await db.transaction(() async {
          if ((await Snapshot.capture(db)).revision != local.revision) {
            throw StateError('Local data changed during sync. Please retry.');
          }
          if (remote == null) throw StateError('No snapshot to restore');
          await remote.snapshot.apply(
            db,
            Directory('${directory.path}${Platform.pathSeparator}restored-fit'),
          );
        });
        restoreGeneration++;
        baseline = remote!.snapshot.revision;
      } else {
        baseline = local.revision;
      }
      lastSync = DateTime.now();
      await save();
      return switch (action) {
        SnapshotAction.upload => store.uploadMessage,
        SnapshotAction.restore =>
          'Backup restored. Previous data is saved in ${directory.path}${Platform.pathSeparator}recovery.',
        _ => 'Already up to date',
      };
    } finally {
      busy = false;
    }
  }
}
