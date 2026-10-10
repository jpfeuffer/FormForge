import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:fit_io/fit_io.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/activity_merge.dart';
import '../../data/activity_streams.dart';
import '../../data/database.dart';
import '../../data/sports.dart';
import '../../features/adaptation/matching_service.dart';
import 'garmin_client.dart';
import 'garmin_exceptions.dart';
import 'garmin_models.dart';

abstract final class GarminSyncKeys {
  /// ISO-8601 UTC start of the newest activity seen by a sync.
  static const lastSyncStart = 'garmin.lastSyncStart';
  static const syncOnStart = 'garmin.syncOnStart';

  /// Per activity: no streams available at Garmin, do not ask again.
  static String noStreams(int activityId) => 'garmin.noStreams.$activityId';
}

class GarminSyncResult {
  const GarminSyncResult({
    this.fetched = 0,
    this.merged = 0,
    this.streamsStored = 0,
    this.streamsFailed = 0,
    this.matched = 0,
    this.rateLimited = false,
  });

  final int fetched;

  /// Activities folded into an already imported FIT recording.
  final int merged;
  final int streamsStored;
  final int streamsFailed;

  /// Planned workouts newly linked to an activity.
  final int matched;
  final bool rateLimited;

  String get message => [
    '$fetched activities',
    if (merged > 0) '$merged merged with FIT imports',
    if (streamsStored > 0) '$streamsStored with details',
    if (matched > 0) '$matched matched to plan',
    if (rateLimited) 'rate limited, details will follow next sync',
  ].join(' · ');
}

class GarminSyncService {
  GarminSyncService(
    this._db,
    this._client, {
    MatchingService? matcher,
    Future<Directory> Function()? storageDir,
    DateTime Function()? clock,
  }) : _matcher = matcher ?? MatchingService(_db),
       _merger = ActivityMerger(_db),
       _storageDir = storageDir ?? getApplicationDocumentsDirectory,
       _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final GarminClient _client;
  final MatchingService _matcher;
  final ActivityMerger _merger;
  final Future<Directory> Function() _storageDir;
  final DateTime Function() _clock;

  /// Streams fetched per sync, newest first; the rest follows next time.
  static const maxStreamFetches = 15;
  static const streamBackfillDays = 30;

  /// Upserts the most recent Garmin activities; returns how many were fetched.
  Future<int> syncRecent({int limit = 20}) async {
    final list = await _client.listActivities(limit: limit);
    await _ingest(list);
    return list.length;
  }

  /// Fetches everything since the last sync (the last [initialLimit]
  /// activities the first time), in pages of [pageSize].
  Future<GarminSyncResult> sync({
    int initialLimit = 100,
    int pageSize = 50,
    int maxPages = 10,
  }) async {
    final since = DateTime.tryParse(
      await _db.getSetting(GarminSyncKeys.lastSyncStart) ?? '',
    );
    // Garmin lists newest first; re-read a day to catch late edits.
    final cutoff = since?.subtract(const Duration(days: 1));
    final all = <GarminActivitySummary>[];
    for (var page = 0; page < maxPages; page++) {
      final list = await _client.listActivities(
        start: page * pageSize,
        limit: pageSize,
      );
      all.addAll(list);
      if (list.length < pageSize) break;
      final done = cutoff == null
          ? all.length >= initialLimit
          : list.last.startTime.isBefore(cutoff);
      if (done) break;
    }
    return _ingest(all);
  }

  Future<GarminSyncResult> _ingest(List<GarminActivitySummary> list) async {
    final merged = await upsert(list);
    final newest = list.fold<DateTime?>(
      null,
      (a, s) => a == null || s.startTime.isAfter(a) ? s.startTime : a,
    );
    if (newest != null) {
      final previous = DateTime.tryParse(
        await _db.getSetting(GarminSyncKeys.lastSyncStart) ?? '',
      );
      if (previous == null || newest.isAfter(previous)) {
        await _db.setSetting(
          GarminSyncKeys.lastSyncStart,
          newest.toUtc().toIso8601String(),
        );
      }
    }
    final streams = await _fetchMissingStreams();
    final matched = await _matcher.matchAll();
    return GarminSyncResult(
      fetched: list.length,
      merged: merged,
      streamsStored: streams.stored,
      streamsFailed: streams.failed,
      matched: matched,
      rateLimited: streams.rateLimited,
    );
  }

  /// Upserts by Garmin id; returns how many FIT-imported duplicates were
  /// folded into the Garmin rows.
  Future<int> upsert(
    List<GarminActivitySummary> list,
  ) => _db.transaction(() async {
    var merged = 0;
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
      await _db
          .into(_db.activities)
          .insert(
            row,
            onConflict: DoUpdate(
              (_) => row,
              target: [_db.activities.externalId],
            ),
          );
      final id = (await (_db.select(
        _db.activities,
      )..where((t) => t.externalId.equals('${a.activityId}'))).getSingle()).id;
      final twin = await _merger.findTwin(
        source: ActivitySource.garmin,
        sport: a.typeKey,
        start: a.startTime,
        excludeId: id,
      );
      if (twin != null && twin.source == ActivitySource.fitFile) {
        await _merger.merge(keepId: id, dropId: twin.id);
        merged++;
      }
    }
    return merged;
  });

  Future<({int stored, int failed, bool rateLimited})>
  _fetchMissingStreams() async {
    final since = _clock().subtract(const Duration(days: streamBackfillDays));
    final withStreams = _db.selectOnly(_db.activityStreams)
      ..addColumns([_db.activityStreams.activityId]);
    final candidates =
        await (_db.select(_db.activities)
              ..where(
                (t) =>
                    t.source.equalsValue(ActivitySource.garmin) &
                    t.startTime.isBiggerOrEqualValue(since) &
                    t.id.isNotInQuery(withStreams),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.startTime)]))
            .get();

    var stored = 0, failed = 0, fetches = 0;
    for (final a in candidates) {
      final garminId = int.tryParse(a.externalId ?? '');
      if (garminId == null || !isRunSport(a.sport)) continue;
      if (await _db.getSetting(GarminSyncKeys.noStreams(garminId)) != null) {
        continue;
      }
      if (fetches++ >= maxStreamFetches) break;
      try {
        if (await _storeStreams(a, garminId)) {
          stored++;
        } else {
          await _db.setSetting(GarminSyncKeys.noStreams(garminId), '1');
        }
      } on GarminRateLimited {
        return (stored: stored, failed: failed, rateLimited: true);
      } on GarminException {
        failed++;
      }
    }
    return (stored: stored, failed: failed, rateLimited: false);
  }

  /// FIT first (distance, GPS, laps), plain samples as fallback; false if
  /// Garmin has no data for the activity.
  Future<bool> _storeStreams(Activity activity, int garminId) async {
    FitActivity? fit;
    Uint8List? fitBytes;
    try {
      final bytes = fitBytes = await _client.downloadFit(garminId);
      fit = FitActivity.fromFile(
        await Isolate.run(() => const FitDecoder().decode(bytes)),
      );
    } on GarminRateLimited {
      rethrow;
    } on GarminException {
      fit = null;
    } on FitFormatException {
      fit = null;
    }

    final records = [
      for (final r in fit?.records ?? const <FitRecord>[])
        if (r.timestamp != null) r,
    ];
    if (records.isNotEmpty) {
      final dir = Directory('${(await _storageDir()).path}/fit');
      await dir.create(recursive: true);
      final file = File('${dir.path}/garmin_$garminId.fit');
      await file.writeAsBytes(fitBytes!, flush: true);
      await _merger.enrich(
        activity.id,
        streams: ActivityStreamData.fromFitRecords(
          records,
          activity.startTime,
          pauses: fit!.timerPauses,
        ),
        fitPath: file.path,
      );
      return true;
    }

    final samples = await _client.activitySamples(garminId);
    if (samples.isEmpty) return false;
    await _merger.enrich(
      activity.id,
      streams: ActivityStreamData.fromSamples(samples),
    );
    return true;
  }
}
