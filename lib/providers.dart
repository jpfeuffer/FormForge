import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_core/training_core.dart';

import 'ai/llm_client.dart';
import 'data/database.dart';
import 'data/secrets.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final secretsProvider = Provider<Secrets>((_) => Secrets());

final profileProvider = StreamProvider<AthleteProfile?>(
    (ref) => ref.watch(databaseProvider).watchProfile());

final latestFitnessProvider = StreamProvider<FitnessSnapshot?>(
    (ref) => ref.watch(databaseProvider).watchLatestFitness());

final activitiesProvider = StreamProvider<List<Activity>>(
    (ref) => ref.watch(databaseProvider).watchActivities());

final _pacingFitnessProvider = StreamProvider<FitnessSnapshot?>(
    (ref) => ref.watch(databaseProvider).watchLatestPacingFitness());

/// Current paces for resolving symbolic workout targets; null until a test
/// or race with VDOT/MAS is logged. Race pace defaults to marathon pace.
final paceProfileProvider = Provider<PaceProfile?>((ref) {
  final fitness = ref.watch(_pacingFitnessProvider).value;
  if (fitness == null) return null;
  return PaceProfile.fromFitness(
    vdot: fitness.vdot,
    mas: fitness.masMps,
    lthr: ref.watch(profileProvider).value?.lthr,
  );
});

abstract final class SettingKeys {
  static const llmKind = 'llm.kind';
  static const llmBaseUrl = 'llm.baseUrl';
  static const llmModel = 'llm.model';
}

Future<LlmConfig?> loadLlmConfig(AppDatabase db, Secrets secrets) async {
  final kindName = await db.getSetting(SettingKeys.llmKind);
  final model = await db.getSetting(SettingKeys.llmModel);
  if (kindName == null || model == null) return null;
  final kind = LlmProviderKind.values.byName(kindName);
  return LlmConfig(
    kind: kind,
    baseUrl: await db.getSetting(SettingKeys.llmBaseUrl) ?? kind.defaultBaseUrl,
    model: model,
    apiKey: await secrets.read(Secrets.llmApiKey),
  );
}
