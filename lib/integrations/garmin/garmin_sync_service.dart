import 'package:drift/drift.dart';

import '../../data/database.dart';
import 'garmin_client.dart';
import 'garmin_models.dart';

class GarminSyncService {
  GarminSyncService(this._db, this._client);
  final AppDatabase _db;
  final GarminClient _client;

  /// Upserts the most recent Garmin activities; returns how many were fetched.
  Future<int> syncRecent({int limit = 20}) async {
    final list = await _client.listActivities(limit: limit);
    await upsert(list);
    return list.length;
  }

  Future<void> upsert(List<GarminActivitySummary> list) => _db.batch((b) {
    for (final a in list) {
      final row = ActivitiesCompanion.insert(
        source: ActivitySource.garmin,
        externalId: Value('${a.activityId}'),
        startTime: a.startTime,
        sport: a.typeKey,
        name: Value(a.name),
        distanceM: Value(a.distanceM),
        durationS: a.durationS.round(),
        avgHr: Value(a.avgHr),
        maxHr: Value(a.maxHr),
        avgSpeed: Value(a.avgSpeed),
      );
      // fitPath is left untouched on update.
      b.insert(
        _db.activities,
        row,
        onConflict: DoUpdate((_) => row, target: [_db.activities.externalId]),
      );
    }
  });
}
