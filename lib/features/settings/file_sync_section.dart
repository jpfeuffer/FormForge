import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/file_sync.dart';
import '../../data/shared_file.dart';
import '../../providers.dart';

final fileSyncProvider = FutureProvider<FileSync>((ref) async {
  final db = ref.watch(databaseProvider);
  final service = FileSync(db, await getApplicationSupportDirectory());
  await service.load();
  return service;
});

class FileSyncSection extends ConsumerStatefulWidget {
  const FileSyncSection({super.key});

  @override
  ConsumerState<FileSyncSection> createState() => _FileSyncSectionState();
}

class _FileSyncSectionState extends ConsumerState<FileSyncSection> {
  bool _busy = false;
  String? _status;

  Future<void> _run(Future<String> Function(FileSync) action) async {
    if (_busy) return;
    FileSync? service;
    var generation = 0;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final loaded = await ref.read(fileSyncProvider.future);
      service = loaded;
      generation = loaded.restoreGeneration;
      final status = await action(loaded);
      if (mounted) setState(() => _status = status);
    } catch (e) {
      if (mounted) setState(() => _status = 'Snapshot exchange failed: $e');
    } finally {
      if (service != null && service.restoreGeneration != generation) {
        ref.invalidate(databaseProvider);
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect(bool create) => _run((service) async {
    final target = await SharedFile.pick(create: create);
    if (target == null) return 'Cancelled';
    await service.connect(target, create: create);
    return create
        ? 'Shared backup created'
        : 'Connected. Press Sync to compare snapshots.';
  });

  Future<SnapshotAction?> _choose(SnapshotAction action) async {
    if (!mounted) return null;
    return showDialog<SnapshotAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          action == SnapshotAction.conflict
              ? 'Choose which snapshot to keep'
              : 'Restore shared backup?',
        ),
        content: Text(
          '${action == SnapshotAction.conflict ? 'The snapshots differ and cannot be merged. ' : ''}'
          'Restore replaces all local training data. A local recovery backup is saved first. '
          'Uploading replaces the shared snapshot. Passwords and tokens remain on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          if (action == SnapshotAction.conflict)
            TextButton(
              onPressed: () => Navigator.pop(context, SnapshotAction.upload),
              child: const Text('Keep local / upload'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, SnapshotAction.restore),
            child: const Text('Use shared / restore'),
          ),
        ],
      ),
    );
  }

  Future<void> _sync() => _run((service) => service.sync(_choose));

  Future<void> _recover() => _run((service) async {
    final files = await service.recoveryFiles();
    if (files.isEmpty) return 'No local recovery backups yet';
    if (!mounted) return 'Cancelled';
    final selected = await showDialog<File>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Local recovery backups'),
        children: [
          for (final file in files)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, file),
              child: Text(
                DateTime.fromMicrosecondsSinceEpoch(
                  int.parse(file.uri.pathSegments.last.split('.').first),
                ).toLocal().toString(),
              ),
            ),
        ],
      ),
    );
    if (selected == null) return 'Cancelled';
    final status = await service.restoreRecovery(
      selected,
      () async =>
          await _choose(SnapshotAction.restore) == SnapshotAction.restore,
    );
    return status;
  });

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(fileSyncProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Shared backup file',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const Text(
          'Snapshot exchange, not merging. Choose a file in a synced cloud folder on desktop, '
          'or a writable cloud document on Android. Provider support varies. '
          'Backups are compressed, not encrypted, and include sensitive training/location data.',
        ),
        const SizedBox(height: 8),
        service.when(
          data: (value) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (value.target != null) Text('File: ${value.target}'),
              if (value.lastSync != null)
                Text('Last exchange: ${value.lastSync!.toLocal()}'),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _busy ? null : () => _connect(true),
                    child: const Text('Create shared file'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _connect(false),
                    child: const Text('Connect existing file'),
                  ),
                  FilledButton(
                    onPressed: _busy || value.target == null ? null : _sync,
                    child: const Text('Sync'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _recover,
                    child: const Text('Restore local recovery backup'),
                  ),
                ],
              ),
            ],
          ),
          loading: () => const LinearProgressIndicator(),
          error: (error, _) => Text('Cannot load shared file settings: $error'),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_status != null) Text(_status!),
      ],
    );
  }
}
