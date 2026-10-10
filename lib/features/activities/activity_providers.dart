import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart' show Value;
import 'package:fit_io/fit_io.dart';
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
      .map((row) {
        if (row != null && row.timerStops == null) {
          unawaited(_backfillTimerStops(db, id));
        }
        return row == null ? null : ActivityStreamData.fromRow(row);
      });
});

final _backfillTried = <int>{};

/// Streams stored before pause support: read timer events from the FIT file.
Future<void> _backfillTimerStops(AppDatabase db, int activityId) async {
  if (!_backfillTried.add(activityId)) return;
  final a = await (db.select(
    db.activities,
  )..where((t) => t.id.equals(activityId))).getSingleOrNull();
  final path = a?.fitPath;
  if (a == null || path == null || !await File(path).exists()) return;
  try {
    final bytes = await File(path).readAsBytes();
    final fit = FitActivity.fromFile(
      await Isolate.run(() => const FitDecoder().decode(bytes)),
    );
    final stops = [
      for (final (s, e) in fit.timerPauses)
        (
          s.difference(a.startTime).inSeconds,
          e.difference(a.startTime).inSeconds,
        ),
    ];
    await (db.update(db.activityStreams)
          ..where((t) => t.activityId.equals(activityId)))
        .write(ActivityStreamsCompanion(timerStops: Value(packStops(stops))));
  } on Object {
    // Unreadable file: keep gap-based detection.
  }
}

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
