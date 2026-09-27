import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:training_core/training_core.dart';

import 'database.dart';

const _missingPosition = 0x7FFFFFFF;

/// Unpacked per-second streams of one activity; `null` lists are absent.
class ActivityStreamData {
  ActivityStreamData({
    required this.seconds,
    this.speed,
    this.heartRate,
    this.distance,
    this.latitude,
    this.longitude,
    this.altitude,
  }) : assert(
         [
           speed,
           heartRate,
           distance,
           latitude,
           longitude,
           altitude,
         ].every((s) => s == null || s.length == seconds.length),
       );

  factory ActivityStreamData.fromRow(ActivityStream row) => ActivityStreamData(
    seconds: List<int>.from(_unpackInt32(row.seconds, null)),
    speed: _maybe(row.speed, _unpackFloat32),
    heartRate: _maybe(row.heartRate, _unpackUint8),
    distance: _maybe(row.distance, _unpackFloat32),
    latitude: _maybe(row.latitude, (b) => _unpackInt32(b, _missingPosition)),
    longitude: _maybe(row.longitude, (b) => _unpackInt32(b, _missingPosition)),
    altitude: _maybe(row.altitude, _unpackFloat32),
  );

  /// Seconds since activity start.
  final List<int> seconds;

  /// m/s
  final List<double?>? speed;

  /// bpm
  final List<int?>? heartRate;

  /// Metres since start.
  final List<double?>? distance;

  /// Semicircles (degrees = value * 180 / 2^31).
  final List<int?>? latitude;
  final List<int?>? longitude;

  /// Metres.
  final List<double?>? altitude;

  int get length => seconds.length;

  List<Sample> toSamples() => [
    for (var i = 0; i < length; i++)
      Sample(second: seconds[i], speed: speed?[i], hr: heartRate?[i]),
  ];

  ActivityStreamsCompanion toCompanion(
    int activityId,
  ) => ActivityStreamsCompanion(
    activityId: Value(activityId),
    sampleCount: Value(length),
    seconds: Value(_packInt32(seconds, 0)),
    speed: Value(_pack(speed, _packFloat32)),
    heartRate: Value(_pack(heartRate, _packUint8)),
    distance: Value(_pack(distance, _packFloat32)),
    latitude: Value(_pack(latitude, (v) => _packInt32(v, _missingPosition))),
    longitude: Value(_pack(longitude, (v) => _packInt32(v, _missingPosition))),
    altitude: Value(_pack(altitude, _packFloat32)),
  );
}

Uint8List? _pack<T>(List<T?>? values, Uint8List Function(List<T?>) pack) =>
    values == null || values.every((v) => v == null) ? null : pack(values);

List<T?>? _maybe<T>(Uint8List? bytes, List<T?> Function(Uint8List) unpack) =>
    bytes == null ? null : unpack(bytes);

Uint8List _packInt32(List<int?> values, int missing) {
  final data = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    data.setInt32(i * 4, values[i] ?? missing, Endian.little);
  }
  return data.buffer.asUint8List();
}

List<int?> _unpackInt32(Uint8List bytes, int? missing) {
  final data = ByteData.sublistView(bytes);
  return [
    for (var i = 0; i < bytes.length ~/ 4; i++)
      switch (data.getInt32(i * 4, Endian.little)) {
        final v when v == missing => null,
        final v => v,
      },
  ];
}

Uint8List _packFloat32(List<double?> values) {
  final data = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    data.setFloat32(i * 4, values[i] ?? double.nan, Endian.little);
  }
  return data.buffer.asUint8List();
}

List<double?> _unpackFloat32(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return [
    for (var i = 0; i < bytes.length ~/ 4; i++)
      switch (data.getFloat32(i * 4, Endian.little)) {
        final v when v.isNaN => null,
        final v => v,
      },
  ];
}

Uint8List _packUint8(List<int?> values) =>
    Uint8List.fromList([for (final v in values) (v ?? 0).clamp(0, 255)]);

List<int?> _unpackUint8(Uint8List bytes) => [
  for (final v in bytes) v == 0 ? null : v,
];
