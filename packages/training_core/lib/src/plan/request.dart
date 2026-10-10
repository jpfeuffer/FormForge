import '../strength.dart';
import '../workout.dart';
import 'dates.dart';

enum Experience { beginner, intermediate, advanced }

final class DayAvailability {
  const DayAvailability({this.available = true, this.maxDuration});

  const DayAvailability.off()
      : available = false,
        maxDuration = null;

  factory DayAvailability.fromJson(Map<String, Object?> json) =>
      DayAvailability(
          available: json['available'] as bool? ?? true,
          maxDuration: _durationFromJson(json['maxDurationS']));

  final bool available;

  /// Null means no limit.
  final Duration? maxDuration;

  Map<String, Object?> toJson() => {
        'available': available,
        'maxDurationS': maxDuration?.inSeconds,
      };
}

Duration? _durationFromJson(Object? seconds) =>
    seconds == null ? null : Duration(seconds: seconds as int);

String _dateToJson(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime? _dateFromJson(Object? s) =>
    s == null ? null : dateOnly(DateTime.parse(s as String));

final class WeeklyAvailability {
  /// [days] keyed by [DateTime.monday]..[DateTime.sunday]; missing days are off.
  WeeklyAvailability(Map<int, DayAvailability> days, {this.longRunWeekday})
      : _days = Map.unmodifiable(days) {
    if (days.keys.any((d) => d < DateTime.monday || d > DateTime.sunday)) {
      throw ArgumentError('Weekdays must be 1..7');
    }
  }

  factory WeeklyAvailability.on(Iterable<int> weekdays,
          {Duration? maxDuration, int? longRunWeekday}) =>
      WeeklyAvailability({
        for (final d in weekdays) d: DayAvailability(maxDuration: maxDuration)
      }, longRunWeekday: longRunWeekday);

  factory WeeklyAvailability.fromJson(Map<String, Object?> json) =>
      WeeklyAvailability({
        for (final e in (json['days'] as Map<String, Object?>).entries)
          int.parse(e.key):
              DayAvailability.fromJson(e.value as Map<String, Object?>)
      }, longRunWeekday: json['longRunWeekday'] as int?);

  final Map<int, DayAvailability> _days;
  final int? longRunWeekday;

  Map<String, Object?> toJson() => {
        'days': {
          for (final d in availableWeekdays) '$d': this[d].toJson(),
        },
        'longRunWeekday': longRunWeekday,
      };

  DayAvailability operator [](int weekday) =>
      _days[weekday] ?? const DayAvailability.off();

  List<int> get availableWeekdays => [
        for (var d = DateTime.monday; d <= DateTime.sunday; d++)
          if (this[d].available) d
      ];
}

final class CurrentFitness {
  const CurrentFitness({this.vdot, this.mas, this.lthr});

  factory CurrentFitness.fromJson(Map<String, Object?> json) => CurrentFitness(
        vdot: (json['vdot'] as num?)?.toDouble(),
        mas: (json['mas'] as num?)?.toDouble(),
        lthr: (json['lthr'] as num?)?.toDouble(),
      );

  Map<String, Object?> toJson() => {'vdot': vdot, 'mas': mas, 'lthr': lthr};

  final double? vdot;

  /// Maximal aerobic speed, m/s.
  final double? mas;

  /// Lactate-threshold heart rate, bpm.
  final double? lthr;
}

final class PlanRequest {
  PlanRequest({
    required this.goalMeters,
    this.raceDate,
    this.weeks,
    this.targetTime,
    required DateTime startDate,
    required this.fitness,
    required this.availability,
    this.currentWeeklyDuration,
    this.currentWeeklyKm,
    this.longestRecentRun,
    this.longestRecentRunKm,
    this.experience = Experience.intermediate,
    this.strength = const StrengthGoal.none(),
    this.preferredTests = const [],
  }) : startDate = dateOnly(startDate) {
    if (goalMeters <= 0 || goalMeters > 110000) {
      throw ArgumentError.value(goalMeters, 'goalMeters', 'must be 0–110 km');
    }
    if (raceDate == null && weeks == null) {
      throw ArgumentError('Either raceDate or weeks is required');
    }
    if (weekCount < 2) {
      throw ArgumentError('Plan must span at least 2 weeks');
    }
    if (fitness.vdot == null && fitness.mas == null) {
      throw ArgumentError('fitness needs vdot or mas');
    }
    if (availability.availableWeekdays.isEmpty) {
      throw ArgumentError('No available training days');
    }
  }

  static const version = 1;

  factory PlanRequest.fromJson(Map<String, Object?> json) {
    final v = json['v'];
    if (v != version) {
      throw FormatException('Unsupported plan request version', v);
    }
    return PlanRequest(
      goalMeters: (json['goalMeters'] as num).toDouble(),
      raceDate: _dateFromJson(json['raceDate']),
      weeks: json['weeks'] as int?,
      targetTime: _durationFromJson(json['targetTimeS']),
      startDate: _dateFromJson(json['startDate'])!,
      fitness:
          CurrentFitness.fromJson(json['fitness'] as Map<String, Object?>),
      availability: WeeklyAvailability.fromJson(
          json['availability'] as Map<String, Object?>),
      currentWeeklyDuration: _durationFromJson(json['currentWeeklyDurationS']),
      currentWeeklyKm: (json['currentWeeklyKm'] as num?)?.toDouble(),
      longestRecentRun: _durationFromJson(json['longestRecentRunS']),
      longestRecentRunKm: (json['longestRecentRunKm'] as num?)?.toDouble(),
      experience: Experience.values.byName(json['experience'] as String),
      strength: json['strength'] == null
          ? const StrengthGoal.none()
          : StrengthGoal.fromJson(json['strength'] as Map<String, Object?>),
      preferredTests: [
        for (final t in (json['preferredTests'] as List?) ?? const [])
          TestType.values.byName(t as String)
      ],
    );
  }

  Map<String, Object?> toJson() => {
        'v': version,
        'goalMeters': goalMeters,
        'raceDate': raceDate == null ? null : _dateToJson(raceDate!),
        'weeks': weeks,
        'targetTimeS': targetTime?.inSeconds,
        'startDate': _dateToJson(startDate),
        'fitness': fitness.toJson(),
        'availability': availability.toJson(),
        'currentWeeklyDurationS': currentWeeklyDuration?.inSeconds,
        'currentWeeklyKm': currentWeeklyKm,
        'longestRecentRunS': longestRecentRun?.inSeconds,
        'longestRecentRunKm': longestRecentRunKm,
        'experience': experience.name,
        'strength': strength.toJson(),
        'preferredTests': [for (final t in preferredTests) t.name],
      };

  /// Copy with new [fitness] (e.g. after a test), all else unchanged.
  PlanRequest withFitness(CurrentFitness fitness) => PlanRequest(
        goalMeters: goalMeters,
        raceDate: raceDate,
        weeks: weeks,
        targetTime: targetTime,
        startDate: startDate,
        fitness: fitness,
        availability: availability,
        currentWeeklyDuration: currentWeeklyDuration,
        currentWeeklyKm: currentWeeklyKm,
        longestRecentRun: longestRecentRun,
        longestRecentRunKm: longestRecentRunKm,
        experience: experience,
        strength: strength,
        preferredTests: preferredTests,
      );

  final double goalMeters;

  /// Takes precedence over [weeks].
  final DateTime? raceDate;
  final int? weeks;
  final Duration? targetTime;
  final DateTime startDate;
  final CurrentFitness fitness;
  final WeeklyAvailability availability;
  final Duration? currentWeeklyDuration;
  final double? currentWeeklyKm;
  final Duration? longestRecentRun;
  final double? longestRecentRunKm;
  final Experience experience;
  final StrengthGoal strength;
  final List<TestType> preferredTests;

  /// Days from [startDate] to [raceDate].
  int? get raceDayOffset =>
      raceDate == null ? null : daysBetween(startDate, raceDate!);

  int get weekCount => switch (raceDayOffset) {
        final o? => o < 0 ? 0 : o ~/ 7 + 1,
        null => weeks!,
      };
}
