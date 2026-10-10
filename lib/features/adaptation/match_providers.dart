import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../providers.dart';
import 'adaptation_providers.dart';
import 'compliance_section.dart';
import 'matching_service.dart';

/// A candidate planned workout for a run that could not be linked for sure.
class MatchChoice {
  const MatchChoice(this.planned, this.score, this.reasons);

  final PlannedWorkout planned;
  final double score;
  final List<String> reasons;
}

class PendingMatch {
  const PendingMatch(this.activity, this.choices);

  final Activity activity;

  /// Best first.
  final List<MatchChoice> choices;
}

/// Runs waiting for the user to say which planned workout they were.
final pendingMatchesProvider = StreamProvider<List<PendingMatch>>((ref) {
  final db = ref.watch(databaseProvider);
  final s = db.matchSuggestions;
  final query =
      db.select(s).join([
          innerJoin(db.activities, db.activities.id.equalsExp(s.activityId)),
          innerJoin(
            db.plannedWorkouts,
            db.plannedWorkouts.id.equalsExp(s.plannedId),
          ),
        ])
        ..where(
          s.dismissed.equals(false) &
              db.plannedWorkouts.activityId.isNull() &
              db.activities.unplanned.equals(false),
        )
        ..orderBy([
          OrderingTerm.desc(db.activities.startTime),
          OrderingTerm.desc(s.score),
        ]);
  return query.watch().map((rows) {
    final byActivity = <int, PendingMatch>{};
    for (final r in rows) {
      final a = r.readTable(db.activities);
      final choice = MatchChoice(
        r.readTable(db.plannedWorkouts),
        r.readTable(s).score,
        _reasons(r.readTable(s).reasonsJson),
      );
      (byActivity[a.id] ??= PendingMatch(a, [])).choices.add(choice);
    }
    return byActivity.values.toList();
  });
});

List<String> _reasons(String json) {
  try {
    return [...(jsonDecode(json) as List).cast<String>()];
  } on FormatException {
    return const [];
  } on TypeError {
    return const [];
  }
}

/// Workouts linked by the matcher itself in the last week, newest first.
final recentAutoLinksProvider = StreamProvider<List<({PlannedWorkout planned, Activity activity})>>((
  ref,
) {
  final db = ref.watch(databaseProvider);
  final since = DateTime.now().subtract(const Duration(days: 7));
  final query =
      db.select(db.plannedWorkouts).join([
          innerJoin(
            db.activities,
            db.activities.id.equalsExp(db.plannedWorkouts.activityId),
          ),
        ])
        ..where(
          (db.plannedWorkouts.linkSource.equalsValue(LinkSource.auto) |
                  db.plannedWorkouts.linkSource.equalsValue(
                    LinkSource.garminWorkout,
                  )) &
              db.activities.startTime.isBiggerOrEqualValue(since),
        )
        ..orderBy([OrderingTerm.desc(db.activities.startTime)]);
  return query.watch().map(
    (rows) => [
      for (final r in rows)
        (
          planned: r.readTable(db.plannedWorkouts),
          activity: r.readTable(db.activities),
        ),
    ],
  );
});

/// Nearby planned workouts for the link picker of an activity.
final linkOptionsProvider = FutureProvider.autoDispose
    .family<List<LinkOption>, int>((ref, activityId) {
      ref.watch(plannedForActivityProvider(activityId));
      return ref.watch(matchingServiceProvider).linkOptions(activityId);
    });
