import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/database.dart';
import 'package:formforge/integrations/garmin/garmin_auth.dart';
import 'package:formforge/integrations/garmin/garmin_client.dart';
import 'package:formforge/integrations/garmin/garmin_sync_service.dart';
import 'package:formforge/integrations/garmin/garmin_tokens.dart';

import 'fake_http.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('upserts Garmin activities by externalId', () async {
    var name = 'Run';
    final http = FakeAdapter(
      (_) => FakeResponse.json([
        {
          'activityId': 7,
          'activityName': name,
          'startTimeGMT': '2026-09-26 05:30:00',
          'activityType': {'typeKey': 'running'},
          'distance': 5000.0,
          'duration': 1500.4,
          'averageHR': 150.0,
          'maxHR': 170.0,
          'averageSpeed': 3.33,
        },
      ]),
    );
    final client = GarminClient(
      store: InMemoryGarminTokenStore(
        GarminTokens(
          accessToken: 'a',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        ),
      ),
      auth: GarminAuth(),
      dio: http.dio,
    );
    final sync = GarminSyncService(db, client);

    expect(await sync.syncRecent(), 1);
    await (db.update(db.activities)..where((t) => t.externalId.equals('7')))
        .write(const ActivitiesCompanion(fitPath: Value('/fit/7.fit')));
    name = 'Renamed run';
    expect(await sync.syncRecent(), 1);

    final rows = await db.select(db.activities).get();
    expect(rows, hasLength(1));
    final a = rows.single;
    expect(a.source, ActivitySource.garmin);
    expect(a.name, 'Renamed run');
    expect(a.sport, 'running');
    expect(a.startTime.toUtc(), DateTime.utc(2026, 9, 26, 5, 30));
    expect(
      (a.distanceM, a.durationS, a.avgHr, a.maxHr, a.avgSpeed),
      (5000.0, 1500, 150.0, 170.0, 3.33),
    );
    expect(a.fitPath, '/fit/7.fit');
  });
}
