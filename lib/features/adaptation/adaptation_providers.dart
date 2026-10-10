import 'dart:convert';

import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_core/training_core.dart' hide TrainingPlan;

import '../../data/activity_streams.dart';
import '../../data/database.dart';
import '../../data/sports.dart';
import '../../providers.dart';
import 'matching_service.dart';
import 'plan_regenerator.dart';
import 'training_load.dart';

DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

abstract final class AdaptationKeys {
  static const dismissed = 'adaptation.dismissed';

  /// Fitness the plan was last (re)generated with, per plan id.
  static String baseline(int planId) => 'adaptation.baseline.$planId';
}

final matchingServiceProvider = Provider<MatchingService>(
  (ref) => MatchingService(ref.watch(databaseProvider)),
);

/// Planned workouts from five weeks back to two weeks ahead.
final recentPlannedProvider = StreamProvider<List<PlannedWorkout>>((ref) {
  final today = _today();
  return ref
      .watch(databaseProvider)
      .watchPlanned(
        DateTime(today.year, today.month, today.day - 35),
        DateTime(today.year, today.month, today.day + 14),
      );
});

final todaysWorkoutsProvider = StreamProvider<List<PlannedWorkout>>((ref) {
  final today = _today();
  return ref.watch(databaseProvider).watchPlanned(today, today);
});

final fitnessSnapshotsProvider = StreamProvider<List<FitnessSnapshot>>((ref) {
  final db = ref.watch(databaseProvider);
  return (db.select(
    db.fitnessSnapshots,
  )..orderBy([(t) => OrderingTerm.desc(t.date)])).watch();
});

final activePlanProvider = StreamProvider<TrainingPlan?>((ref) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.trainingPlans)
        ..where((t) => t.active.equals(true))
        ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
        ..limit(1))
      .watchSingleOrNull();
});

SessionCompliance? parseCompliance(PlannedWorkout p) {
  final json = p.complianceJson;
  if (json == null) return null;
  try {
    return SessionCompliance.fromJson(
      (jsonDecode(json) as Map).cast<String, Object?>(),
    );
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}

/// Latest planned workout with an evaluated activity.
final lastEvaluationProvider =
    Provider<({PlannedWorkout workout, SessionCompliance compliance})?>((ref) {
      final planned = ref.watch(recentPlannedProvider).value ?? const [];
      for (final p in planned.reversed) {
        if (parseCompliance(p) case final c?) {
          return (workout: p, compliance: c);
        }
      }
      return null;
    });

/// CTL/ATL/TSB over the last 90 days.
final trainingLoadProvider = FutureProvider<List<LoadPoint>>((ref) async {
  final activities = await ref.watch(activitiesProvider.future);
  final profile = await ref.watch(profileProvider.future);
  final today = _today();
  final from = DateTime(today.year, today.month, today.day - 89);
  final daily = <DateTime, double>{};
  for (final a in activities) {
    final local = a.startTime.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    if (day.isBefore(from)) continue;
    final load = activityLoad(a, profile);
    if (load != null) daily[day] = (daily[day] ?? 0) + load;
  }
  return Load.performanceManagement(daily, from: from, to: today);
});

class DismissedSuggestionsNotifier extends AsyncNotifier<Set<String>> {
  static const _max = 200;

  @override
  Future<Set<String>> build() async {
    final json = await ref
        .watch(databaseProvider)
        .getSetting(AdaptationKeys.dismissed);
    if (json == null) return {};
    return {...(jsonDecode(json) as List).cast<String>()};
  }

  Future<void> dismiss(String key) async {
    final keys = {...?state.value, key}.toList();
    final kept = keys.length > _max ? keys.sublist(keys.length - _max) : keys;
    await ref
        .read(databaseProvider)
        .setSetting(AdaptationKeys.dismissed, jsonEncode(kept));
    state = AsyncData(kept.toSet());
  }
}

final dismissedSuggestionsProvider =
    AsyncNotifierProvider<DismissedSuggestionsNotifier, Set<String>>(
      DismissedSuggestionsNotifier.new,
    );

CurrentFitness _fitnessOf(FitnessSnapshot s, AthleteProfile? profile) =>
    CurrentFitness(vdot: s.vdot, mas: s.masMps, lthr: profile?.lthr);

CurrentFitness? _decodeFitness(String? json) {
  if (json == null) return null;
  final m = (jsonDecode(json) as Map).cast<String, Object?>();
  return CurrentFitness(
    vdot: (m['vdot'] as num?)?.toDouble(),
    mas: (m['mas'] as num?)?.toDouble(),
    lthr: (m['lthr'] as num?)?.toDouble(),
  );
}

/// What the active plan was sized with: the baseline stored when a
/// regeneration was applied, else the fitness current at plan creation.
Future<CurrentFitness?> _planFitness(
  AppDatabase db,
  TrainingPlan? plan,
  List<FitnessSnapshot> snapshots,
  AthleteProfile? profile,
) async {
  if (plan == null) return null;
  final stored = _decodeFitness(
    await db.getSetting(AdaptationKeys.baseline(plan.id)),
  );
  if (stored != null) return stored;
  final pacing = snapshots.where((s) => s.vdot != null || s.masMps != null);
  final atCreation = pacing.where((s) => !s.date.isAfter(plan.createdAt));
  final basis = atCreation.firstOrNull ?? pacing.lastOrNull;
  return basis == null ? null : _fitnessOf(basis, profile);
}

Future<List<EffortCandidate>> _detectEfforts(
  AppDatabase db,
  List<Activity> activities,
  List<FitnessSnapshot> snapshots,
  AthleteProfile? profile,
) async {
  final since = DateTime.now().subtract(
    const Duration(days: AdaptationEngine.detectedWindowDays),
  );
  final known = {for (final s in snapshots) ?s.activityId};
  final found = <EffortCandidate>[];
  for (final a in activities) {
    if (a.startTime.isBefore(since) || !isRunSport(a.sport)) continue;
    if (known.contains(a.id)) continue;
    final row = await (db.select(
      db.activityStreams,
    )..where((t) => t.activityId.equals(a.id))).getSingleOrNull();
    if (row == null) continue;
    final samples = ActivityStreamData.fromRow(row).toSamples();
    for (final e in TestEvaluator.detectHardEfforts(
      samples,
      maxHr: profile?.maxHr,
    )) {
      found.add(
        EffortCandidate(ref: 'activity:${a.id}', date: a.startTime, effort: e),
      );
    }
  }
  return found;
}

/// Undismissed coaching suggestions for the current training state.
final adaptationSuggestionsProvider =
    FutureProvider<List<AdaptationSuggestion>>((ref) async {
      final db = ref.watch(databaseProvider);
      final planned = await ref.watch(recentPlannedProvider.future);
      final snapshots = await ref.watch(fitnessSnapshotsProvider.future);
      final activities = await ref.watch(activitiesProvider.future);
      final profile = await ref.watch(profileProvider.future);
      final plan = await ref.watch(activePlanProvider.future);
      final load = await ref.watch(trainingLoadProvider.future);
      final dismissed = await ref.watch(dismissedSuggestionsProvider.future);

      final today = _today();
      final history = <SessionOutcome>[];
      final upcoming = <UpcomingSession>[];
      for (final p in planned) {
        if (p.date.isAfter(today)) {
          upcoming.add(
            UpcomingSession(date: p.date, kind: p.kind, isKey: p.isKey),
          );
          continue;
        }
        final status = switch (p.status) {
          WorkoutStatus.done => OutcomeStatus.done,
          WorkoutStatus.partial => OutcomeStatus.partial,
          WorkoutStatus.skipped => OutcomeStatus.skipped,
          WorkoutStatus.planned =>
            p.activityId == null && p.date.isBefore(today)
                ? OutcomeStatus.missed
                : null,
        };
        if (status == null) continue;
        history.add(
          SessionOutcome(
            date: p.date,
            kind: p.kind,
            status: status,
            isKey: p.isKey,
            compliance: parseCompliance(p),
          ),
        );
      }

      final pacing = snapshots.where((s) => s.vdot != null || s.masMps != null);
      final tests = snapshots.where((s) => s.source != FitnessSource.manual);
      final suggestions = AdaptationEngine.suggest(
        today: today,
        history: history,
        upcoming: upcoming,
        planFitness: await _planFitness(db, plan, snapshots, profile),
        currentFitness: pacing.isEmpty
            ? null
            : _fitnessOf(pacing.first, profile),
        load: load,
        detected: await _detectEfforts(db, activities, snapshots, profile),
        lastTestDate: tests.firstOrNull?.date,
      );
      return [
        for (final s in suggestions)
          if (!dismissed.contains(s.key)) s,
      ];
    });

/// Whether Apply does anything for [action] right now.
bool canApply(
  AdaptationAction action, {
  PlanRegenerator? regenerator,
  PlanAdjuster? adjuster,
}) => switch (action) {
  Advice() => false,
  AdoptEffort() => true,
  RegenerateFuture() => regenerator != null,
  _ => adjuster != null,
};

final suggestionApplierProvider = Provider<SuggestionApplier>(
  (ref) => SuggestionApplier(ref),
);

class SuggestionApplier {
  SuggestionApplier(this._ref);

  final Ref _ref;

  /// Applies [s] and dismisses it; returns a message for the user.
  Future<String> apply(AdaptationSuggestion s) async {
    final message = await switch (s.action) {
      Advice() => Future.value('Noted'),
      AdoptEffort(:final ref, :final effort, :final date) => _adopt(
        ref,
        effort,
        date,
      ),
      final action => _changePlan(action),
    };
    await _ref.read(dismissedSuggestionsProvider.notifier).dismiss(s.key);
    return message;
  }

  Future<String> _adopt(String ref, DetectedEffort e, DateTime date) async {
    final db = _ref.read(databaseProvider);
    await db
        .into(db.fitnessSnapshots)
        .insert(
          FitnessSnapshotsCompanion.insert(
            date: date,
            source: FitnessSource.detected,
            distanceM: Value(e.distanceM),
            durationS: Value(e.time.inSeconds),
            vdot: Value(e.vdot),
            activityId: Value(int.tryParse(ref.split(':').last)),
            notes: const Value('Detected hard effort'),
          ),
        );
    return 'Fitness updated to VDOT ${e.vdot.toStringAsFixed(1)}';
  }

  Future<String> _changePlan(AdaptationAction action) async {
    final regenerator = _ref.read(planRegeneratorProvider);
    final adjuster = _ref.read(planAdjusterProvider);
    final plan = await _ref.read(activePlanProvider.future);
    if (plan == null ||
        !canApply(action, regenerator: regenerator, adjuster: adjuster)) {
      return 'No active plan to change';
    }
    final tomorrow = _today().add(const Duration(days: 1));
    switch (action) {
      case RegenerateFuture(:final fitness):
        await regenerator!.regenerateFuture(
          plan.id,
          from: tomorrow,
          fitness: fitness,
        );
        await _ref
            .read(databaseProvider)
            .setSetting(
              AdaptationKeys.baseline(plan.id),
              jsonEncode({
                if (fitness.vdot != null) 'vdot': fitness.vdot,
                if (fitness.mas != null) 'mas': fitness.mas,
                if (fitness.lthr != null) 'lthr': fitness.lthr,
              }),
            );
        return 'Plan regenerated from tomorrow';
      case ReduceNextWeek(:final factor):
        await adjuster!.reduceWeek(plan.id, from: tomorrow, factor: factor);
        return 'Next week lightened';
      case AddRecoveryDay(:final date):
        await adjuster!.addRecoveryDay(plan.id, date);
        return 'Recovery day added';
      case ScheduleTest(:final type):
        await adjuster!.scheduleTest(plan.id, type, from: tomorrow);
        return 'Test scheduled';
      case Advice() || AdoptEffort():
        return 'Noted';
    }
  }
}
