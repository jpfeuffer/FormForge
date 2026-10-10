import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:training_core/training_core.dart';

import '../../data/database.dart';
import 'garmin_client.dart';
import 'garmin_exceptions.dart';
import 'workout_mapper.dart';

Workout _parseWorkout(PlannedWorkout row) => Workout.fromJson(
  (jsonDecode(row.workoutJson) as Map).cast<String, Object?>(),
);

Map<String, Object?> garminPayload(PlannedWorkout row, PaceProfile? profile) =>
    garminWorkoutJson(_parseWorkout(row), profile: profile, title: row.title);

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Changes whenever the workout, its date or its resolved paces change.
String syncHash(PlannedWorkout row, PaceProfile? profile) {
  final input = jsonEncode({
    'workout': garminPayload(row, profile),
    'date': _ymd(row.date),
    'startMinute': row.startMinute,
  });
  return sha256.convert(utf8.encode(input)).toString();
}

class PushFailure {
  const PushFailure(this.row, this.reason);
  final PlannedWorkout row;
  final String reason;
}

class PushSummary {
  var created = 0;
  var updated = 0;
  var unchanged = 0;
  var removed = 0;
  final failed = <PushFailure>[];

  /// Set when the run stopped early (rate limit, logged out).
  String? abortReason;

  String get message => [
    'Garmin: $created new, $updated updated, $unchanged unchanged',
    if (removed > 0) '$removed removed',
    if (failed.isNotEmpty)
      '${failed.length} failed (${failed.map((f) => '${f.row.title}: ${f.reason}').join('; ')})',
    ?abortReason,
  ].join(' · ');
}

class OrphanCleanup {
  var removed = 0;
  final failed = <String>[];
  String? abortReason;

  String get message => [
    removed == 0
        ? 'No orphaned FormForge workouts found'
        : 'Removed $removed orphaned FormForge workouts',
    if (failed.isNotEmpty) '${failed.length} failed (${failed.join('; ')})',
    ?abortReason,
  ].join(' · ');
}

enum _Outcome { created, updated, unchanged, removed }

/// Pushes planned workouts into the Garmin calendar (and from there to the watch).
class GarminPushService {
  GarminPushService(
    this._db,
    this._client, {
    PaceProfile? Function()? paceProfile,
    this.delay = const Duration(milliseconds: 400),
    DateTime Function()? clock,
  }) : _paceProfile = paceProfile ?? (() => null),
       _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final GarminClient _client;
  final PaceProfile? Function() _paceProfile;
  final DateTime Function() _clock;

  /// Pause between consecutive requests, to stay below Garmin's rate limits.
  final Duration delay;

  /// Syncs planned rows in `[from, to]` (whole days); stops on rate limiting.
  Future<PushSummary> pushRange(
    DateTime from,
    DateTime to, {
    void Function(int done, int total)? onProgress,
  }) async {
    final summary = PushSummary();
    final today = _day(_clock());
    final rows = await _rowsBetween(from, to);
    final todo = [
      for (final r in rows)
        if (r.status == WorkoutStatus.planned && !r.date.isBefore(today) ||
            r.status == WorkoutStatus.skipped && _hasGarminIds(r))
          r,
    ];
    final profile = _paceProfile();
    var paused = false;
    for (final (i, row) in todo.indexed) {
      if (paused) await _pause();
      try {
        final outcome = await _sync(row, profile);
        paused = outcome != _Outcome.unchanged;
        switch (outcome) {
          case _Outcome.created:
            summary.created++;
          case _Outcome.updated:
            summary.updated++;
          case _Outcome.unchanged:
            summary.unchanged++;
          case _Outcome.removed:
            summary.removed++;
        }
      } on GarminException catch (e) {
        summary.failed.add(PushFailure(row, e.message));
        if (e is GarminRateLimited || e is GarminNotConnected) {
          summary.abortReason = 'Stopped: ${e.message}';
          break;
        }
        paused = true;
      } on Object catch (e) {
        summary.failed.add(PushFailure(row, '$e'));
      }
      onProgress?.call(i + 1, todo.length);
    }
    return summary;
  }

  /// Unschedules and deletes the Garmin copy of [row] and forgets its ids.
  Future<void> removeFromGarmin(PlannedWorkout row) async {
    final scheduleId = _id(row.garminScheduleId);
    final workoutId = _id(row.garminWorkoutId);
    if (scheduleId != null) {
      await _ignoreMissing(() => _client.unscheduleWorkout(scheduleId));
    }
    if (workoutId != null) {
      await _ignoreMissing(() => _client.deleteWorkout(workoutId));
    }
    await _writeIds(row.id, null);
  }

  /// Removes FormForge workouts from the Garmin calendar that no database row
  /// refers to, e.g. because the row was deleted or moved without telling Garmin.
  Future<OrphanCleanup> cleanupOrphans({
    required DateTime from,
    required DateTime to,
  }) async {
    final result = OrphanCleanup();
    final rows = await _db.select(_db.plannedWorkouts).get();
    final knownSchedules = {for (final r in rows) ?_id(r.garminScheduleId)};
    final knownWorkouts = {for (final r in rows) ?_id(r.garminWorkoutId)};
    final first = _ymd(from);
    final last = _ymd(to);

    var requested = false;
    var month = DateTime(from.year, from.month);
    final end = _day(to);
    while (!month.isAfter(end)) {
      if (requested) await _pause();
      requested = true;
      try {
        final calendar = await _client.calendarMonth(month.year, month.month);
        for (final item in _calendarWorkouts(calendar)) {
          final inRange =
              item.date.compareTo(first) >= 0 && item.date.compareTo(last) <= 0;
          if (!inRange || knownSchedules.contains(item.scheduleId)) continue;
          await _pause();
          try {
            await _ignoreMissing(
              () => _client.unscheduleWorkout(item.scheduleId),
            );
            if (!knownWorkouts.contains(item.workoutId)) {
              await _ignoreMissing(() => _client.deleteWorkout(item.workoutId));
            }
            result.removed++;
          } on GarminRateLimited {
            rethrow;
          } on GarminException catch (e) {
            result.failed.add('${item.title}: ${e.message}');
          }
        }
      } on GarminException catch (e) {
        result.abortReason = 'Stopped: ${e.message}';
        break;
      }
      month = DateTime(month.year, month.month + 1);
    }
    return result;
  }

  Future<_Outcome> _sync(PlannedWorkout row, PaceProfile? profile) async {
    if (row.status == WorkoutStatus.skipped) {
      await removeFromGarmin(row);
      return _Outcome.removed;
    }
    final hash = syncHash(row, profile);
    final oldSchedule = _id(row.garminScheduleId);
    final oldWorkout = _id(row.garminWorkoutId);
    if (oldSchedule != null &&
        oldWorkout != null &&
        row.garminSyncedHash == hash) {
      return _Outcome.unchanged;
    }

    // New copy first: if anything fails the old one stays valid.
    final workoutId = await _client.createWorkout(garminPayload(row, profile));
    final int scheduleId;
    try {
      scheduleId = await _client.scheduleWorkout(workoutId, row.date);
    } on GarminException {
      await _bestEffort(() => _client.deleteWorkout(workoutId));
      rethrow;
    }
    await _writeIds(row.id, (
      workoutId: workoutId,
      scheduleId: scheduleId,
      hash: hash,
      at: _clock(),
    ));

    // Leftovers are picked up by [cleanupOrphans] since the row no longer points to them.
    if (oldSchedule != null) {
      await _bestEffort(() => _client.unscheduleWorkout(oldSchedule));
    }
    if (oldWorkout != null) {
      await _bestEffort(() => _client.deleteWorkout(oldWorkout));
    }
    return oldSchedule == null && oldWorkout == null
        ? _Outcome.created
        : _Outcome.updated;
  }

  Future<List<PlannedWorkout>> _rowsBetween(DateTime from, DateTime to) {
    final start = _day(from);
    final end = DateTime(to.year, to.month, to.day + 1);
    return (_db.select(_db.plannedWorkouts)
          ..where(
            (t) =>
                t.date.isBiggerOrEqualValue(start) &
                t.date.isSmallerThanValue(end),
          )
          ..orderBy([
            (t) => OrderingTerm.asc(t.date),
            (t) => OrderingTerm.asc(t.startMinute),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .get();
  }

  Future<void> _writeIds(
    int rowId,
    ({int workoutId, int scheduleId, String hash, DateTime at})? ids,
  ) =>
      (_db.update(_db.plannedWorkouts)..where((t) => t.id.equals(rowId))).write(
        PlannedWorkoutsCompanion(
          garminWorkoutId: Value(ids?.workoutId.toString()),
          garminScheduleId: Value(ids?.scheduleId.toString()),
          garminSyncedHash: Value(ids?.hash),
          garminSyncedAt: Value(ids?.at),
        ),
      );

  Future<void> _pause() async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  static bool _hasGarminIds(PlannedWorkout r) =>
      r.garminScheduleId != null || r.garminWorkoutId != null;

  static int? _id(Object? value) => switch (value) {
    final num n => n.toInt(),
    final String s => int.tryParse(s),
    _ => null,
  };

  static Iterable<_CalendarWorkout> _calendarWorkouts(
    Map<String, Object?> calendar,
  ) sync* {
    final items = calendar['calendarItems'];
    if (items is! List) return;
    for (final raw in items) {
      if (raw is! Map || raw['itemType'] != 'workout') continue;
      final title = raw['title'];
      // The calendar item `id` is the workout schedule id.
      final scheduleId = _id(raw['workoutScheduleId'] ?? raw['id']);
      final workoutId = _id(raw['workoutId']);
      final date = raw['date'];
      if (title is! String || !isFormForgeWorkoutName(title)) continue;
      if (scheduleId == null || workoutId == null || date is! String) continue;
      yield _CalendarWorkout(title, date, scheduleId, workoutId);
    }
  }

  /// 404 means it is already gone, which is what we want.
  static Future<void> _ignoreMissing(Future<void> Function() call) async {
    try {
      await call();
    } on GarminApiException catch (e) {
      if (e.statusCode != 404) rethrow;
    }
  }

  static Future<void> _bestEffort(Future<void> Function() call) async {
    try {
      await _ignoreMissing(call);
    } on GarminException {
      // Orphan cleanup handles what is left behind.
    }
  }
}

class _CalendarWorkout {
  const _CalendarWorkout(
    this.title,
    this.date,
    this.scheduleId,
    this.workoutId,
  );
  final String title;
  final String date;
  final int scheduleId;
  final int workoutId;
}
