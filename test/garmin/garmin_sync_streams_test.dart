import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/database.dart';
import 'package:formforge/features/adaptation/matching_service.dart';
import 'package:formforge/integrations/garmin/garmin_auth.dart';
import 'package:formforge/integrations/garmin/garmin_client.dart';
import 'package:formforge/integrations/garmin/garmin_sync_service.dart';
import 'package:formforge/integrations/garmin/garmin_tokens.dart';
import 'package:training_core/training_core.dart' hide TrainingPlan;

import '../adaptation/helpers.dart';
import '../fit_fixtures.dart';
import 'fake_http.dart';

void main() {
  late AppDatabase db;
  late Directory dir;
  final clock = DateTime.utc(2026, 10, 1);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dir = await Directory.systemTemp.createTemp('formforge_sync_');
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  String gmt(DateTime t) => t.toUtc().toString().substring(0, 19);

  Map<String, Object?> activityJson(int id, String type, DateTime start) => {
    'activityId': id,
    'activityName': 'Activity $id',
    'startTimeGMT': gmt(start),
    'activityType': {'typeKey': type},
    'distance': 3600.0,
    'duration': 1200.0,
    'averageHR': 143.0,
    'maxHR': 147.0,
    'averageSpeed': 3.0,
  };

  /// Serves [activities] (newest first, paged) plus per-activity downloads.
  FakeAdapter garminApi(
    List<Map<String, Object?>> activities, {
    FakeResponse Function(int id)? fit,
    FakeResponse Function(int id)? details,
  }) => FakeAdapter((o) {
    final path = o.uri.path;
    if (path.endsWith('activities/search/activities')) {
      final start = int.parse('${o.queryParameters['start']}');
      final limit = int.parse('${o.queryParameters['limit']}');
      return FakeResponse.json(activities.skip(start).take(limit).toList());
    }
    final id = int.parse(RegExp(r'activity/(\d+)').firstMatch(path)![1]!);
    return path.contains('download-service')
        ? (fit ?? (_) => FakeResponse(404, const []))(id)
        : (details ?? (_) => FakeResponse.json(const {}))(id);
  });

  GarminSyncService service(FakeAdapter http) => GarminSyncService(
    db,
    GarminClient(
      store: InMemoryGarminTokenStore(
        GarminTokens(
          accessToken: 'a',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        ),
      ),
      auth: GarminAuth(),
      dio: http.dio,
    ),
    matcher: MatchingService(
      db,
      clock: () => clock,
      lapLoader: (_) async => [],
    ),
    storageDir: () async => dir,
    clock: () => clock,
  );

  Future<Activity> activity(String externalId) => (db.select(
    db.activities,
  )..where((t) => t.externalId.equals(externalId))).getSingle();

  Future<ActivityStream?> streamsOf(String externalId) async {
    final a = await activity(externalId);
    return (db.select(
      db.activityStreams,
    )..where((t) => t.activityId.equals(a.id))).getSingleOrNull();
  }

  int requestsTo(FakeAdapter http, String fragment) =>
      http.requests.where((r) => r.uri.path.contains(fragment)).length;

  FakeResponse zipped(List<int> bytes) =>
      FakeResponse(200, bytes, contentType: 'application/zip');

  test('stores FIT streams and file for runs, skips other sports', () async {
    final bytes = syntheticRunFit();
    final http = garminApi([
      activityJson(8, 'cycling', runStart.add(const Duration(hours: 5))),
      activityJson(7, 'running', runStart),
    ], fit: (_) => zipped(bytes));

    final result = await service(http).sync();
    expect(result.fetched, 2);
    expect(result.streamsStored, 1);
    expect((await streamsOf('7'))!.sampleCount, 1201);
    expect(await streamsOf('8'), isNull);
    expect(requestsTo(http, 'files/activity/8'), 0);

    final a = await activity('7');
    expect(await File(a.fitPath!).readAsBytes(), bytes);
    expect(a.fitPath, startsWith(dir.path));

    // Already stored: a second sync does not download again.
    await service(http).sync();
    expect(requestsTo(http, 'files/activity/7'), 1);
  });

  test(
    'falls back to the detail samples when the FIT download fails',
    () async {
      final http = garminApi(
        [activityJson(9, 'running', runStart)],
        details: (_) => FakeResponse.json({
          'metricDescriptors': [
            {'key': 'sumDuration', 'metricsIndex': 0},
            {'key': 'directSpeed', 'metricsIndex': 1},
            {'key': 'directHeartRate', 'metricsIndex': 2},
          ],
          'activityDetailMetrics': [
            for (var i = 0; i < 5; i++)
              {
                'metrics': [i, 3.0, 140 + i],
              },
          ],
        }),
      );
      final result = await service(http).sync();
      expect(result.streamsStored, 1);
      final row = (await streamsOf('9'))!;
      expect(row.sampleCount, 5);
      expect(row.distance, isNull);
      expect((await activity('9')).fitPath, isNull);
    },
  );

  test('remembers activities without any data', () async {
    final http = garminApi([activityJson(9, 'running', runStart)]);
    await service(http).sync();
    await service(http).sync();
    expect(await streamsOf('9'), isNull);
    expect(requestsTo(http, 'activity/9/details'), 1);
  });

  test('stops on rate limiting and retries next time', () async {
    final bytes = syntheticRunFit();
    var limited = true;
    final http = garminApi([
      activityJson(7, 'running', runStart),
      activityJson(6, 'running', runStart.subtract(const Duration(days: 1))),
    ], fit: (_) => limited ? FakeResponse(429, const []) : zipped(bytes));
    final first = await service(http).sync();
    expect(first.rateLimited, isTrue);
    expect(first.streamsStored, 0);
    expect(requestsTo(http, 'download-service'), 1);

    limited = false;
    final second = await service(http).sync();
    expect(second.rateLimited, isFalse);
    expect(second.streamsStored, 2);
  });

  test('incremental sync stops paging at the last synced start', () async {
    final starts = [
      DateTime.utc(2026, 9, 29, 7),
      DateTime.utc(2026, 9, 27, 7),
      DateTime.utc(2026, 9, 20, 7),
    ];
    final http = garminApi([
      for (var i = 0; i < starts.length; i++)
        activityJson(30 - i, 'running', starts[i]),
    ]);
    final s = service(http);

    expect((await s.sync(pageSize: 2)).fetched, 3);
    expect(requestsTo(http, 'activities/search'), 2);
    expect(
      await db.getSetting(GarminSyncKeys.lastSyncStart),
      starts.first.toIso8601String(),
    );

    http.requests.clear();
    expect((await s.sync(pageSize: 2)).fetched, 2);
    expect(requestsTo(http, 'activities/search'), 1);
  });

  test('matches synced runs to the plan', () async {
    await setFitness(db, 50);
    final plannedId = await addPlanned(
      db,
      date: dayOf(runStart),
      workout: SessionTemplates.easy(const Duration(minutes: 20)),
    );
    final http = garminApi([
      activityJson(7, 'running', runStart),
    ], fit: (_) => zipped(syntheticRunFit()));
    final result = await service(http).sync();
    expect(result.matched, 1);
    final p = await (db.select(
      db.plannedWorkouts,
    )..where((t) => t.id.equals(plannedId))).getSingle();
    expect(p.status, WorkoutStatus.done);
    expect(p.complianceJson, isNotNull);
  });
}
