import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import 'garmin_providers.dart';
import 'garmin_sync_service.dart';

/// Runs one sync at a time; state is the last result.
final garminSyncControllerProvider =
    AsyncNotifierProvider<GarminSyncController, GarminSyncResult?>(
      GarminSyncController.new,
    );

class GarminSyncController extends AsyncNotifier<GarminSyncResult?> {
  @override
  Future<GarminSyncResult?> build() async => null;

  Future<void> run() async {
    if (state.isLoading) return;
    state = const AsyncLoading<GarminSyncResult?>();
    state = await AsyncValue.guard(
      () => ref.read(garminSyncServiceProvider).sync(),
    );
  }
}

final garminSyncOnStartProvider =
    AsyncNotifierProvider<GarminSyncOnStartNotifier, bool>(
      GarminSyncOnStartNotifier.new,
    );

class GarminSyncOnStartNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async =>
      await ref
          .watch(databaseProvider)
          .getSetting(GarminSyncKeys.syncOnStart) ==
      '1';

  Future<void> set(bool enabled) async {
    await ref
        .read(databaseProvider)
        .setSetting(GarminSyncKeys.syncOnStart, enabled ? '1' : '0');
    state = AsyncData(enabled);
  }
}

/// Watch once at app start; syncs if connected and enabled.
final garminStartupSyncProvider = FutureProvider<void>((ref) async {
  if (!await ref.read(garminSyncOnStartProvider.future)) return;
  if (await ref.watch(garminAccountProvider.future) == null) return;
  await ref.read(garminSyncControllerProvider.notifier).run();
});
