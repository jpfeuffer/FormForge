import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import 'garmin_auth.dart';
import 'garmin_client.dart';
import 'garmin_exceptions.dart';
import 'garmin_sync_service.dart';
import 'garmin_tokens.dart';

abstract final class GarminSettingKeys {
  static const displayName = 'garmin.displayName';
}

final garminTokenStoreProvider = Provider<GarminTokenStore>(
  (ref) => SecretsGarminTokenStore(ref.watch(secretsProvider)),
);

final garminAuthProvider = Provider<GarminAuth>((_) => GarminAuth());

final garminClientProvider = Provider<GarminClient>(
  (ref) => GarminClient(
    store: ref.watch(garminTokenStoreProvider),
    auth: ref.watch(garminAuthProvider),
  ),
);

final garminSyncServiceProvider = Provider<GarminSyncService>(
  (ref) => GarminSyncService(
    ref.watch(databaseProvider),
    ref.watch(garminClientProvider),
  ),
);

/// Display name of the connected Garmin account, or null when logged out.
final garminAccountProvider =
    AsyncNotifierProvider<GarminAccountNotifier, String?>(
      GarminAccountNotifier.new,
    );

class GarminAccountNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    if (await ref.watch(garminTokenStoreProvider).read() == null) return null;
    return await ref
            .watch(databaseProvider)
            .getSetting(GarminSettingKeys.displayName) ??
        'Garmin user';
  }

  Future<void> login(
    String email,
    String password, {
    required MfaPrompt promptMfa,
  }) async {
    final store = ref.read(garminTokenStoreProvider);
    final client = ref.read(garminClientProvider);
    final tokens = await ref
        .read(garminAuthProvider)
        .login(email, password, promptMfa: promptMfa);
    await store.write(tokens);
    client.clearCachedTokens();
    try {
      final profile = await client.socialProfile();
      await ref
          .read(databaseProvider)
          .setSetting(GarminSettingKeys.displayName, profile.label);
      state = AsyncData(profile.label);
    } on GarminException {
      // A token the API rejects is useless; don't keep it around.
      await store.clear();
      client.clearCachedTokens();
      rethrow;
    }
  }

  Future<void> logout() async {
    await ref.read(garminTokenStoreProvider).clear();
    ref.read(garminClientProvider).clearCachedTokens();
    state = const AsyncData(null);
  }
}
