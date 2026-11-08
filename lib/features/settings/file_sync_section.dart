import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/file_sync.dart';
import '../../data/shared_file.dart';
import '../../integrations/google/google_providers.dart';
import '../../integrations/google/google_drive_store.dart';
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

  bool get _googleSignedIn =>
      ref.read(googleAuthorizationProvider).value?.account != null;

  Future<FileSync> _service() => _googleSignedIn
      ? ref.read(googleFileSyncProvider.future)
      : ref.read(fileSyncProvider.future);

  Future<void> _accountAction(bool signIn) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final authorization = await ref.read(googleAuthorizationProvider.future);
      if (signIn) {
        await authorization.signIn();
      } else {
        await authorization.signOut();
      }
      if (!mounted) return;
      ref.invalidate(googleFileSyncProvider);
      if (mounted) {
        setState(
          () => _status = signIn
              ? 'Signed in. Press Sync to compare with your Google backup.'
              : 'Signed out. File-based exchange is available again.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _status = 'Google ${signIn ? 'sign-in' : 'sign-out'} failed: $e',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(Future<String> Function(FileSync) action) async {
    if (_busy) return;
    FileSync? service;
    var generation = 0;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final loaded = await _service();
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
          '${_googleSignedIn ? 'Uploading adds a new Google backup version and preserves older versions.' : 'Uploading replaces the shared snapshot.'} '
          'Passwords and tokens remain on this device.',
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

  Future<GoogleBackupVersion?> _chooseVersion(
    List<GoogleBackupVersion> versions,
  ) async {
    if (!mounted) return null;
    return showDialog<GoogleBackupVersion>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Concurrent Google backups'),
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'More than one device uploaded independently. Choose a snapshot to compare with this device. No version has been overwritten.',
            ),
          ),
          for (final version in versions)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, version),
              child: Text(
                '${version.created.toLocal()} (${version.revision.substring(0, 8)})',
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _sync() => _run((service) async {
    final store = service.store;
    if (store is GoogleDriveStore) store.chooseVersion = _chooseVersion;
    try {
      return await service.sync(_choose);
    } finally {
      if (store is GoogleDriveStore) store.chooseVersion = null;
    }
  });

  Future<void> _resetGoogle() => _run((service) async {
    if (!mounted) return 'Cancelled';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Google backup connection?'),
        content: const Text(
          'Forget this device’s last shared revision. No cloud or local training data is deleted. If your cloud backup is missing, the next Sync will upload the current data as a new backup.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset connection'),
          ),
        ],
      ),
    );
    if (confirmed != true) return 'Cancelled';
    service.baseline = null;
    service.lastSync = null;
    await service.save();
    return 'Google backup connection reset. Press Sync.';
  });

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
    final authorization = ref.watch(googleAuthorizationProvider);
    final account = authorization.value?.account;
    final signedIn = account != null;
    final service = signedIn
        ? ref.watch(googleFileSyncProvider)
        : ref.watch(fileSyncProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Backup exchange', style: Theme.of(context).textTheme.titleMedium),
        const Text(
          'Snapshot exchange, not merging. Sign in to Google Drive, or use a writable file while signed out. '
          'Backups are compressed, not encrypted, and include sensitive training/location data.',
        ),
        const SizedBox(height: 8),
        if (authorization.isLoading) const LinearProgressIndicator(),
        if (authorization.hasError) ...[
          Text('Cannot initialize Google sign-in: ${authorization.error}'),
          TextButton(
            onPressed: _busy
                ? null
                : () => ref.invalidate(googleAuthorizationProvider),
            child: const Text('Retry Google sign-in setup'),
          ),
        ],
        if (!authorization.isLoading && !authorization.hasError)
          OutlinedButton(
            onPressed: _busy ? null : () => _accountAction(!signedIn),
            child: Text(
              signedIn ? 'Sign out of Google' : 'Sign in with Google',
            ),
          ),
        if (account != null) Text('Google account: ${account.email}'),
        service.when(
          data: (value) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!signedIn && value.target != null)
                Text('File: ${value.target}'),
              if (value.lastSync != null)
                Text('Last exchange: ${value.lastSync!.toLocal()}'),
              Wrap(
                spacing: 8,
                children: [
                  if (!signedIn)
                    OutlinedButton(
                      onPressed: _busy ? null : () => _connect(true),
                      child: const Text('Create shared file'),
                    ),
                  if (!signedIn)
                    OutlinedButton(
                      onPressed: _busy ? null : () => _connect(false),
                      child: const Text('Connect existing file'),
                    ),
                  FilledButton(
                    onPressed: _busy || value.target == null ? null : _sync,
                    child: const Text('Sync'),
                  ),
                  if (signedIn)
                    TextButton(
                      onPressed: _busy ? null : _resetGoogle,
                      child: const Text('Reset Google backup connection'),
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
          error: (error, _) => Text('Cannot load backup settings: $error'),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_status != null) Text(_status!),
      ],
    );
  }
}
