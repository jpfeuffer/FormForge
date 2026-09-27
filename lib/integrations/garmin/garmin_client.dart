import 'dart:async';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:training_core/training_core.dart';

import 'garmin_auth.dart';
import 'garmin_endpoints.dart';
import 'garmin_exceptions.dart';
import 'garmin_models.dart';
import 'garmin_tokens.dart';

/// Garmin Connect API client with bearer auth and transparent token refresh.
class GarminClient {
  GarminClient({
    required this._store,
    required this._auth,
    Dio? dio,
    DateTime Function()? clock,
    this.refreshMargin = const Duration(minutes: 15),
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 30),
               receiveTimeout: const Duration(seconds: 60),
             ),
           ),
       _clock = clock ?? DateTime.now;

  final GarminTokenStore _store;
  final GarminAuth _auth;
  final Dio _dio;
  final DateTime Function() _clock;
  final Duration refreshMargin;

  GarminTokens? _tokens;
  Future<GarminTokens>? _refreshing;

  /// Forget in-memory tokens, e.g. after login/logout changed the store.
  void clearCachedTokens() => _tokens = null;

  Future<GarminProfile> socialProfile() async => GarminProfile.fromJson(
    await _getMap('userprofile-service/socialProfile'),
  );

  Future<List<GarminActivitySummary>> listActivities({
    int start = 0,
    int limit = 20,
  }) async {
    final data = await _send(
      'GET',
      'activitylist-service/activities/search/activities',
      query: {'start': start, 'limit': limit},
    );
    if (data is! List) throw const GarminUnexpectedResponse('activity list');
    return [
      for (final a in data)
        GarminActivitySummary.fromJson((a as Map).cast<String, Object?>()),
    ];
  }

  Future<List<Sample>> activitySamples(
    int activityId, {
    int maxChartSize = 2000,
  }) async => samplesFromDetails(
    await _getMap(
      'activity-service/activity/$activityId/details',
      query: {'maxChartSize': maxChartSize, 'maxPolylineSize': 0},
    ),
  );

  /// The original FIT file (Garmin serves it zipped).
  Future<Uint8List> downloadFit(int activityId) async {
    final data = await _send(
      'GET',
      'download-service/files/activity/$activityId',
      responseType: ResponseType.bytes,
    );
    if (data is! List<int>) {
      throw const GarminUnexpectedResponse('FIT download');
    }
    return extractFit(Uint8List.fromList(data));
  }

  Future<int> createWorkout(Map<String, Object?> json) async => _intField(
    await _send('POST', 'workout-service/workout', data: json),
    'workoutId',
  );

  Future<void> deleteWorkout(int workoutId) async {
    await _send('DELETE', 'workout-service/workout/$workoutId');
  }

  Future<int> scheduleWorkout(int workoutId, DateTime date) async {
    final day =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    return _intField(
      await _send(
        'POST',
        'workout-service/schedule/$workoutId',
        data: {'date': day},
      ),
      'workoutScheduleId',
    );
  }

  Future<void> unscheduleWorkout(int scheduleId) async {
    await _send('DELETE', 'workout-service/schedule/$scheduleId');
  }

  /// [month] is 1-based; Garmin's calendar-service is 0-based.
  Future<Map<String, Object?>> calendarMonth(int year, int month) {
    RangeError.checkValueInInterval(month, 1, 12, 'month');
    return _getMap('calendar-service/year/$year/month/${month - 1}');
  }

  Future<Map<String, Object?>> _getMap(
    String path, {
    Map<String, Object?>? query,
  }) async {
    final data = await _send('GET', path, query: query);
    if (data is! Map) throw GarminUnexpectedResponse('non-object from $path');
    return data.cast<String, Object?>();
  }

  /// Returns the decoded body.
  Future<Object?> _send(
    String method,
    String path, {
    Map<String, Object?>? query,
    Object? data,
    ResponseType responseType = ResponseType.json,
  }) async {
    var tokens = await _validTokens();
    var res = await _request(method, path, tokens, query, data, responseType);
    if (res.statusCode == 401) {
      tokens = await _refresh(tokens);
      res = await _request(method, path, tokens, query, data, responseType);
    }
    final status = res.statusCode ?? 0;
    if (status == 401) throw const GarminNotConnected();
    if (status == 429) throw const GarminRateLimited();
    if (status >= 400) throw GarminApiException(status, path);
    return res.data;
  }

  Future<Response<Object?>> _request(
    String method,
    String path,
    GarminTokens tokens,
    Map<String, Object?>? query,
    Object? data,
    ResponseType responseType,
  ) async {
    try {
      return await _dio.request<Object?>(
        '${GarminEndpoints.connectApi}/$path',
        queryParameters: query,
        data: data,
        options: Options(
          method: method,
          headers: {
            ...GarminEndpoints.nativeHeaders,
            'Authorization': 'Bearer ${tokens.accessToken}',
            'Accept': responseType == ResponseType.bytes
                ? '*/*'
                : 'application/json',
          },
          contentType: data == null ? null : Headers.jsonContentType,
          responseType: responseType,
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e) {
      throw GarminNetworkError(e.type.name);
    }
  }

  Future<GarminTokens> _validTokens() async {
    final tokens = _tokens ??= await _store.read();
    if (tokens == null) throw const GarminNotConnected();
    return tokens.expiresWithin(refreshMargin, _clock())
        ? _refresh(tokens)
        : tokens;
  }

  Future<GarminTokens> _refresh(GarminTokens stale) {
    final current = _tokens;
    if (current != null && current.accessToken != stale.accessToken) {
      return Future.value(current);
    }
    return _refreshing ??= () async {
      try {
        final fresh = await _auth.refresh(stale);
        await _store.write(fresh);
        return _tokens = fresh;
      } finally {
        _refreshing = null;
      }
    }();
  }

  static int _intField(Object? json, String key) =>
      switch (json is Map ? json[key] : null) {
        final num n => n.toInt(),
        final String s when int.tryParse(s) != null => int.parse(s),
        _ => throw GarminUnexpectedResponse('response without $key'),
      };
}

/// Returns the first `.fit` entry of a zip, or [bytes] unchanged if not zipped.
Uint8List extractFit(Uint8List bytes) {
  final isZip = bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B;
  if (!isZip) return bytes;
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final file in archive.files) {
    if (file.isFile && file.name.toLowerCase().endsWith('.fit')) {
      return file.content;
    }
  }
  throw const GarminUnexpectedResponse('download contained no FIT file');
}
