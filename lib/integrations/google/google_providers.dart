import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/file_sync.dart';
import '../../providers.dart';
import 'google_auth.dart';
import 'google_drive_store.dart';

final googleAuthorizationProvider = FutureProvider<GoogleAuthorization>((
  ref,
) async {
  if (!Platform.isAndroid &&
      !Platform.isWindows &&
      !Platform.isLinux &&
      !Platform.isMacOS) {
    throw UnsupportedError(
      'Google backup is currently supported on Android and desktop only.',
    );
  }
  final GoogleAuthorization authorization = Platform.isAndroid
      ? AndroidGoogleAuthorization()
      : DesktopGoogleAuthorization(ref.watch(secretsProvider));
  await authorization.initialize();
  return authorization;
});

final googleFileSyncProvider = FutureProvider<FileSync>((ref) async {
  final db = ref.watch(databaseProvider);
  final authorization = await ref.watch(googleAuthorizationProvider.future);
  if (authorization.account == null) {
    throw StateError('Sign in to Google first');
  }
  final service = FileSync(
    db,
    await getApplicationSupportDirectory(),
    store: GoogleDriveStore(authorization),
  );
  await service.load();
  service.target = 'Google Drive';
  return service;
});
