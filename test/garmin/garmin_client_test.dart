import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/integrations/garmin/garmin_auth.dart';
import 'package:formforge/integrations/garmin/garmin_client.dart';
import 'package:formforge/integrations/garmin/garmin_exceptions.dart';
import 'package:formforge/integrations/garmin/garmin_models.dart';
import 'package:formforge/integrations/garmin/garmin_tokens.dart';

import 'fake_http.dart';

final now = DateTime.utc(2026, 9, 27, 12);

class FakeAuth extends GarminAuth {
  var refreshCalls = 0;

  @override
  Future<GarminTokens> refresh(GarminTokens tokens) async {
    refreshCalls++;
    return GarminTokens(
      accessToken: 'fresh-$refreshCalls',
      expiresAt: now.add(const Duration(hours: 1)),
    );
  }
}

GarminTokens valid([String access = 'valid']) => GarminTokens(
  accessToken: access,
  expiresAt: now.add(const Duration(hours: 2)),
);

({
  GarminClient client,
  FakeAdapter http,
  FakeAuth auth,
  InMemoryGarminTokenStore store,
})
setup(FakeHandler handler, {GarminTokens? tokens}) {
  final http = FakeAdapter(handler);
  final auth = FakeAuth();
  final store = InMemoryGarminTokenStore(tokens ?? valid());
  return (
    client: GarminClient(
      store: store,
      auth: auth,
      dio: http.dio,
      clock: () => now,
    ),
    http: http,
    auth: auth,
    store: store,
  );
}

void main() {
  group('tokens', () {
    test('json round trip', () {
      final t = GarminTokens(
        accessToken: 'a',
        refreshToken: 'r',
        clientId: 'c',
        expiresAt: now,
        oauth1Token: 'o',
        oauth1Secret: 's',
        mfaToken: 'm',
      );
      final back = GarminTokens.fromJson(
        jsonDecode(jsonEncode(t.toJson())) as Map<String, Object?>,
      );
      expect(
        (back.accessToken, back.refreshToken, back.clientId, back.expiresAt),
        ('a', 'r', 'c', now),
      );
      expect(
        (back.oauth1Token, back.oauth1Secret, back.mfaToken),
        ('o', 's', 'm'),
      );
      expect(t.toString(), isNot(contains('a,')));
    });

    test('expiry margin', () {
      final t = GarminTokens(
        accessToken: 'a',
        expiresAt: now.add(const Duration(minutes: 10)),
      );
      expect(t.expiresWithin(const Duration(minutes: 15), now), isTrue);
      expect(t.expiresWithin(const Duration(minutes: 5), now), isFalse);
    });
  });

  test('refreshes before expiry and persists new tokens', () async {
    final s = setup(
      (_) => FakeResponse.json({'displayName': 'u1', 'fullName': 'Ada'}),
      tokens: GarminTokens(
        accessToken: 'stale',
        expiresAt: now.add(const Duration(minutes: 5)),
      ),
    );

    final profile = await s.client.socialProfile();

    expect(profile.label, 'Ada');
    expect(s.auth.refreshCalls, 1);
    expect(s.http.requests.single.headers['Authorization'], 'Bearer fresh-1');
    expect(s.store.tokens?.accessToken, 'fresh-1');
  });

  test('on 401 refreshes once and retries', () async {
    final s = setup(
      (o) => o.headers['Authorization'] == 'Bearer valid'
          ? FakeResponse.json({'message': 'expired'}, status: 401)
          : FakeResponse.json({'displayName': 'u1'}),
    );

    expect((await s.client.socialProfile()).label, 'u1');
    expect(s.auth.refreshCalls, 1);
    expect(s.http.requests.map((r) => r.headers['Authorization']), [
      'Bearer valid',
      'Bearer fresh-1',
    ]);
  });

  test('second 401 is not retried again', () async {
    final s = setup((_) => FakeResponse.json({}, status: 401));
    await expectLater(
      s.client.socialProfile(),
      throwsA(isA<GarminNotConnected>()),
    );
    expect(s.http.requests, hasLength(2));
    expect(s.auth.refreshCalls, 1);
  });

  test('no stored tokens means not connected', () async {
    final s = setup((_) => FakeResponse.json({}));
    await s.store.clear();
    await expectLater(
      s.client.listActivities(),
      throwsA(isA<GarminNotConnected>()),
    );
    expect(s.http.requests, isEmpty);
  });

  test('listActivities parses summaries', () async {
    final s = setup((o) {
      expect(o.uri.path, '/activitylist-service/activities/search/activities');
      expect(o.uri.queryParameters, {'start': '5', 'limit': '2'});
      return FakeResponse.json([
        {
          'activityId': 17112345678,
          'activityName': 'Morning Run',
          'startTimeGMT': '2026-09-26 05:30:00',
          'startTimeLocal': '2026-09-26 07:30:00',
          'activityType': {'typeKey': 'running', 'typeId': 1},
          'distance': 10012.5,
          'duration': 3021.7,
          'averageHR': 148.0,
          'maxHR': 171,
          'averageSpeed': 3.313,
        },
        {
          'activityId': 2,
          'beginTimestamp': 1790000000000,
          'activityType': {'typeKey': 'strength_training'},
          'duration': 1800,
        },
      ]);
    });

    final list = await s.client.listActivities(start: 5, limit: 2);

    final run = list.first;
    expect(run.activityId, 17112345678);
    expect(run.name, 'Morning Run');
    expect(run.typeKey, 'running');
    expect(run.startTime, DateTime.utc(2026, 9, 26, 5, 30));
    expect(run.distanceM, 10012.5);
    expect(run.durationS, 3021.7);
    expect((run.avgHr, run.maxHr, run.avgSpeed), (148.0, 171.0, 3.313));
    final lift = list.last;
    expect(lift.typeKey, 'strength_training');
    expect(
      lift.startTime,
      DateTime.fromMillisecondsSinceEpoch(1790000000000, isUtc: true),
    );
    expect(lift.distanceM, isNull);
  });

  test('activity details map to samples by metric index', () async {
    final s = setup((o) {
      expect(o.uri.path, '/activity-service/activity/42/details');
      return FakeResponse.json({
        'metricDescriptors': [
          {
            'metricsIndex': 0,
            'key': 'directHeartRate',
            'unit': {'key': 'bpm'},
          },
          {'metricsIndex': 1, 'key': 'directTimestamp'},
          {'metricsIndex': 2, 'key': 'sumDuration'},
          {'metricsIndex': 3, 'key': 'directSpeed'},
        ],
        'activityDetailMetrics': [
          {
            'metrics': [120.0, 1790000000000.0, 0.0, 2.5],
          },
          {
            'metrics': [130.4, 1790000001000.0, 1.0, null],
          },
          {
            'metrics': [null, 1790000002000.0, 2.2, 3.1],
          },
        ],
      });
    });

    final samples = await s.client.activitySamples(42);

    expect(samples.map((x) => (x.second, x.hr, x.speed)), [
      (0, 120, 2.5),
      (1, 130, null),
      (2, null, 3.1),
    ]);
  });

  test('falls back to directTimestamp when no duration channel exists', () {
    final samples = samplesFromDetails({
      'metricDescriptors': [
        {'metricsIndex': 1, 'key': 'directTimestamp'},
        {'metricsIndex': 0, 'key': 'directSpeed'},
      ],
      'activityDetailMetrics': [
        {
          'metrics': [2.0, 1000.0],
        },
        {
          'metrics': [2.1, 6000.0],
        },
      ],
    });
    expect(samples.map((x) => (x.second, x.speed)), [(0, 2.0), (5, 2.1)]);
  });

  test('downloadFit unpacks the zipped FIT file', () async {
    final fit = Uint8List.fromList([
      14,
      16,
      0x6B,
      0x08,
      1,
      2,
      3,
      4,
      0x2E,
      0x46,
      0x49,
      0x54,
    ]);
    final zip = ZipEncoder().encodeBytes(
      Archive()
        ..add(ArchiveFile.string('readme.txt', 'x'))
        ..add(ArchiveFile.bytes('42_ACTIVITY.fit', fit)),
    );
    final s = setup((o) {
      expect(o.uri.path, '/download-service/files/activity/42');
      return FakeResponse(
        200,
        zip,
        contentType: 'application/x-zip-compressed',
      );
    });

    expect(await s.client.downloadFit(42), fit);
  });

  test(
    'workout create, schedule and calendar month use Garmin conventions',
    () async {
      final s = setup(
        (o) => switch (route(o)) {
          'POST connectapi.garmin.com/workout-service/workout' =>
            FakeResponse.json({'workoutId': 991}),
          'POST connectapi.garmin.com/workout-service/schedule/991' =>
            FakeResponse.json({
              'workoutScheduleId': 555,
              'calendarDate': '2026-10-03',
            }),
          'GET connectapi.garmin.com/calendar-service/year/2026/month/0' =>
            FakeResponse.json({'calendarItems': <Object>[]}),
          'DELETE connectapi.garmin.com/workout-service/schedule/555' ||
          'DELETE connectapi.garmin.com/workout-service/workout/991' =>
            FakeResponse(204, const []),
          _ => FakeResponse.json({}, status: 404),
        },
      );

      expect(await s.client.createWorkout({'workoutName': 'Easy'}), 991);
      expect(await s.client.scheduleWorkout(991, DateTime(2026, 10, 3)), 555);
      expect(s.http.requests[1].data, {'date': '2026-10-03'});
      expect(await s.client.calendarMonth(2026, 1), {
        'calendarItems': <Object>[],
      });
      await s.client.unscheduleWorkout(555);
      await s.client.deleteWorkout(991);
      expect(() => s.client.calendarMonth(2026, 13), throwsRangeError);
    },
  );

  test('HTTP errors map to typed exceptions', () async {
    final s = setup(
      (o) => FakeResponse.json(
        {},
        status: o.uri.path.contains('search') ? 429 : 500,
      ),
    );
    await expectLater(
      s.client.listActivities(),
      throwsA(isA<GarminRateLimited>()),
    );
    await expectLater(
      s.client.socialProfile(),
      throwsA(
        isA<GarminApiException>().having((e) => e.statusCode, 'status', 500),
      ),
    );
  });
}
