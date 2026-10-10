import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:fit_io/fit_io.dart';
import 'package:training_core/training_core.dart';

import '../../data/activity_streams.dart';
import '../../data/database.dart';
import '../../data/sports.dart';

typedef LapLoader = Future<List<LapSegment>> Function(Activity activity);

/// Laps of the activity's stored FIT file, if there is one.
Future<List<LapSegment>> loadFitLaps(Activity activity) async {
  final path = activity.fitPath;
  if (path == null) return const [];
  final file = File(path);
  if (!await file.exists()) return const [];
  try {
    final bytes = await file.readAsBytes();
    final fit = FitActivity.fromFile(
      await Isolate.run(() => const FitDecoder().decode(bytes)),
    );
    return [
      for (final l in fit.laps)
        if (l.startTime != null)
          LapSegment(
            startSecond: l.startTime!.difference(activity.startTime).inSeconds,
            durationS: (l.totalElapsedTime ?? l.totalTimerTime ?? 0).round(),
            distanceM: l.totalDistance,
            avgHr: l.avgHeartRate,
          ),
    ];
  } on FitFormatException {
    return const [];
  }
}

/// Pace profile the app currently resolves workout targets with.
Future<PaceProfile?> currentPaceProfile(AppDatabase db) async {
  final fitness =
      await (db.select(db.fitnessSnapshots)
            ..where((t) => t.vdot.isNotNull() | t.masMps.isNotNull())
            ..orderBy([(t) => OrderingTerm.desc(t.date)])
            ..limit(1))
          .getSingleOrNull();
  if (fitness == null) return null;
  final profile = await (db.select(
    db.athleteProfiles,
  )..where((t) => t.id.equals(1))).getSingleOrNull();
  return PaceProfile.fromFitness(
    vdot: fitness.vdot,
    mas: fitness.masMps,
    lthr: profile?.lthr,
  );
}

/// Links recorded activities to planned workouts and evaluates them.
class MatchingService {
  MatchingService(this._db, {LapLoader? lapLoader, DateTime Function()? clock})
    : _lapLoader = lapLoader ?? loadFitLaps,
      _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final LapLoader _lapLoader;
  final DateTime Function() _clock;

  static const lookbackDays = 90;

  /// Shorter recordings are not workouts.
  static const minActivitySeconds = 300;

  /// A planned session moved by a day costs as much as this duration error.
  static const shiftPenaltySeconds = 1800;
  static const shiftWindowDays = 7;

  /// Links unmatched planned workouts to activities (same local day first,
  /// then ±1 day for sessions of the last week), evaluates them against the
  /// plan and re-evaluates linked ones that lacked streams. Returns the number
  /// of new links.
  Future<int> matchAll() async {
    final today = _day(_clock());
    final from = _addDays(today, -lookbackDays);
    final profile = await currentPaceProfile(_db);
    final sizing = profile ?? PaceProfile.fromVdot(45);

    final open =
        await (_db.select(_db.plannedWorkouts)
              ..where(
                (t) =>
                    t.activityId.isNull() &
                    t.status.equalsValue(WorkoutStatus.planned) &
                    t.date.isBiggerOrEqualValue(from) &
                    t.date.isSmallerThanValue(_addDays(today, 1)),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.date)]))
            .get();
    var linked = 0;
    if (open.isNotEmpty) {
      final workouts = {for (final p in open) p.id: ?_parse(p)};
      final planned = [
        for (final p in open)
          if (workouts.containsKey(p.id)) p,
      ];
      final taken = {
        for (final p in await (_db.select(
          _db.plannedWorkouts,
        )..where((t) => t.activityId.isNotNull())).get())
          p.activityId!,
      };
      final activities = [
        for (final a
            in await (_db.select(_db.activities)..where(
                  (t) =>
                      t.startTime.isBiggerOrEqualValue(_addDays(from, -1)) &
                      t.startTime.isSmallerThanValue(_addDays(today, 3)),
                ))
                .get())
          if (!taken.contains(a.id)) a,
      ];

      Duration estimate(PlannedWorkout p) => p.kind == SessionKind.strength
          ? workouts[p.id]!.estimatedDuration(sizing)
          : workouts[p.id]!.estimatedRunDuration(sizing);

      final pairs = _pair(planned, activities, estimate, offsets: const [0]);
      final matchedPlanned = {for (final (p, _) in pairs) p.id};
      final matchedActivities = {for (final (_, a) in pairs) a.id};
      pairs.addAll(
        _pair(
          [
            for (final p in planned)
              if (!matchedPlanned.contains(p.id) &&
                  _day(p.date.toLocal()).isBefore(today) &&
                  _day(p.date.toLocal())
                      .isAfter(_addDays(today, -shiftWindowDays - 1)))
                p,
          ],
          [
            for (final a in activities)
              if (!matchedActivities.contains(a.id)) a,
          ],
          estimate,
          offsets: const [-1, 1],
        ),
      );
      for (final (p, a) in pairs) {
        await _evaluate(p, a, workouts[p.id]!, profile, sizing);
        linked++;
      }
    }
    await _reevaluateLinked(from, profile, sizing);
    return linked;
  }

  Workout? _parse(PlannedWorkout p) {
    try {
      return Workout.fromJson(
        (jsonDecode(p.workoutJson) as Map).cast<String, Object?>(),
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// Greedy assignment by cost: duration error plus a penalty per day shift.
  List<(PlannedWorkout, Activity)> _pair(
    List<PlannedWorkout> planned,
    List<Activity> activities,
    Duration Function(PlannedWorkout) estimate, {
    required List<int> offsets,
  }) {
    final candidates = <({int cost, PlannedWorkout p, Activity a})>[];
    for (final p in planned) {
      final day = _day(p.date.toLocal());
      for (final a in activities) {
        final shift = _daysBetween(day, _day(a.startTime.toLocal()));
        if (!offsets.contains(shift) || !_compatible(p, a)) continue;
        final cost =
            (a.durationS - estimate(p).inSeconds).abs() +
            shift.abs() * shiftPenaltySeconds;
        candidates.add((cost: cost, p: p, a: a));
      }
    }
    candidates.sort((x, y) {
      final c = x.cost.compareTo(y.cost);
      return c != 0 ? c : x.a.startTime.compareTo(y.a.startTime);
    });
    final usedP = <int>{}, usedA = <int>{};
    return [
      for (final c in candidates)
        if (usedP.add(c.p.id) && usedA.add(c.a.id)) (c.p, c.a),
    ];
  }

  bool _compatible(PlannedWorkout p, Activity a) =>
      p.kind == SessionKind.strength
      ? isStrengthSport(a.sport)
      : isRunSport(a.sport) && a.durationS >= minActivitySeconds;

  Future<void> _reevaluateLinked(
    DateTime from,
    PaceProfile? profile,
    PaceProfile sizing,
  ) async {
    final rows =
        await (_db.select(_db.plannedWorkouts)..where(
              (t) =>
                  t.activityId.isNotNull() &
                  t.complianceJson.isNull() &
                  t.kind.equalsValue(SessionKind.strength).not() &
                  t.date.isBiggerOrEqualValue(from),
            ))
            .get();
    for (final p in rows) {
      if (profile == null) break;
      final w = _parse(p);
      if (w == null) continue;
      final a = await (_db.select(
        _db.activities,
      )..where((t) => t.id.equals(p.activityId!))).getSingleOrNull();
      final hasStreams =
          await (_db.select(_db.activityStreams)
                ..where((t) => t.activityId.equals(p.activityId!)))
              .getSingleOrNull() !=
          null;
      if (a != null && hasStreams) await _evaluate(p, a, w, profile, sizing);
    }
  }

  Future<void> _evaluate(
    PlannedWorkout p,
    Activity a,
    Workout w,
    PaceProfile? profile,
    PaceProfile sizing,
  ) async {
    final row = await (_db.select(
      _db.activityStreams,
    )..where((t) => t.activityId.equals(a.id))).getSingleOrNull();
    final samples = row == null
        ? const <Sample>[]
        : ActivityStreamData.fromRow(row).toSamples();

    SessionCompliance? compliance;
    if (p.kind != SessionKind.strength &&
        profile != null &&
        samples.isNotEmpty) {
      final runSteps = w.steps.where((s) => s.kind != StepKind.strength).length;
      compliance = ComplianceEvaluator.evaluate(
        workout: w,
        profile: profile,
        samples: samples,
        laps: runSteps >= 3 ? await _lapLoader(a) : const [],
      );
    }

    final completion =
        compliance?.completion ?? _durationRatio(p, a, w, sizing);
    await (_db.update(
      _db.plannedWorkouts,
    )..where((t) => t.id.equals(p.id))).write(
      PlannedWorkoutsCompanion(
        activityId: Value(a.id),
        status: Value(
          completion >= ComplianceEvaluator.completedCoverage
              ? WorkoutStatus.done
              : WorkoutStatus.partial,
        ),
        complianceJson: Value(
          compliance == null ? null : jsonEncode(compliance.toJson()),
        ),
        updatedAt: Value(_clock()),
      ),
    );
    if (w.test case final type? when samples.isNotEmpty) {
      await _recordTest(a, type, samples);
    }
  }

  double _durationRatio(
    PlannedWorkout p,
    Activity a,
    Workout w,
    PaceProfile sizing,
  ) {
    final planned = p.kind == SessionKind.strength
        ? w.estimatedDuration(sizing)
        : w.estimatedRunDuration(sizing);
    return planned.inSeconds == 0 ? 1 : a.durationS / planned.inSeconds;
  }

  Future<void> _recordTest(
    Activity a,
    TestType type,
    List<Sample> samples,
  ) async {
    final result = TestEvaluator.evaluate(type, samples);
    if (result == null) return;
    final source = switch (type) {
      TestType.timeTrial3k || TestType.timeTrial5k => FitnessSource.timeTrial,
      TestType.halfCooper => FitnessSource.halfCooper,
      TestType.friel30 => FitnessSource.lthrTest,
    };
    final exists =
        await (_db.select(_db.fitnessSnapshots)..where(
              (t) => t.activityId.equals(a.id) & t.source.equalsValue(source),
            ))
            .getSingleOrNull() !=
        null;
    if (exists) return;
    await _db
        .into(_db.fitnessSnapshots)
        .insert(
          FitnessSnapshotsCompanion.insert(
            date: a.startTime,
            source: source,
            distanceM: Value(result.distanceM),
            durationS: Value(result.duration.inSeconds),
            vdot: Value(result.vdot),
            masMps: Value(result.masMps),
            lthr: Value(result.lthr),
            activityId: Value(a.id),
            notes: const Value('Evaluated from planned test'),
          ),
        );
    if (result.lthr case final lthr?) {
      final profile = await _db.watchProfile().first;
      await _db.saveProfile(
        (profile?.toCompanion(false) ?? const AthleteProfilesCompanion())
            .copyWith(lthr: Value(lthr), updatedAt: Value(_clock())),
      );
    }
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  static DateTime _addDays(DateTime d, int days) =>
      DateTime(d.year, d.month, d.day + days);

  static int _daysBetween(DateTime from, DateTime to) => DateTime.utc(
    to.year,
    to.month,
    to.day,
  ).difference(DateTime.utc(from.year, from.month, from.day)).inDays;
}
