import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/activity_streams.dart';
import '../../data/database.dart';
import '../../integrations/fit/fit_import_service.dart';
import '../../providers.dart';
import 'activity_analysis.dart';

final fitImportServiceProvider = Provider<FitImportService>(
  (ref) => FitImportService(ref.watch(databaseProvider)),
);

final activityProvider = StreamProvider.family<Activity?, int>((ref, id) {
  final db = ref.watch(databaseProvider);
  return (db.select(
    db.activities,
  )..where((t) => t.id.equals(id))).watchSingleOrNull();
});

final activityStreamProvider = StreamProvider.family<ActivityStreamData?, int>((
  ref,
  id,
) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.activityStreams)..where((t) => t.activityId.equals(id)))
      .watchSingleOrNull()
      .map((row) => row == null ? null : ActivityStreamData.fromRow(row));
});

final activityAnalysisProvider = FutureProvider.family<ActivityAnalysis?, int>((
  ref,
  id,
) async {
  final activity = await ref.watch(activityProvider(id).future);
  final streams = await ref.watch(activityStreamProvider(id).future);
  final profile = await ref.watch(profileProvider.future);
  if (activity == null || streams == null) return null;
  return ActivityAnalysis.compute(activity, streams.toSamples(), profile);
});
