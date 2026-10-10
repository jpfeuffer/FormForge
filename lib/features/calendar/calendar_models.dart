import 'dart:convert';

import 'package:training_core/training_core.dart';

import '../../data/database.dart';
import 'strength_codec.dart';

DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

DateTime weekStartOf(DateTime d) => addDays(d, 1 - d.weekday);

bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Used for estimates until a test or race provides a real pace profile.
final fallbackPaceProfile = PaceProfile.fromVdot(35);

enum GarminSync { none, synced, changed }

/// A planned workout row with its decoded workout.
final class CalendarEntry {
  CalendarEntry(this.row)
    : workout = _decode(row),
      strength = decodeStrength(row.strengthJson);

  final PlannedWorkout row;
  final Workout workout;
  final StrengthSession? strength;

  int get id => row.id;
  DateTime get day => dayOf(row.date);
  SessionKind get kind => row.kind;
  bool get isSkipped => row.status == WorkoutStatus.skipped;
  bool get hasStrength => workout.sport != Sport.run;

  List<FocusArea> get focusAreas => workout.focusAreas.isNotEmpty
      ? workout.focusAreas
      : strength?.focusAreas ?? const [];

  bool isMissed(DateTime today) =>
      row.status == WorkoutStatus.planned && day.isBefore(today);

  GarminSync get garmin {
    if (row.garminScheduleId == null || row.garminSyncedHash == null) {
      return GarminSync.none;
    }
    final at = row.garminSyncedAt;
    return at != null && row.updatedAt.isAfter(at)
        ? GarminSync.changed
        : GarminSync.synced;
  }

  ScheduledItem toItem(PaceProfile p) => ScheduledItem(
    id: id,
    date: day,
    kind: kind,
    isKey: row.isKey,
    heavyStrength: strength?.isHeavyLowerBody ?? false,
    estimatedDuration: workout.estimatedDuration(p),
    runDuration: workout.estimatedRunDuration(p),
  );

  static Workout _decode(PlannedWorkout row) {
    try {
      return Workout.fromJson(
        jsonDecode(row.workoutJson) as Map<String, Object?>,
      );
    } on Object {
      return Workout(
        sport: switch (row.kind) {
          SessionKind.strength => Sport.strength,
          SessionKind.combined => Sport.combined,
          _ => Sport.run,
        },
        title: row.title,
        elements: const [],
      );
    }
  }
}

typedef DateRange = ({DateTime from, DateTime to});

typedef Volume = ({Duration run, double meters});

/// Entries of a loaded date range plus the rule check over them.
final class CalendarData {
  CalendarData(Iterable<PlannedWorkout> rows, this.profile, this.availability)
    : entries = [for (final r in rows) CalendarEntry(r)]..sort(_byTime) {
    for (final e in entries) {
      (_byDay[e.day] ??= []).add(e);
    }
    _items = [
      for (final e in entries)
        if (!e.isSkipped) e.toItem(profile),
    ];
    issues = ScheduleChecker.check(_items, availability: availability);
  }

  final PaceProfile profile;
  final WeeklyAvailability? availability;
  final List<CalendarEntry> entries;
  final _byDay = <DateTime, List<CalendarEntry>>{};
  late final List<ScheduledItem> _items;
  late final List<ScheduleIssue> issues;

  List<CalendarEntry> on(DateTime d) => _byDay[dayOf(d)] ?? const [];

  CalendarEntry? byId(int id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  List<ScheduleIssue> issuesOn(DateTime d) => [
    for (final i in issues)
      if (!i.weekly && sameDay(i.date, d)) i,
  ];

  List<ScheduleIssue> issuesFor(int itemId) => [
    for (final i in issues)
      if (i.itemId == itemId) i,
  ];

  List<ScheduleIssue> weeklyIssues(DateTime weekStart) => [
    for (final i in issues)
      if (i.weekly && sameDay(i.date, weekStart)) i,
  ];

  /// Issues that moving [id] to [to] would introduce.
  List<ScheduleIssue> previewMove(int id, DateTime to) {
    final moved = ScheduleChecker.check([
      for (final i in _items) i.id == id ? i.moved(to) : i,
    ], availability: availability);
    final existing = {for (final i in issues) _issueKey(i)};
    return [
      for (final i in moved)
        if (!existing.contains(_issueKey(i))) i,
    ];
  }

  Volume volume(DateTime from, DateTime to) {
    var run = Duration.zero;
    var meters = 0.0;
    for (final e in entries) {
      if (e.isSkipped || e.day.isBefore(from) || e.day.isAfter(to)) continue;
      run += e.workout.estimatedRunDuration(profile);
      meters += e.workout.estimatedDistance(profile);
    }
    return (run: run, meters: meters);
  }

  static String _issueKey(ScheduleIssue i) => '${i.code}|${i.date}|${i.itemId}';

  static int _byTime(CalendarEntry a, CalendarEntry b) {
    final c = a.day.compareTo(b.day);
    if (c != 0) return c;
    final t = (a.row.startMinute ?? 24 * 60).compareTo(
      b.row.startMinute ?? 24 * 60,
    );
    return t != 0 ? t : a.id.compareTo(b.id);
  }
}

String formatMinutes(Duration d) {
  final m = (d.inSeconds / 60).round();
  return m >= 60
      ? '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')} h'
      : '$m min';
}

String formatKmShort(double meters) =>
    '${(meters / 1000).toStringAsFixed(meters >= 100000 ? 0 : 1)} km';

String formatClock(int minuteOfDay) =>
    '${(minuteOfDay ~/ 60).toString().padLeft(2, '0')}:${(minuteOfDay % 60).toString().padLeft(2, '0')}';
