import 'dart:convert';

import 'package:test/test.dart';
import 'package:training_core/training_core.dart';

void main() {
  final today = DateTime(2026, 10, 10);
  DateTime ago(int days) => DateTime(2026, 10, 10 - days);

  SessionCompliance comp(
    SessionVerdict verdict, {
    StepVerdict step = StepVerdict.onTarget,
    double completion = 1,
    double? decoupling,
    double? speedRatio,
  }) =>
      SessionCompliance(
        steps: [
          StepCompliance(
            index: 0,
            kind: StepKind.active,
            verdict: step,
            coverage: 1,
          ),
        ],
        completion: completion,
        verdict: verdict,
        alignment: StepAlignment.time,
        decoupling: decoupling,
        speedRatio: speedRatio,
      );

  SessionOutcome outcome(
    int daysAgo,
    SessionKind kind, {
    OutcomeStatus status = OutcomeStatus.done,
    SessionCompliance? compliance,
  }) =>
      SessionOutcome(
        date: ago(daysAgo),
        kind: kind,
        status: status,
        compliance: compliance,
      );

  List<AdaptationSuggestion> suggest({
    List<SessionOutcome> history = const [],
    List<UpcomingSession> upcoming = const [],
    CurrentFitness? plan,
    CurrentFitness? current,
    List<LoadPoint> load = const [],
    List<EffortCandidate> detected = const [],
    DateTime? lastTest,
  }) =>
      AdaptationEngine.suggest(
        today: today,
        history: history,
        upcoming: upcoming,
        planFitness: plan,
        currentFitness: current,
        load: load,
        detected: detected,
        lastTestDate: lastTest,
      );

  Iterable<String> codes(List<AdaptationSuggestion> s) => s.map((e) => e.code);

  test('nothing to say about an uneventful week', () {
    expect(
      suggest(
        history: [
          outcome(1, SessionKind.easy,
              compliance: comp(SessionVerdict.onTarget)),
          outcome(3, SessionKind.threshold,
              compliance: comp(SessionVerdict.onTarget)),
        ],
        plan: const CurrentFitness(vdot: 50),
        current: const CurrentFitness(vdot: 50.4),
      ),
      isEmpty,
    );
  });

  group('fitness change', () {
    test('a VDOT shift of 1 or more suggests regenerating', () {
      final s = suggest(
        plan: const CurrentFitness(vdot: 50),
        current: const CurrentFitness(vdot: 52.3),
      ).single;
      expect(s.code, 'fitness_changed');
      expect(s.severity, SuggestionSeverity.info);
      expect(s.action, isA<RegenerateFuture>());
      expect((s.action as RegenerateFuture).fitness.vdot, 52.3);
    });

    test('a drop is a warning; MAS compares via equivalent VDOT', () {
      final s = suggest(
        plan: const CurrentFitness(mas: 4.8),
        current: const CurrentFitness(vdot: 40),
      ).single;
      expect(s.severity, SuggestionSeverity.warning);
    });

    test('below the threshold stays quiet', () {
      expect(
        suggest(
          plan: const CurrentFitness(vdot: 50),
          current: const CurrentFitness(vdot: 50.9),
        ),
        isEmpty,
      );
    });
  });

  group('easy runs', () {
    SessionOutcome easy(int d, SessionVerdict v,
            {StepVerdict step = StepVerdict.tooFast}) =>
        outcome(d, SessionKind.easy, compliance: comp(v, step: step));

    test('two of the last three too hard → slow down', () {
      final s = suggest(
        history: [
          easy(8, SessionVerdict.onTarget),
          easy(5, SessionVerdict.tooHard),
          easy(2, SessionVerdict.tooHard, step: StepVerdict.hrTooHigh),
        ],
      ).single;
      expect(s.code, 'easy_too_hard');
      expect(s.action, isA<Advice>());
      expect(s.message, contains('too fast'));
      expect(s.message, contains('HR'));
      expect(s.key, 'easy_too_hard:2026-10-08');
    });

    test('a single slip is ignored', () {
      expect(
        suggest(
          history: [
            easy(6, SessionVerdict.onTarget),
            easy(4, SessionVerdict.tooHard),
            easy(2, SessionVerdict.onTarget),
          ],
        ),
        isEmpty,
      );
    });

    test('old runs outside the window do not count', () {
      expect(
        suggest(
          history: [
            easy(30, SessionVerdict.tooHard),
            easy(20, SessionVerdict.tooHard),
          ],
        ),
        isEmpty,
      );
    });
  });

  group('quality sessions', () {
    test('two of the last three not completed → reduce next week', () {
      final s = suggest(
        history: [
          outcome(9, SessionKind.interval,
              compliance: comp(SessionVerdict.onTarget)),
          outcome(
            6,
            SessionKind.threshold,
            compliance: comp(SessionVerdict.incomplete, completion: 0.5),
          ),
          outcome(2, SessionKind.interval, status: OutcomeStatus.missed),
        ],
      );
      expect(codes(s), contains('quality_not_completed'));
      final a = s.firstWhere((e) => e.code == 'quality_not_completed').action;
      expect((a as ReduceNextWeek).factor, 0.85);
    });

    test('tests do not count as quality sessions', () {
      expect(
        codes(
          suggest(
            history: [
              outcome(9, SessionKind.test, status: OutcomeStatus.missed),
              outcome(6, SessionKind.test, status: OutcomeStatus.missed),
            ],
          ),
        ),
        isNot(contains('quality_not_completed')),
      );
    });
  });

  group('missed sessions', () {
    test('two in a week → lighten', () {
      final s = suggest(
        history: [
          outcome(5, SessionKind.easy, status: OutcomeStatus.missed),
          outcome(2, SessionKind.long, status: OutcomeStatus.skipped),
        ],
      ).single;
      expect(s.code, 'missed_sessions');
      expect((s.action as ReduceNextWeek).factor, 0.9);
    });

    test('one miss, or misses long ago, are fine', () {
      expect(
        suggest(
          history: [
            outcome(2, SessionKind.easy, status: OutcomeStatus.missed),
            outcome(12, SessionKind.easy, status: OutcomeStatus.missed),
            outcome(13, SessionKind.easy, status: OutcomeStatus.missed),
          ],
        ),
        isEmpty,
      );
    });

    test("today's unmatched session is not missed yet", () {
      expect(
        suggest(
          history: [
            outcome(0, SessionKind.easy, status: OutcomeStatus.missed),
            outcome(1, SessionKind.easy, status: OutcomeStatus.missed),
          ],
        ),
        isEmpty,
      );
    });
  });

  group('training load', () {
    LoadPoint point(double ctl, double atl) =>
        LoadPoint(day: today, load: 0, ctl: ctl, atl: atl, tsb: ctl - atl);

    test('ACWR above 1.3 → recovery day tomorrow', () {
      final s = suggest(load: [point(50, 70)]).single;
      expect(s.code, 'load_high');
      expect(s.severity, SuggestionSeverity.warning);
      expect((s.action as AddRecoveryDay).date, DateTime(2026, 10, 11));
    });

    test('skips days with key sessions', () {
      final s = suggest(
        load: [point(50, 70)],
        upcoming: [
          UpcomingSession(
              date: DateTime(2026, 10, 11),
              kind: SessionKind.interval,
              isKey: true),
          UpcomingSession(date: DateTime(2026, 10, 12), kind: SessionKind.easy),
        ],
      ).single;
      expect((s.action as AddRecoveryDay).date, DateTime(2026, 10, 12));
    });

    test('very negative form alone triggers; extreme values are critical', () {
      expect(suggest(load: [point(60, 95)]).single.severity,
          SuggestionSeverity.critical);
      expect(codes(suggest(load: [point(60, 80)])), ['load_high']);
    });

    test('low CTL makes the ratio meaningless', () {
      expect(suggest(load: [point(8, 20)]), isEmpty);
    });

    test('balanced load is fine', () {
      expect(suggest(load: [point(50, 55)]), isEmpty);
    });
  });

  group('decoupling', () {
    test('repeatedly above 5 % on long runs → build base', () {
      final s = suggest(
        history: [
          outcome(21, SessionKind.long,
              compliance: comp(SessionVerdict.onTarget, decoupling: 7.2)),
          outcome(14, SessionKind.long,
              compliance: comp(SessionVerdict.onTarget, decoupling: 3.1)),
          outcome(7, SessionKind.long,
              compliance: comp(SessionVerdict.onTarget, decoupling: 8.0)),
        ],
      ).single;
      expect(s.code, 'decoupling_high');
      expect(s.action, isA<Advice>());
    });

    test('one drifting run is not a trend', () {
      expect(
        suggest(
          history: [
            outcome(14, SessionKind.long,
                compliance: comp(SessionVerdict.onTarget, decoupling: 3.1)),
            outcome(7, SessionKind.long,
                compliance: comp(SessionVerdict.onTarget, decoupling: 8.0)),
          ],
        ),
        isEmpty,
      );
    });
  });

  group('exceeding targets', () {
    List<SessionOutcome> strong() => [
          for (final (d, k) in [
            (12, SessionKind.interval),
            (8, SessionKind.threshold),
            (3, SessionKind.interval),
          ])
            outcome(d, k,
                compliance: comp(SessionVerdict.onTarget, speedRatio: 1.05)),
        ];

    test('three beaten quality sessions → schedule a test', () {
      final s = suggest(history: strong(), plan: const CurrentFitness(vdot: 50))
          .single;
      expect(s.code, 'exceeding_targets');
      expect((s.action as ScheduleTest).type, TestType.timeTrial5k);
    });

    test('MAS-only athletes get a half-Cooper', () {
      final s = suggest(history: strong(), plan: const CurrentFitness(mas: 4.8))
          .single;
      expect((s.action as ScheduleTest).type, TestType.halfCooper);
    });

    test('not when a test is planned or was just done', () {
      expect(
        suggest(
          history: strong(),
          upcoming: [
            UpcomingSession(date: ago(-6), kind: SessionKind.test, isKey: true)
          ],
        ),
        isEmpty,
      );
      expect(suggest(history: strong(), lastTest: ago(10)), isEmpty);
    });

    test('not when the effort showed in HR', () {
      final history = strong()
        ..[2] = outcome(
          3,
          SessionKind.interval,
          compliance: comp(SessionVerdict.tooHard,
              step: StepVerdict.hrTooHigh, speedRatio: 1.05),
        );
      expect(suggest(history: history), isEmpty);
    });
  });

  group('detected efforts', () {
    EffortCandidate candidate(double vdot) => EffortCandidate(
          ref: 'activity:42',
          date: ago(2),
          effort: DetectedEffort(
            distanceM: 5000,
            startSecond: 600,
            endSecond: 1736,
            vdot: vdot,
            pacingVariation: 0.03,
          ),
        );

    test('a clearly better effort is offered as new fitness', () {
      final s = suggest(
        current: const CurrentFitness(vdot: 50),
        detected: [candidate(52.5)],
      ).single;
      expect(s.code, 'detected_effort');
      expect(s.message, contains('5k'));
      expect(s.message, contains('18:56'));
      final a = s.action as AdoptEffort;
      expect(a.ref, 'activity:42');
      expect(a.effort.vdot, 52.5);
    });

    test('no better than current fitness: nothing', () {
      expect(
        suggest(
            current: const CurrentFitness(vdot: 52),
            detected: [candidate(52.5)]),
        isEmpty,
      );
    });
  });

  test('critical first, then warnings, then info; stable within a level', () {
    final s = suggest(
      plan: const CurrentFitness(vdot: 50),
      current: const CurrentFitness(vdot: 53),
      history: [
        outcome(5, SessionKind.easy, status: OutcomeStatus.missed),
        outcome(2, SessionKind.long, status: OutcomeStatus.missed),
      ],
      load: [LoadPoint(day: today, load: 0, ctl: 60, atl: 95, tsb: 0)],
    );
    expect(codes(s), ['load_high', 'missed_sessions', 'fitness_changed']);
  });

  test('suggestions serialize to JSON', () {
    final s = suggest(
      plan: const CurrentFitness(vdot: 50),
      current: const CurrentFitness(vdot: 53, lthr: 168),
    );
    final json =
        jsonDecode(jsonEncode([for (final x in s) x.toJson()])) as List;
    expect((json.single as Map)['action'], {
      'type': 'regenerateFuture',
      'fitness': {'vdot': 53.0, 'lthr': 168.0},
    });
  });
}
