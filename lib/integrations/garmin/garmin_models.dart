import 'package:training_core/training_core.dart';

class GarminProfile {
  const GarminProfile({
    required this.displayName,
    this.fullName,
    this.profileId,
  });

  factory GarminProfile.fromJson(Map<String, Object?> json) => GarminProfile(
    displayName: json['displayName'] as String? ?? '',
    fullName: json['fullName'] as String?,
    profileId: (json['profileId'] as num?)?.toInt(),
  );

  /// Garmin's (often opaque) user handle used in some API paths.
  final String displayName;
  final String? fullName;
  final int? profileId;

  String get label => (fullName?.trim().isNotEmpty ?? false)
      ? fullName!.trim()
      : displayName.isNotEmpty
      ? displayName
      : 'Garmin user';
}

class GarminActivitySummary {
  const GarminActivitySummary({
    required this.activityId,
    required this.typeKey,
    required this.startTime,
    required this.durationS,
    this.name,
    this.distanceM,
    this.avgHr,
    this.maxHr,
    this.avgSpeed,
  });

  factory GarminActivitySummary.fromJson(Map<String, Object?> json) {
    final type = json['activityType'];
    return GarminActivitySummary(
      activityId: (json['activityId'] as num).toInt(),
      name: json['activityName'] as String?,
      typeKey: (type is Map ? type['typeKey'] as String? : null) ?? 'other',
      startTime: _startTime(json),
      durationS: (json['duration'] as num?)?.toDouble() ?? 0,
      distanceM: (json['distance'] as num?)?.toDouble(),
      avgHr: (json['averageHR'] as num?)?.toDouble(),
      maxHr: (json['maxHR'] as num?)?.toDouble(),
      avgSpeed: (json['averageSpeed'] as num?)?.toDouble(),
    );
  }

  final int activityId;
  final String? name;

  /// Garmin activityType.typeKey, e.g. `running`, `strength_training`.
  final String typeKey;

  /// UTC.
  final DateTime startTime;
  final double durationS;
  final double? distanceM;
  final double? avgHr;
  final double? maxHr;

  /// m/s
  final double? avgSpeed;

  static DateTime _startTime(Map<String, Object?> json) {
    // startTimeGMT is "yyyy-MM-dd HH:mm:ss" without a zone designator.
    if (json['startTimeGMT'] case final String gmt) {
      final parsed = DateTime.tryParse('${gmt.replaceFirst(' ', 'T')}Z');
      if (parsed != null) return parsed;
    }
    if (json['beginTimestamp'] case final num ms) {
      return DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: true);
    }
    throw FormatException('Activity ${json['activityId']} has no start time');
  }
}

/// Maps the positional `activityDetailMetrics` of
/// `activity-service/activity/{id}/details` to [Sample]s via `metricDescriptors`.
List<Sample> samplesFromDetails(Map<String, Object?> details) {
  final index = <String, int>{
    for (final d in (details['metricDescriptors'] as List?) ?? const [])
      if (d case {'key': final String key, 'metricsIndex': final int i}
          when i >= 0)
        key: i,
  };
  double? metric(List<Object?> values, String key) {
    final i = index[key];
    return i == null || i >= values.length
        ? null
        : (values[i] as num?)?.toDouble();
  }

  final samples = <Sample>[];
  double? firstTimestamp;
  for (final row in (details['activityDetailMetrics'] as List?) ?? const []) {
    final values = (row as Map)['metrics'] as List? ?? const [];
    // Wall-clock time so pauses stay visible as gaps; timer time last.
    var second = metric(values, 'sumElapsedDuration');
    if (second == null) {
      final ts = metric(values, 'directTimestamp');
      if (ts != null) {
        firstTimestamp ??= ts;
        second = (ts - firstTimestamp) / 1000;
      }
    }
    second ??= metric(values, 'sumDuration');
    if (second == null) continue;
    samples.add(
      Sample(
        second: second.round(),
        speed: metric(values, 'directSpeed'),
        hr: metric(values, 'directHeartRate')?.round(),
      ),
    );
  }
  return samples;
}
