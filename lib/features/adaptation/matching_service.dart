import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show max;

import 'package:drift/drift.dart';
import 'package:fit_io/fit_io.dart';
import 'package:training_core/training_core.dart';

import '../../data/activity_streams.dart';
import '../../data/database.dart';
import '../../data/sports.dart';

typedef LapLoader = Future<List<LapSegment>> Function(Activity activity);
typedef WorkoutNameLoader = Future<String?> Function(Activity activity);

Future<FitActivity?> _decodeFit(Activity activity) async {
  final path = activity.fitPath;
  if (path == null) return null;
  final file = File(path);
  if (!await file.exists()) return null;
  try {
    final bytes = await file.readAsBytes();
    return FitActivity.fromFile(
      await Isolate.run(() => const FitDecoder().decode(bytes)),
    );
  } on FitFormatException {
    return null;
  }
}

/// Laps of the activity's stored FIT file, if there is one.
Future<List<LapSegment>> loadFitLaps(Activity activity) async {
  final fit = await _decodeFit(activity);
  if (fit == null) return const [];
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
}

/// Name of the workout the watch executed, from the stored FIT file.
Future<String?> loadFitWorkoutName(Activity activity) async =>
    (await _decodeFit(activity))?.workoutName;

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

/// A planned workout an activity could be linked to, with how well it fits.
class LinkOption {
  const LinkOption(this.planned, this.score, this.reasons);

  final PlannedWorkout planned;
  final double score;
  final List<String> reasons;
}

/// Links recorded activities to planned workouts and evaluates them.
///
/// [matchAll] links what training_core's [ActivityMatcher] is sure about,
/// stores doubtful pairs as [MatchSuggestions] and leaves the rest unplanned.
/// Manual links and decisions of the user are never overridden.
class MatchingService {
  MatchingService(
    this._db, {
    LapLoader? lapLoader,
    WorkoutNameLoader? nameLoader,
    DateTime Function()? clock,
  }) : _lapLoader = lapLoader ?? loadFitLaps,
       _nameLoader = nameLoader ?? loadFitWorkoutName,
       _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final LapLoader _lapLoader;
  final WorkoutNameLoader _nameLoader;
  final DateTime Function() _clock;

  static const lookbackDays = 90;

  /// Shorter recordings are not workouts.
  static const minActivitySeconds = 300;

  /// Suggested candidates per activity.
  static const maxSuggestions = 2;

  /// Links open planned workouts (up to today) to activities, evaluates them
  /// against the plan, stores suggestions for doubtful pairs and re-evaluates
  /// linked ones that lacked streams. Returns the number of new automatic
  /// links.
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
    final workouts = {for (final p in open) p.id: ?_parse(p)};
    final planned = [
      for (final p in open)
        if (workouts.containsKey(p.id)) p,
    ];

    var linked = 0;
    if (planned.isNotEmpty) {
      linked = await _matchOpen(planned, workouts, today, from, profile, sizing);
    }
    await _reevaluateLinked(from, profile, sizing);
    return linked;
  }

  Future<int> _matchOpen(
    List<PlannedWorkout> planned,
    Map<int, Workout> workouts,
    DateTime today,
    DateTime from,
    PaceProfile? profile,
    PaceProfile sizing,
  ) async {
    final taken = {
      for (final p in await (_db.select(
        _db.plannedWorkouts,
      )..where((t) => t.activityId.isNotNull())).get())
        p.activityId!,
    };
    final rows =
        await (_db.select(_db.activities)..where(
              (t) =>
                  t.startTime.isBiggerOrEqualValue(
                    _addDays(from, -ActivityMatcher.maxDayShift),
                  ) &
                  t.startTime.isSmallerThanValue(_addDays(today, 2)) &
                  t.unplanned.equals(false),
            ))
            .get();
    final pool = [
      for (final a in rows)
        if (!taken.contains(a.id) && _eligible(a)) a,
    ];

    final dismissed = {
      for (final s
          in await (_db.select(
            _db.matchSuggestions,
          )..where((t) => t.dismissed.equals(true))).get())
        (s.activityId, s.plannedId),
    };

    final plannedCandidates = [
      for (final p in planned) _plannedCandidate(p, workouts[p.id]!),
    ];
    final byId = {for (final p in planned) p.id: p};
    final excluded = {...dismissed};
    final activities = <ActivityCandidate>[];
    final rowOf = <int, Activity>{};
    for (var a in pool) {
      final day = _day(a.startTime.toLocal());
      final near = [
        for (final p in plannedCandidates)
          if (_daysBetween(p.day, day).abs() <= ActivityMatcher.maxDayShift) p,
      ];
      if (near.isEmpty) continue;
      // A workout of today is only matched by a run of today; later days
      // may still bring a better candidate for earlier ones.
      for (final p in near) {
        if (p.day == today && day != today) excluded.add((a.id, p.id));
      }
      a = await _identify(a);
      final needLaps = near.any(
        (p) =>
            p.workout.steps.where((s) => s.kind != StepKind.strength).length >=
            3,
      );
      activities.add(await _candidate(a, needLaps: needLaps));
      rowOf[a.id] = a;
    }

    final result = ActivityMatcher(sizing).assign(
      planned: plannedCandidates,
      activities: activities,
      excluded: excluded,
    );

    var linked = 0;
    final autoLinked = <int>{};
    for (final r in result.high) {
      final p = byId[r.plannedId]!;
      await _evaluate(
        p,
        rowOf[r.activityId]!,
        workouts[p.id]!,
        profile,
        sizing,
        source: r.identified ? LinkSource.garminWorkout : LinkSource.auto,
        score: r.score,
      );
      await _dropSuggestions(activityId: r.activityId, plannedId: p.id);
      autoLinked.add(p.id);
      linked++;
    }

    await (_db.delete(
      _db.matchSuggestions,
    )..where((t) => t.dismissed.equals(false))).go();
    for (final r in result.medium) {
      final options = [
        r,
        for (final alt in result.alternatives[r.activityId] ?? const [])
          if (alt.plannedId != r.plannedId) alt,
      ].where((o) => !autoLinked.contains(o.plannedId));
      for (final o in options.take(maxSuggestions)) {
        if (dismissed.contains((o.activityId, o.plannedId))) continue;
        await _db
            .into(_db.matchSuggestions)
            .insertOnConflictUpdate(
              MatchSuggestionsCompanion.insert(
                activityId: o.activityId,
                plannedId: o.plannedId,
                score: o.score,
                reasonsJson: Value(jsonEncode(o.reasons)),
                createdAt: Value(_clock()),
              ),
            );
      }
    }
    return linked;
  }

  bool _eligible(Activity a) =>
      isStrengthSport(a.sport) ||
      (isRunSport(a.sport) && a.durationS >= minActivitySeconds);

  PlannedCandidate _plannedCandidate(PlannedWorkout p, Workout w) =>
      PlannedCandidate(
        id: p.id,
        day: _day(p.date.toLocal()),
        startMinute: p.startMinute,
        kind: p.kind,
        workout: w,
        title: p.title,
        garminWorkoutId: p.garminWorkoutId,
      );

  Future<ActivityCandidate> _candidate(
    Activity a, {
    required bool needLaps,
  }) async {
    final row = await (_db.select(
      _db.activityStreams,
    )..where((t) => t.activityId.equals(a.id))).getSingleOrNull();
    final data = row == null ? null : ActivityStreamData.fromRow(row);
    final local = a.startTime.toLocal();
    // Stored durations are timer time; the matcher subtracts pauses itself.
    final elapsed = data != null && data.length > 1
        ? data.seconds.last - data.seconds.first
        : 0;
    return ActivityCandidate(
      id: a.id,
      day: _day(local),
      startMinute: local.hour * 60 + local.minute,
      durationS: max(a.durationS, elapsed),
      distanceM: a.distanceM,
      isRun: !isStrengthSport(a.sport),
      samples: data?.toSamples(),
      pauses: data?.pauses,
      laps: needLaps ? await _lapLoader(a) : null,
      workoutName: a.workoutName,
      garminWorkoutId: a.garminWorkoutId,
    );
  }

  /// Fills the workout name from the stored FIT file once.
  Future<Activity> _identify(Activity a) async {
    if (a.workoutChecked || a.workoutName != null || a.fitPath == null) {
      return a;
    }
    final name = await _nameLoader(a);
    await (_db.update(_db.activities)..where((t) => t.id.equals(a.id))).write(
      ActivitiesCompanion(workoutName: Value(name), workoutChecked: const Value(true)),
    );
    return a.copyWith(workoutName: Value(name), workoutChecked: true);
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

  /// Links [activityId] to [plannedId] by the user's decision and evaluates
  /// it; the activity leaves any other workout and the unplanned state.
  Future<void> link(int activityId, int plannedId) async {
    final p = await _plannedRow(plannedId);
    final a = await _activityRow(activityId);
    if (p == null || a == null) return;
    final profile = await currentPaceProfile(_db);
    final sizing = profile ?? PaceProfile.fromVdot(45);
    final w = _parse(p);

    double? score;
    if (w != null) {
      score = ActivityMatcher(sizing)
          .score(
            _plannedCandidate(p, w),
            await _candidate(a, needLaps: true),
          )
          .score;
    }
    await _db.transaction(() async {
      for (final other in await (_db.select(
        _db.plannedWorkouts,
      )..where((t) => t.activityId.equals(a.id) & t.id.equals(p.id).not())).get()) {
        await _clearLink(other);
      }
      if (p.activityId != null && p.activityId != a.id) await _clearLink(p);
      await (_db.update(_db.activities)..where((t) => t.id.equals(a.id))).write(
        const ActivitiesCompanion(unplanned: Value(false)),
      );
      if (w == null) {
        await (_db.update(
          _db.plannedWorkouts,
        )..where((t) => t.id.equals(p.id))).write(
          PlannedWorkoutsCompanion(
            activityId: Value(a.id),
            status: const Value(WorkoutStatus.done),
            linkSource: const Value(LinkSource.manual),
            linkScore: Value(score),
            updatedAt: Value(_clock()),
          ),
        );
      } else {
        await _evaluate(
          p,
          a,
          w,
          profile,
          sizing,
          source: LinkSource.manual,
          score: score,
        );
      }
      await _dropSuggestions(activityId: a.id, plannedId: p.id);
    });
  }

  /// Same as [link]: the user confirmed the proposed pair.
  Future<void> acceptSuggestion(int activityId, int plannedId) =>
      link(activityId, plannedId);

  /// Removes the link and remembers that this pair was rejected.
  Future<void> unlink(int plannedId) async {
    final p = await _plannedRow(plannedId);
    if (p?.activityId == null) return;
    await _db.transaction(() => _clearLink(p!));
  }

  /// The activity is not a planned workout; unlinks it if it was linked.
  Future<void> markUnplanned(int activityId) => _db.transaction(() async {
    for (final p in await (_db.select(
      _db.plannedWorkouts,
    )..where((t) => t.activityId.equals(activityId))).get()) {
      await _clearLink(p);
    }
    await (_db.update(_db.activities)..where((t) => t.id.equals(activityId)))
        .write(const ActivitiesCompanion(unplanned: Value(true)));
    await _dropSuggestions(activityId: activityId);
  });

  /// Rejects one proposed pair for good.
  Future<void> rejectSuggestion(int activityId, int plannedId) =>
      (_db.update(_db.matchSuggestions)..where(
            (t) =>
                t.activityId.equals(activityId) & t.plannedId.equals(plannedId),
          ))
          .write(const MatchSuggestionsCompanion(dismissed: Value(true)));

  /// Rejects every proposal for the activity without calling it unplanned.
  Future<void> dismissSuggestions(int activityId) =>
      (_db.update(_db.matchSuggestions)
            ..where((t) => t.activityId.equals(activityId)))
          .write(const MatchSuggestionsCompanion(dismissed: Value(true)));

  /// Moves the planned workout to the day its activity was done.
  Future<bool> moveToActivityDay(int plannedId) async {
    final p = await _plannedRow(plannedId);
    if (p?.activityId == null) return false;
    final a = await _activityRow(p!.activityId!);
    if (a == null) return false;
    final day = _day(a.startTime.toLocal());
    if (day == _day(p.date.toLocal())) return false;
    await (_db.update(
      _db.plannedWorkouts,
    )..where((t) => t.id.equals(plannedId))).write(
      PlannedWorkoutsCompanion(date: Value(day), updatedAt: Value(_clock())),
    );
    return true;
  }

  /// Planned workouts near the activity's day, best fit first; ones linked to
  /// another activity are left out.
  Future<List<LinkOption>> linkOptions(
    int activityId, {
    int days = ActivityMatcher.maxDayShift,
  }) async {
    final a = await _activityRow(activityId);
    if (a == null) return const [];
    final day = _day(a.startTime.toLocal());
    final rows =
        await (_db.select(_db.plannedWorkouts)..where(
              (t) =>
                  t.date.isBiggerOrEqualValue(_addDays(day, -days)) &
                  t.date.isSmallerThanValue(_addDays(day, days + 1)) &
                  (t.activityId.isNull() | t.activityId.equals(activityId)),
            ))
            .get();
    final profile = await currentPaceProfile(_db) ?? PaceProfile.fromVdot(45);
    final matcher = ActivityMatcher(profile);
    final candidate = await _candidate(a, needLaps: true);
    final options = <LinkOption>[];
    for (final p in rows) {
      final w = _parse(p);
      if (w == null) continue;
      final s = matcher.score(_plannedCandidate(p, w), candidate);
      if (s.score > 0) options.add(LinkOption(p, s.score, s.reasons));
    }
    return options..sort((x, y) => y.score.compareTo(x.score));
  }

  Future<PlannedWorkout?> _plannedRow(int id) => (_db.select(
    _db.plannedWorkouts,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<Activity?> _activityRow(int id) => (_db.select(
    _db.activities,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> _dropSuggestions({int? activityId, int? plannedId}) =>
      (_db.delete(_db.matchSuggestions)..where(
            (t) =>
                t.dismissed.equals(false) &
                (t.activityId.equals(activityId ?? -1) |
                    t.plannedId.equals(plannedId ?? -1)),
          ))
          .go();

  Future<void> _clearLink(PlannedWorkout p) async {
    final activityId = p.activityId;
    await (_db.update(
      _db.plannedWorkouts,
    )..where((t) => t.id.equals(p.id))).write(
      PlannedWorkoutsCompanion(
        activityId: const Value<int?>(null),
        status: const Value(WorkoutStatus.planned),
        complianceJson: const Value<String?>(null),
        linkSource: const Value<LinkSource?>(null),
        linkScore: const Value<double?>(null),
        updatedAt: Value(_clock()),
      ),
    );
    if (activityId != null) {
      await _db
          .into(_db.matchSuggestions)
          .insertOnConflictUpdate(
            MatchSuggestionsCompanion.insert(
              activityId: activityId,
              plannedId: p.id,
              score: p.linkScore ?? 0,
              dismissed: const Value(true),
            ),
          );
    }
  }

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
      final a = await _activityRow(p.activityId!);
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
    PaceProfile sizing, {
    LinkSource? source,
    double? score,
  }) async {
    final row = await (_db.select(
      _db.activityStreams,
    )..where((t) => t.activityId.equals(a.id))).getSingleOrNull();
    final data = row == null ? null : ActivityStreamData.fromRow(row);
    final samples = data?.toSamples() ?? const <Sample>[];

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
        pauses: data?.pauses ?? const [],
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
        linkSource: source == null ? const Value.absent() : Value(source),
        linkScore: source == null ? const Value.absent() : Value(score),
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
