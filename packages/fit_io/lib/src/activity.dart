import 'decoder.dart';
import 'profile.dart';

final _fitEpoch = DateTime.utc(1989, 12, 31);

/// FIT `date_time` (seconds since 1989-12-31T00:00:00Z) to UTC.
/// Values below 0x10000000 are device-relative and yield `null`.
DateTime? fitDateTime(int? seconds) => seconds == null || seconds < 0x10000000
    ? null
    : _fitEpoch.add(Duration(seconds: seconds));

int toFitDateTime(DateTime time) =>
    time.toUtc().difference(_fitEpoch).inSeconds;

double? _scaled(FitMessage m, int field, double scale, [double offset = 0]) {
  final v = m.numValue(field);
  return v == null ? null : v / scale - offset;
}

double? _semicirclesToDegrees(int? v) =>
    v == null ? null : v * 180 / 2147483648;

class FitFileId {
  FitFileId.fromMessage(FitMessage m)
      : type = m.intValue(FitFileIdField.type),
        manufacturer = m.intValue(FitFileIdField.manufacturer),
        product = m.intValue(FitFileIdField.product),
        serialNumber = m.intValue(FitFileIdField.serialNumber),
        timeCreatedRaw = m.intValue(FitFileIdField.timeCreated);

  final int? type;
  final int? manufacturer;
  final int? product;
  final int? serialNumber;
  final int? timeCreatedRaw;

  DateTime? get timeCreated => fitDateTime(timeCreatedRaw);
}

class FitSession {
  FitSession.fromMessage(FitMessage m)
      : sport = m.intValue(FitSessionField.sport),
        subSport = m.intValue(FitSessionField.subSport),
        startTime = fitDateTime(m.intValue(FitSessionField.startTime)),
        timestamp = fitDateTime(m.timestamp),
        totalElapsedTime = _scaled(m, FitSessionField.totalElapsedTime, 1000),
        totalTimerTime = _scaled(m, FitSessionField.totalTimerTime, 1000),
        totalDistance = _scaled(m, FitSessionField.totalDistance, 100),
        avgSpeed = _scaled(m, FitSessionField.enhancedAvgSpeed, 1000) ??
            _scaled(m, FitSessionField.avgSpeed, 1000),
        maxSpeed = _scaled(m, FitSessionField.enhancedMaxSpeed, 1000) ??
            _scaled(m, FitSessionField.maxSpeed, 1000),
        avgHeartRate = m.intValue(FitSessionField.avgHeartRate),
        maxHeartRate = m.intValue(FitSessionField.maxHeartRate),
        totalAscent = m.intValue(FitSessionField.totalAscent);

  final int? sport;
  final int? subSport;
  final DateTime? startTime;
  final DateTime? timestamp;

  /// Seconds, including pauses.
  final double? totalElapsedTime;

  /// Seconds, excluding pauses.
  final double? totalTimerTime;

  /// Metres.
  final double? totalDistance;

  /// m/s
  final double? avgSpeed;
  final double? maxSpeed;
  final int? avgHeartRate;
  final int? maxHeartRate;

  /// Metres.
  final int? totalAscent;
}

class FitLap {
  FitLap.fromMessage(FitMessage m)
      : startTime = fitDateTime(m.intValue(FitLapField.startTime)),
        timestamp = fitDateTime(m.timestamp),
        totalElapsedTime = _scaled(m, FitLapField.totalElapsedTime, 1000),
        totalTimerTime = _scaled(m, FitLapField.totalTimerTime, 1000),
        totalDistance = _scaled(m, FitLapField.totalDistance, 100),
        avgSpeed = _scaled(m, FitLapField.enhancedAvgSpeed, 1000) ??
            _scaled(m, FitLapField.avgSpeed, 1000),
        avgHeartRate = m.intValue(FitLapField.avgHeartRate),
        maxHeartRate = m.intValue(FitLapField.maxHeartRate),
        totalAscent = m.intValue(FitLapField.totalAscent);

  final DateTime? startTime;
  final DateTime? timestamp;
  final double? totalElapsedTime;
  final double? totalTimerTime;
  final double? totalDistance;
  final double? avgSpeed;
  final int? avgHeartRate;
  final int? maxHeartRate;
  final int? totalAscent;
}

class FitRecord {
  FitRecord.fromMessage(FitMessage m)
      : timestamp = fitDateTime(m.timestamp),
        distance = _scaled(m, FitRecordField.distance, 100),
        speed = _scaled(m, FitRecordField.enhancedSpeed, 1000) ??
            _scaled(m, FitRecordField.speed, 1000),
        heartRate = m.intValue(FitRecordField.heartRate),
        cadence = m.intValue(FitRecordField.cadence),
        positionLat = m.intValue(FitRecordField.positionLat),
        positionLong = m.intValue(FitRecordField.positionLong),
        altitude = _scaled(m, FitRecordField.enhancedAltitude, 5, 500) ??
            _scaled(m, FitRecordField.altitude, 5, 500);

  final DateTime? timestamp;

  /// Metres since start.
  final double? distance;

  /// m/s
  final double? speed;
  final int? heartRate;
  final int? cadence;

  /// Semicircles.
  final int? positionLat;
  final int? positionLong;

  /// Metres.
  final double? altitude;

  double? get latitude => _semicirclesToDegrees(positionLat);
  double? get longitude => _semicirclesToDegrees(positionLong);
}

/// Typed view of the activity-relevant messages of a decoded file.
class FitActivity {
  FitActivity.fromFile(FitFile file)
      : fileId = file
            .byNum(FitMesgNum.fileId)
            .map(FitFileId.fromMessage)
            .firstOrNull,
        sessions =
            file.byNum(FitMesgNum.session).map(FitSession.fromMessage).toList(),
        laps = file.byNum(FitMesgNum.lap).map(FitLap.fromMessage).toList(),
        records =
            file.byNum(FitMesgNum.record).map(FitRecord.fromMessage).toList(),
        events =
            file.byNum(FitMesgNum.event).map(FitEvent.fromMessage).toList();

  final FitFileId? fileId;
  final List<FitSession> sessions;
  final List<FitLap> laps;
  final List<FitRecord> records;
  final List<FitEvent> events;

  bool get isActivity => fileId?.type == FitFileType.activity;

  /// Intervals between a timer stop (manual or auto pause) and the next start.
  List<(DateTime, DateTime)> get timerPauses {
    final pauses = <(DateTime, DateTime)>[];
    DateTime? stoppedAt;
    for (final e in events) {
      final t = e.timestamp;
      if (e.event != FitEventValue.timer || t == null) continue;
      if (FitEventType.isStop(e.eventType)) {
        stoppedAt ??= t;
      } else if (e.eventType == FitEventType.start && stoppedAt != null) {
        if (t.isAfter(stoppedAt)) pauses.add((stoppedAt, t));
        stoppedAt = null;
      }
    }
    return pauses;
  }
}

class FitEvent {
  FitEvent.fromMessage(FitMessage m)
      : timestamp = fitDateTime(m.timestamp),
        event = m.intValue(FitEventField.event),
        eventType = m.intValue(FitEventField.eventType),
        data = m.intValue(FitEventField.data);

  final DateTime? timestamp;
  final int? event;
  final int? eventType;
  final int? data;
}
