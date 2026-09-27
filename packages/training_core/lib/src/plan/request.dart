import '../strength.dart';
import '../workout.dart';
import 'dates.dart';

enum Experience { beginner, intermediate, advanced }

final class DayAvailability {
  const DayAvailability({this.available = true, this.maxDuration});

  const DayAvailability.off()
      : available = false,
        maxDuration = null;

  final bool available;

  /// Null means no limit.
  final Duration? maxDuration;
}

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

  final Map<int, DayAvailability> _days;
  final int? longRunWeekday;

  DayAvailability operator [](int weekday) =>
      _days[weekday] ?? const DayAvailability.off();

  List<int> get availableWeekdays => [
        for (var d = DateTime.monday; d <= DateTime.sunday; d++)
          if (this[d].available) d
      ];
}

final class CurrentFitness {
  const CurrentFitness({this.vdot, this.mas, this.lthr});

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
