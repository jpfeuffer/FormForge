import 'package:drift/drift.dart';

import 'activity_streams.dart';
import 'database.dart';
import 'sports.dart';

/// Detects the same workout arriving from two sources (Garmin and a FIT file)
/// and folds the duplicate into one row.
class ActivityMerger {
  ActivityMerger(this._db);

  final AppDatabase _db;

  /// Start times closer than this, with the same sport, are one activity.
  static const startTolerance = Duration(minutes: 2);

  static bool sameSport(String a, String b) =>
      a == b || (isRunSport(a) && isRunSport(b));

  /// A row of another [ActivitySource] than [source] that is the same workout.
  Future<Activity?> findTwin({
    required ActivitySource source,
    required String sport,
    required DateTime start,
    int? excludeId,
  }) async {
    final rows =
        await (_db.select(_db.activities)
              ..where(
                (t) =>
                    t.startTime.isBetweenValues(
                      start.subtract(startTolerance),
                      start.add(startTolerance),
                    ) &
                    t.source.equalsValue(source).not(),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.id)]))
            .get();
    return rows
        .where((r) => r.id != excludeId && sameSport(r.sport, sport))
        .firstOrNull;
  }

  /// Moves streams, FIT file and references from [dropId] to [keepId], then
  /// deletes [dropId]. [keepId]'s own streams and file win.
  Future<void> merge({required int keepId, required int dropId}) =>
      _db.transaction(() async {
        final keep = await (_db.select(
          _db.activities,
        )..where((t) => t.id.equals(keepId))).getSingle();
        final drop = await (_db.select(
          _db.activities,
        )..where((t) => t.id.equals(dropId))).getSingle();

        final keepHasStreams = await _hasStreams(keepId);
        if (keepHasStreams) {
          await (_db.delete(
            _db.activityStreams,
          )..where((t) => t.activityId.equals(dropId))).go();
        } else {
          await (_db.update(_db.activityStreams)
                ..where((t) => t.activityId.equals(dropId)))
              .write(ActivityStreamsCompanion(activityId: Value(keepId)));
        }
        if (keep.fitPath == null && drop.fitPath != null) {
          await (_db.update(_db.activities)..where((t) => t.id.equals(keepId)))
              .write(ActivitiesCompanion(fitPath: Value(drop.fitPath)));
        }
        if (keep.workoutName == null && drop.workoutName != null) {
          await (_db.update(_db.activities)..where((t) => t.id.equals(keepId)))
              .write(
                ActivitiesCompanion(
                  workoutName: Value(drop.workoutName),
                  workoutChecked: const Value(true),
                ),
              );
        }
        await (_db.update(_db.fitnessSnapshots)
              ..where((t) => t.activityId.equals(dropId)))
            .write(FitnessSnapshotsCompanion(activityId: Value(keepId)));
        await (_db.update(_db.plannedWorkouts)
              ..where((t) => t.activityId.equals(dropId)))
            .write(PlannedWorkoutsCompanion(activityId: Value(keepId)));
        await (_db.delete(
          _db.activities,
        )..where((t) => t.id.equals(dropId))).go();
      });

  /// Gives [activityId] the streams and FIT file it lacks; false if it had both.
  /// [workoutName] is the name found in that FIT file (null if it has none).
  Future<bool> enrich(
    int activityId, {
    ActivityStreamData? streams,
    String? fitPath,
    String? workoutName,
  }) => _db.transaction(() async {
    var changed = false;
    if (streams != null && !await _hasStreams(activityId)) {
      await _db
          .into(_db.activityStreams)
          .insert(streams.toCompanion(activityId));
      changed = true;
    }
    if (fitPath != null) {
      final updated =
          await (_db.update(_db.activities)
                ..where((t) => t.id.equals(activityId) & t.fitPath.isNull()))
              .write(
                ActivitiesCompanion(
                  fitPath: Value(fitPath),
                  workoutName: Value(workoutName),
                  workoutChecked: const Value(true),
                ),
              );
      changed |= updated > 0;
    }
    return changed;
  });

  Future<bool> _hasStreams(int activityId) async =>
      await (_db.select(
        _db.activityStreams,
      )..where((t) => t.activityId.equals(activityId))).getSingleOrNull() !=
      null;
}
