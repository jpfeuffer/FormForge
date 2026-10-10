import 'dart:math';

import 'compliance.dart';
import 'evaluation.dart';
import 'pauses.dart';
import 'plan/plan.dart';
import 'segmentation.dart';
import 'workout.dart';

/// How sure the matcher is that an activity executed a planned workout.
enum MatchConfidence {
  /// Link automatically.
  high,

  /// Ask the user.
  medium,

  /// Treat the activity as unplanned.
  low,
}

final class PlannedCandidate {
  const PlannedCandidate({
    required this.id,
    required this.day,
    required this.kind,
    required this.workout,
    required this.title,
    this.startMinute,
    this.garminWorkoutId,
  });

  final int id;

  /// Local calendar day.
  final DateTime day;

  /// Minute of the local day, if a time was planned.
  final int? startMinute;
  final SessionKind kind;
  final Workout workout;
  final String title;

  /// Id of the workout pushed to Garmin for this session.
  final String? garminWorkoutId;
}

final class ActivityCandidate {
  const ActivityCandidate({
    required this.id,
    required this.day,
    required this.startMinute,
    required this.durationS,
    required this.isRun,
    this.distanceM,
    this.samples,
    this.pauses,
    this.laps,
    this.workoutName,
    this.garminWorkoutId,
  });

  final int id;

  /// Local calendar day of the start.
  final DateTime day;
  final int startMinute;

  /// Elapsed seconds, pauses included.
  final int durationS;
  final double? distanceM;

  /// A run (not strength or another sport).
  final bool isRun;
  final List<Sample>? samples;
  final List<Pause>? pauses;
  final List<LapSegment>? laps;

  /// Name of the workout the watch executed, if any.
  final String? workoutName;
  final String? garminWorkoutId;
}

/// Similarity of one planned/activity pair, 0–1, with the reasons for it.
final class MatchScore {
  const MatchScore(
    this.score,
    this.reasons, {
    this.idMatch = false,
    this.nameMatch = false,
  });

  final double score;
  final List<String> reasons;

  /// The activity was started from the planned workout's Garmin id.
  final bool idMatch;

  /// The activity's workout name equals the planned title.
  final bool nameMatch;

  bool get identified => idMatch || nameMatch;
}

final class MatchResult {
  const MatchResult({
    required this.plannedId,
    required this.activityId,
    required this.score,
    required this.confidence,
    required this.reasons,
    this.identified = false,
  });

  final int plannedId;
  final int activityId;
  final double score;
  final MatchConfidence confidence;
  final List<String> reasons;

  /// Matched by the workout the watch executed (Garmin id or name).
  final bool identified;

  @override
  String toString() => 'MatchResult(planned $plannedId ↔ activity $activityId, '
      '${score.toStringAsFixed(2)} ${confidence.name})';
}

final class MatchAssignment {
  const MatchAssignment({
    required this.results,
    required this.unmatchedActivityIds,
    required this.unmatchedPlannedIds,
    required this.alternatives,
  });

  /// One-to-one pairs of all confidences.
  final List<MatchResult> results;

  /// Activities without any acceptable partner.
  final List<int> unmatchedActivityIds;
  final List<int> unmatchedPlannedIds;

  /// Per activity: every planned workout scoring at least
  /// [ActivityMatcher.mediumScore], best first.
  final Map<int, List<MatchResult>> alternatives;

  List<MatchResult> get high => [
        for (final r in results)
          if (r.confidence == MatchConfidence.high) r
      ];

  List<MatchResult> get medium => [
        for (final r in results)
          if (r.confidence == MatchConfidence.medium) r
      ];

  /// Activities to treat as unplanned: unmatched or only weakly matched.
  List<int> get unplannedActivityIds => [
        ...unmatchedActivityIds,
        for (final r in results)
          if (r.confidence == MatchConfidence.low) r.activityId,
      ];
}

/// Scores and assigns recorded activities to planned workouts.
///
/// A pair's score is the weighted mean of the available components (each
/// 0–1): structure (hard blocks of the plan versus laps or detected effort
/// segments), intensity (hard share and pace), size (duration and distance),
/// day and, on the same day with a planned start, time of day
/// ([timeWeight]). For planned sessions with hard blocks the weights are
/// [structureWeight], [intensityWeight], [sizeWeight], [dayWeight]; steady
/// runs and strength carry little structure information, so size and day
/// weigh more ([steadyWeights]). Components without data are left out and the
/// rest renormalised. An activity started from the pushed Garmin workout
/// scores at least [idScore]; a matching workout name closes [nameBoost] of
/// the remaining distance to 1; an activity identified with another workout
/// loses half its score.
final class ActivityMatcher {
  ActivityMatcher(this.profile);

  final PaceProfile profile;

  static const structureWeight = 0.30;
  static const intensityWeight = 0.20;
  static const sizeWeight = 0.25;
  static const dayWeight = 0.20;
  static const timeWeight = 0.05;

  /// (structure, intensity, size, day) for steady runs and strength.
  static const steadyWeights = (0.05, 0.10, 0.40, 0.35);

  static const idScore = 0.90;
  static const nameBoost = 0.60;

  /// Planned and executed day further apart than this never match.
  static const maxDayShift = 6;

  /// Day-proximity score by days apart.
  static const dayScores = [1.0, 0.65, 0.4, 0.2, 0.1, 0.1, 0.1];

  /// At least this: auto-link (if clearly better than the alternatives).
  static const highScore = 0.75;

  /// At least this: suggest to the user. Below: unplanned.
  static const mediumScore = 0.5;

  /// Pairs below this are not even assigned.
  static const minScore = 0.35;

  /// A high pair must beat every alternative of its activity and of its
  /// planned workout by this much (unless identified by Garmin workout id).
  static const margin = 0.10;

  final _planned = Map<PlannedCandidate, _Planned>.identity();
  final _activities = Map<ActivityCandidate, _Measured>.identity();

  /// Day offsets beyond [maxDayShift] are not comparable.
  static int dayShift(PlannedCandidate p, ActivityCandidate a) =>
      _days(a.day) - _days(p.day);

  MatchScore score(
    PlannedCandidate p,
    ActivityCandidate a, {
    bool identifiedElsewhere = false,
  }) {
    final plan = _plan(p);
    final done = _measured(a);
    if (plan.strengthOnly == a.isRun) return const MatchScore(0, []);

    final (wStructure, wIntensity, wSize, wDay) =
        plan.strengthOnly || plan.hardBlocks.isEmpty
            ? steadyWeights
            : (structureWeight, intensityWeight, sizeWeight, dayWeight);

    final reasons = <String>[];
    final parts = <(double weight, double value)>[];
    void add(double weight, double? value) {
      if (value != null) parts.add((weight, value));
    }

    final shift = dayShift(p, a);
    final distance = shift.abs();
    add(wDay, distance < dayScores.length ? dayScores[distance] : 0.0);
    reasons.add(switch (shift) {
      0 => 'Same day',
      > 0 => 'Done $shift day${shift == 1 ? '' : 's'} after the planned day',
      _ => 'Done ${-shift} day${shift == -1 ? '' : 's'} before the planned day',
    });

    if (p.startMinute != null && shift == 0) {
      final gap = (a.startMinute - p.startMinute!).abs();
      add(timeWeight, 1 - min(1, gap / 360));
      if (gap <= 90) reasons.add('Close to the planned start time');
    }

    add(wSize, _size(plan, done, a, reasons));
    if (!plan.strengthOnly) {
      add(wStructure, _structure(plan, done, a, reasons));
      add(wIntensity, _intensity(plan, done, a, reasons));
    }

    var total = 0.0, weights = 0.0;
    for (final (w, v) in parts) {
      total += w * v;
      weights += w;
    }
    var score = weights == 0 ? 0.0 : total / weights;

    final idMatch =
        p.garminWorkoutId != null && p.garminWorkoutId == a.garminWorkoutId;
    final nameMatch = !idMatch && _nameMatches(p, a.workoutName);
    if (idMatch) {
      score = idScore + (1 - idScore) * score;
      reasons.insert(0, 'Started from the pushed Garmin workout');
    } else if (nameMatch) {
      score += (1 - score) * nameBoost;
      reasons.insert(0, 'Garmin workout name matches');
    } else if (identifiedElsewhere) {
      score *= 0.5;
      reasons.insert(0, 'Started from a different planned workout');
    }
    return MatchScore(
      max(0.0, min(1.0, score)),
      reasons,
      idMatch: idMatch,
      nameMatch: nameMatch,
    );
  }

  /// Optimal one-to-one assignment maximising the total score. [excluded]
  /// holds `(activityId, plannedId)` pairs the user rejected.
  MatchAssignment assign({
    required List<PlannedCandidate> planned,
    required List<ActivityCandidate> activities,
    Set<(int, int)> excluded = const {},
  }) {
    final idOwner = <int, int>{};
    for (final a in activities) {
      for (final p in planned) {
        if (a.garminWorkoutId != null &&
            a.garminWorkoutId == p.garminWorkoutId) {
          idOwner[a.id] = p.id;
        }
      }
    }

    final scores = <(int, int), MatchScore>{};
    for (final a in activities) {
      for (final p in planned) {
        if (excluded.contains((a.id, p.id))) continue;
        if (dayShift(p, a).abs() > maxDayShift) continue;
        final s = score(
          p,
          a,
          identifiedElsewhere:
              idOwner.containsKey(a.id) && idOwner[a.id] != p.id,
        );
        if (s.score > 0) scores[(a.id, p.id)] = s;
      }
    }

    final weight = [
      for (final p in planned)
        [
          for (final a in activities)
            switch (scores[(a.id, p.id)]) {
              final s? when s.score >= minScore => s.score,
              _ => 0.0,
            },
        ],
    ];
    final rows = _hungarian(weight, planned.length, activities.length);

    final plannedOf = <int, int>{}; // activity -> planned
    final activityOf = <int, int>{}; // planned -> activity
    for (var i = 0; i < rows.length; i++) {
      final j = rows[i];
      if (j < 0 || weight[i][j] <= 0) continue;
      plannedOf[activities[j].id] = planned[i].id;
      activityOf[planned[i].id] = activities[j].id;
    }

    double bestAlternative({
      required bool forActivity,
      required int a,
      required int p,
      required bool identifiedOnly,
    }) {
      var best = 0.0;
      for (final MapEntry(key: (ai, pi), value: s) in scores.entries) {
        if (forActivity ? ai != a || pi == p : pi != p || ai == a) continue;
        if (s.score < minScore || (identifiedOnly && !s.identified)) continue;
        final other = forActivity ? pi : ai;
        final owner = forActivity ? activityOf[pi] : plannedOf[ai];
        if (owner != null && owner != (forActivity ? a : p)) {
          // Claimed by a partner that fits it at least as well.
          final theirs =
              forActivity ? scores[(owner, other)] : scores[(other, owner)];
          if (theirs != null && theirs.score >= s.score) continue;
        }
        best = max(best, s.score);
      }
      return best;
    }

    final results = <MatchResult>[];
    for (final MapEntry(key: a, value: p) in plannedOf.entries) {
      final s = scores[(a, p)]!;
      // Knowing which workout the watch ran only competes with the same.
      final gap = s.score -
          max(
            bestAlternative(
                forActivity: true, a: a, p: p, identifiedOnly: s.identified),
            bestAlternative(
                forActivity: false, a: a, p: p, identifiedOnly: s.identified),
          );
      final confidence = s.score < mediumScore
          ? MatchConfidence.low
          : s.idMatch || (s.score >= highScore && gap >= margin)
              ? MatchConfidence.high
              : MatchConfidence.medium;
      results.add(
        MatchResult(
          plannedId: p,
          activityId: a,
          score: s.score,
          confidence: confidence,
          reasons: s.reasons,
          identified: s.identified,
        ),
      );
    }
    results.sort((x, y) => y.score.compareTo(x.score));

    final alternatives = <int, List<MatchResult>>{};
    for (final MapEntry(key: (a, p), value: s) in scores.entries) {
      if (s.score < mediumScore) continue;
      (alternatives[a] ??= []).add(
        MatchResult(
          plannedId: p,
          activityId: a,
          score: s.score,
          confidence: MatchConfidence.medium,
          reasons: s.reasons,
          identified: s.identified,
        ),
      );
    }
    for (final list in alternatives.values) {
      list.sort((x, y) => y.score.compareTo(x.score));
    }

    return MatchAssignment(
      results: results,
      unmatchedActivityIds: [
        for (final a in activities)
          if (!plannedOf.containsKey(a.id)) a.id,
      ],
      unmatchedPlannedIds: [
        for (final p in planned)
          if (!activityOf.containsKey(p.id)) p.id,
      ],
      alternatives: alternatives,
    );
  }

  _Planned _plan(PlannedCandidate p) => _planned[p] ??= _Planned(p, profile);

  _Measured _measured(ActivityCandidate a) =>
      _activities[a] ??= _Measured(a, profile);

  static bool _nameMatches(PlannedCandidate p, String? name) {
    final n = _normalize(name);
    if (n.isEmpty) return false;
    return n == _normalize(p.title) || n == _normalize(p.workout.title);
  }

  static String _normalize(String? name) => (name ?? '')
      .replaceAll(RegExp(r'\s*\[FF\]\s*$'), '')
      .trim()
      .toLowerCase();

  static int _days(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;

  /// Ratio similarity: 1 at equal, 0 at a factor of [limit] apart.
  static double _ratio(double a, double b, {double limit = 2}) {
    if (a <= 0 || b <= 0) return 0;
    return max(0.0, 1 - (log(a / b)).abs() / log(limit));
  }

  double? _size(_Planned plan, _Measured done, ActivityCandidate a,
      List<String> reasons) {
    final values = <double>[];
    final seconds = plan.seconds;
    if (seconds > 0 && a.durationS > 0) {
      final actual = done.elapsedS;
      values.add(_ratio(actual.toDouble(), seconds.toDouble()));
      reasons.add(
        'Duration ${(actual / 60).round()} min (planned ${(seconds / 60).round()})',
      );
    }
    if (!plan.strengthOnly && plan.meters > 0 && (a.distanceM ?? 0) > 0) {
      values.add(_ratio(a.distanceM!, plan.meters));
      reasons.add(
        'Distance ${(a.distanceM! / 1000).toStringAsFixed(1)} km '
        '(planned ${(plan.meters / 1000).toStringAsFixed(1)})',
      );
    }
    return values.isEmpty
        ? null
        : values.reduce((x, y) => x + y) / values.length;
  }

  double? _structure(_Planned plan, _Measured done, ActivityCandidate a,
      List<String> reasons) {
    final blocks = done.blocksFor(plan);
    if (blocks == null) return null;
    final planned = plan.hardBlocks;
    final found = [
      for (final b in blocks)
        if (b.hard) b
    ];
    final foundSeconds = found.fold(0.0, (s, b) => s + b.seconds);
    final total = blocks.fold(0.0, (s, b) => s + b.seconds);

    if (planned.isEmpty) {
      final share = total == 0 ? 0.0 : foundSeconds / total;
      if (share > 0.1) reasons.add('Contains hard efforts the plan does not');
      return 1 - min(1, share / 0.2);
    }
    if (found.isEmpty) {
      reasons.add(
          'Planned ${planned.length} hard block${planned.length == 1 ? '' : 's'}, found none');
      return 0;
    }

    // Best in-order pairing of hard blocks of similar size.
    final dp = List.generate(
      planned.length + 1,
      (_) => List.filled(found.length + 1, 0.0),
    );
    for (var i = 1; i <= planned.length; i++) {
      for (var j = 1; j <= found.length; j++) {
        final sim = _blockSimilarity(planned[i - 1], found[j - 1]);
        dp[i][j] = max(
          max(dp[i - 1][j], dp[i][j - 1]),
          dp[i - 1][j - 1] + (sim >= 0.4 ? sim : 0),
        );
      }
    }
    final value =
        dp[planned.length][found.length] / max(planned.length, found.length);
    if (value >= 0.7) {
      reasons.add(
          '${found.length} hard blocks like the planned ${planned.length}');
    } else {
      reasons
          .add('Planned ${planned.length} hard blocks, found ${found.length}');
    }
    return value;
  }

  /// Time and distance both count: reps of a set distance vary in time with
  /// pace, timed reps vary in distance.
  static double _blockSimilarity(_Block planned, _Block found) {
    final byTime = _ratio(found.seconds, planned.seconds, limit: 3);
    final byDistance = planned.meters != null && found.meters != null
        ? _ratio(found.meters!, planned.meters!, limit: 3)
        : 0.0;
    return max(byTime, byDistance);
  }

  double? _intensity(_Planned plan, _Measured done, ActivityCandidate a,
      List<String> reasons) {
    final speed = plan.moving > 0 && plan.meters > 0 && done.speed != null
        ? _ratio(done.speed!, plan.meters / plan.moving, limit: 1.3)
        : null;
    final share = done.hardShareFor(plan);
    double? hard;
    if (share != null) {
      final p = plan.hardShare;
      hard = 1 - min(1, (p - share).abs() / max(0.1, max(p, share)));
      if (hard < 0.4) reasons.add('Intensity mix differs from the plan');
    }
    if (hard != null && speed != null) return 0.6 * hard + 0.4 * speed;
    return hard ?? speed;
  }
}

/// A run of equal effort class in the plan or the recording.
final class _Block {
  const _Block(this.hard, this.seconds, this.meters);

  final bool hard;
  final double seconds;
  final double? meters;
}

/// Run part of a planned workout.
final class _Planned {
  _Planned(PlannedCandidate p, PaceProfile profile) {
    final steps = [
      for (final s in p.workout.flatten())
        if (s.kind != StepKind.strength) s,
    ];
    strengthOnly = p.kind == SessionKind.strength || steps.isEmpty;
    stepCount = steps.length;
    if (strengthOnly) {
      seconds = p.workout.estimatedDuration(profile).inSeconds;
      return;
    }
    var hardSeconds = 0.0;
    var open = false;
    for (final s in steps) {
      final secs = s.estimatedDuration(profile).inSeconds.toDouble();
      seconds += secs.round();
      if (!s.isMoving) {
        open = false;
        continue;
      }
      moving += secs;
      final m = s.estimatedDistance(profile);
      meters += m;
      final v = s.effectiveSpeed(profile);
      if (v == null || !profile.isHard(v)) {
        open = false;
        continue;
      }
      hardSeconds += secs;
      if (open) {
        final last = hardBlocks.removeLast();
        hardBlocks
            .add(_Block(true, last.seconds + secs, (last.meters ?? 0) + m));
      } else {
        hardBlocks.add(_Block(true, secs, m));
      }
      open = true;
    }
    hardShare = moving == 0 ? 0 : hardSeconds / moving;
  }

  late final bool strengthOnly;
  late final int stepCount;
  int seconds = 0;
  double moving = 0;
  double meters = 0;
  double hardShare = 0;
  final hardBlocks = <_Block>[];
}

/// Effort structure of a recording, computed on demand.
final class _Measured {
  _Measured(this.a, this.profile);

  final ActivityCandidate a;
  final PaceProfile profile;

  late final int elapsedS = a.durationS -
      [
        for (final p in a.pauses ?? const <Pause>[])
          if (p.kind == PauseKind.paused) p.seconds,
      ].fold(0, (s, v) => s + v);

  late final int movingS = max(
    1,
    a.durationS -
        [for (final p in a.pauses ?? const <Pause>[]) p.seconds]
            .fold(0, (s, v) => s + v),
  );

  late final double? speed =
      (a.distanceM ?? 0) > 0 ? a.distanceM! / movingS : null;

  late final List<_Block>? _segments = () {
    final samples = a.samples;
    if (samples == null || samples.length < 2) return null;
    final segments = EffortSegmenter.segment(
      samples,
      profile,
      pauses: a.pauses ?? const [],
    );
    if (segments.isEmpty) return null;
    return [
      for (final s in segments)
        _Block(s.hard, s.movingS.toDouble(), s.distance),
    ];
  }();

  late final List<_Block>? _laps = () {
    final laps = a.laps;
    if (laps == null || laps.isEmpty || laps.any((l) => l.distanceM == null)) {
      return null;
    }
    final enter = EffortSegmenter.thresholds(profile).enter;
    final blocks = <_Block>[];
    for (final l in laps) {
      if (l.durationS <= 0) continue;
      final hard = l.distanceM! / l.durationS >= enter;
      if (blocks.isNotEmpty && blocks.last.hard == hard) {
        final last = blocks.removeLast();
        blocks.add(_Block(
            hard, last.seconds + l.durationS, last.meters! + l.distanceM!));
      } else {
        blocks.add(_Block(hard, l.durationS.toDouble(), l.distanceM));
      }
    }
    return blocks;
  }();

  /// Laps that look like one per workout step; else detected segments.
  List<_Block>? blocksFor(_Planned plan) {
    final laps = a.laps;
    final plausible = laps != null &&
        plan.stepCount >= 3 &&
        (laps.length - plan.stepCount).abs() <= 1;
    return plausible ? _laps ?? _segments : _segments;
  }

  double? hardShareFor(_Planned plan) {
    final blocks = blocksFor(plan);
    if (blocks == null) return null;
    final total = blocks.fold(0.0, (s, b) => s + b.seconds);
    if (total == 0) return null;
    return blocks.where((b) => b.hard).fold(0.0, (s, b) => s + b.seconds) /
        total;
  }
}

List<int> _hungarian(List<List<double>> weight, int rows, int cols) {
  final n = max(rows, cols);
  if (n == 0) return List.filled(rows, -1);
  double cost(int i, int j) => i < rows && j < cols ? -weight[i][j] : 0;
  final u = List.filled(n + 1, 0.0), v = List.filled(n + 1, 0.0);
  final p = List.filled(n + 1, 0), way = List.filled(n + 1, 0);
  for (var i = 1; i <= n; i++) {
    p[0] = i;
    var j0 = 0;
    final minv = List.filled(n + 1, double.infinity);
    final used = List.filled(n + 1, false);
    do {
      used[j0] = true;
      final i0 = p[j0];
      var delta = double.infinity;
      var j1 = 0;
      for (var j = 1; j <= n; j++) {
        if (used[j]) continue;
        final cur = cost(i0 - 1, j - 1) - u[i0] - v[j];
        if (cur < minv[j]) {
          minv[j] = cur;
          way[j] = j0;
        }
        if (minv[j] < delta) {
          delta = minv[j];
          j1 = j;
        }
      }
      for (var j = 0; j <= n; j++) {
        if (used[j]) {
          u[p[j]] += delta;
          v[j] -= delta;
        } else {
          minv[j] -= delta;
        }
      }
      j0 = j1;
    } while (p[j0] != 0);
    do {
      final j1 = way[j0];
      p[j0] = p[j1];
      j0 = j1;
    } while (j0 != 0);
  }
  final result = List.filled(rows, -1);
  for (var j = 1; j <= n; j++) {
    final i = p[j] - 1;
    if (i >= 0 && i < rows && j - 1 < cols) result[i] = j - 1;
  }
  return result;
}
