import 'dart:convert';

import 'package:test/test.dart';
import 'package:training_core/training_core.dart';

import 'synthetic_samples.dart';

void main() {
  final profile = PaceProfile.fromVdot(50, lthr: 170);
  final easy = profile.speedFor(Intensity.easy).mid;
  final interval = profile.speedFor(Intensity.interval).mid;

  Workout easyRun(int minutes) => Workout(
        sport: Sport.run,
        title: 'Easy',
        elements: [
          WorkoutStep(
            kind: StepKind.active,
            end: TimeEnd(Duration(minutes: minutes)),
            target: const IntensityTarget(Intensity.easy),
          ),
        ],
      );

  // warm-up 10 min, 4 × (3 min hard / 2 min jog), cool-down 5 min: 10 steps.
  Workout intervals() => Workout(
        sport: Sport.run,
        title: '4 × 3 min',
        elements: [
          const WorkoutStep(
            kind: StepKind.warmup,
            end: TimeEnd(Duration(minutes: 10)),
            target: IntensityTarget(Intensity.easy),
          ),
          RepeatBlock(
            times: 4,
            elements: const [
              WorkoutStep(
                kind: StepKind.active,
                end: TimeEnd(Duration(minutes: 3)),
                target: IntensityTarget(Intensity.interval),
              ),
              WorkoutStep(
                kind: StepKind.recovery,
                end: TimeEnd(Duration(minutes: 2)),
                target: IntensityTarget(Intensity.recovery),
              ),
            ],
          ),
          const WorkoutStep(
            kind: StepKind.cooldown,
            end: TimeEnd(Duration(minutes: 5)),
            target: IntensityTarget(Intensity.easy),
          ),
        ],
      );

  List<Part> intervalParts({
    double hard = 0,
    int reps = 4,
    bool cooldown = true,
  }) {
    final h = hard == 0 ? interval : hard;
    return [
      part(600, easy, 135),
      for (var i = 0; i < reps; i++) ...[
        part(180, h, 172),
        part(120, 2.3, 150)
      ],
      if (cooldown) part(300, easy, 140),
    ];
  }

  List<LapSegment> lapsFor(List<Part> parts) {
    final laps = <LapSegment>[];
    var start = 0;
    for (final p in parts) {
      laps.add(LapSegment(startSecond: start, durationS: p.seconds));
      start += p.seconds;
    }
    return laps;
  }

  group('easy run', () {
    test('done at plan', () {
      final c = ComplianceEvaluator.evaluate(
        workout: easyRun(40),
        profile: profile,
        samples: synth([part(2400, easy, 140)]),
      );
      expect(c.verdict, SessionVerdict.onTarget);
      expect(c.completion, closeTo(1, 1e-9));
      expect(c.paceCompliance, closeTo(1, 1e-9));
      expect(c.hrCompliance, closeTo(1, 1e-9));
      expect(c.steps.single.verdict, StepVerdict.onTarget);
      expect(c.speedRatio,
          closeTo(easy / profile.speedFor(Intensity.easy).mid, 1e-3));
    });

    test('done too fast', () {
      final c = ComplianceEvaluator.evaluate(
        workout: easyRun(40),
        profile: profile,
        samples: synth([part(2400, 3.9, 150)]),
      );
      expect(c.steps.single.verdict, StepVerdict.tooFast);
      expect(c.verdict, SessionVerdict.tooHard);
      expect(c.tooFast, isTrue);
      expect(c.paceCompliance, 0);
      expect(c.speedRatio, greaterThan(1.1));
    });

    test('right pace but HR too high', () {
      final c = ComplianceEvaluator.evaluate(
        workout: easyRun(40),
        profile: profile,
        samples: synth([part(2400, easy, 162)]),
      );
      expect(c.steps.single.verdict, StepVerdict.hrTooHigh);
      expect(c.verdict, SessionVerdict.tooHard);
      expect(c.hrTooHigh, isTrue);
      expect(c.hrCompliance, 0);
    });

    test('done too slowly', () {
      final c = ComplianceEvaluator.evaluate(
        workout: easyRun(40),
        profile: profile,
        samples: synth([part(2400, 2.3, 120)]),
      );
      expect(c.steps.single.verdict, StepVerdict.tooSlow);
      expect(c.verdict, SessionVerdict.tooEasy);
    });

    test('cut short is incomplete', () {
      final c = ComplianceEvaluator.evaluate(
        workout: easyRun(60),
        profile: profile,
        samples: synth([part(1200, easy, 140)]),
      );
      expect(c.steps.single.verdict, StepVerdict.notCompleted);
      expect(c.completion, closeTo(1200 / 3600, 0.01));
      expect(c.verdict, SessionVerdict.incomplete);
    });

    test('no samples at all', () {
      final c = ComplianceEvaluator.evaluate(
        workout: easyRun(30),
        profile: profile,
        samples: const [],
      );
      expect(c.completion, 0);
      expect(c.verdict, SessionVerdict.incomplete);
    });
  });

  group('intervals', () {
    test('aligned by laps', () {
      final parts = intervalParts();
      final c = ComplianceEvaluator.evaluate(
        workout: intervals(),
        profile: profile,
        samples: synth(parts),
        laps: lapsFor(parts),
      );
      expect(c.alignment, StepAlignment.laps);
      expect(c.steps, hasLength(10));
      expect(c.completion, closeTo(1, 1e-9));
      expect(c.verdict, SessionVerdict.onTarget);
      expect(c.steps[1].avgSpeed, closeTo(interval, 0.01));
      expect(c.steps[1].avgHr, closeTo(172, 0.5));
      expect(
          c.workSteps.every((s) => s.verdict == StepVerdict.onTarget), isTrue);
      expect(c.efficiencyFactor, isNull, reason: 'hard session is not steady');
    });

    test('aligned by time without laps', () {
      final c = ComplianceEvaluator.evaluate(
        workout: intervals(),
        profile: profile,
        samples: synth(intervalParts()),
      );
      expect(c.alignment, StepAlignment.time);
      expect(c.verdict, SessionVerdict.onTarget);
      expect(c.steps[7].avgSpeed, closeTo(interval, 0.01));
      expect(c.paceCompliance, closeTo(1, 1e-9));
    });

    test('autolaps of another length fall back to time alignment', () {
      final samples = synth(intervalParts());
      final km = [
        for (var i = 0; i < 10; i++)
          LapSegment(startSecond: i * 150, durationS: 150),
      ];
      final c = ComplianceEvaluator.evaluate(
        workout: intervals(),
        profile: profile,
        samples: samples,
        laps: km,
      );
      expect(c.alignment, StepAlignment.time);
      expect(c.verdict, SessionVerdict.onTarget);
    });

    test('reps run too slowly', () {
      final slow = profile.speedFor(Intensity.interval).lower * 0.9;
      final parts = intervalParts(hard: slow);
      final c = ComplianceEvaluator.evaluate(
        workout: intervals(),
        profile: profile,
        samples: synth(parts),
        laps: lapsFor(parts),
      );
      expect(
          c.workSteps.every((s) => s.verdict == StepVerdict.tooSlow), isTrue);
      expect(c.verdict, SessionVerdict.tooEasy);
    });

    test('stopped after two reps', () {
      final c = ComplianceEvaluator.evaluate(
        workout: intervals(),
        profile: profile,
        samples: synth(intervalParts(reps: 2, cooldown: false)),
      );
      final verdicts = [for (final s in c.steps) s.verdict];
      expect(verdicts.sublist(5), everyElement(StepVerdict.notCompleted));
      expect(verdicts.take(5), everyElement(StepVerdict.onTarget));
      expect(c.completion, closeTo(1200 / 2100, 0.01));
      expect(c.verdict, SessionVerdict.incomplete);
    });

    test('distance steps align by the distance stream', () {
      final workout = Workout(
        sport: Sport.run,
        title: '3 × 1 km',
        elements: [
          const WorkoutStep(
            kind: StepKind.warmup,
            end: TimeEnd(Duration(minutes: 5)),
            target: IntensityTarget(Intensity.easy),
          ),
          RepeatBlock(
            times: 3,
            elements: const [
              WorkoutStep(
                kind: StepKind.active,
                end: DistanceEnd(1000),
                target: IntensityTarget(Intensity.interval),
              ),
              WorkoutStep(
                kind: StepKind.recovery,
                end: TimeEnd(Duration(seconds: 90)),
              ),
            ],
          ),
        ],
      );
      final secPerKm = (1000 / interval).round();
      final c = ComplianceEvaluator.evaluate(
        workout: workout,
        profile: profile,
        samples: synth([
          part(300, easy, 135),
          for (var i = 0; i < 3; i++) ...[
            part(secPerKm, 1000 / secPerKm, 170),
            part(90, 2.0, 150),
          ],
        ]),
      );
      expect(c.verdict, SessionVerdict.onTarget);
      expect(c.completion, closeTo(1, 1e-6));
      expect(c.steps[5].avgSpeed, closeTo(1000 / secPerKm, 0.01));
    });
  });

  test('long steady run reports efficiency and decoupling', () {
    final c = ComplianceEvaluator.evaluate(
      workout: easyRun(90),
      profile: profile,
      samples: synth([part(2700, easy, 138), part(2700, easy, 152)]),
    );
    expect(c.verdict, SessionVerdict.onTarget);
    expect(c.efficiencyFactor, isNotNull);
    expect(c.decoupling, closeTo(9.5, 1.0));
  });

  test('short steady run has no decoupling', () {
    final c = ComplianceEvaluator.evaluate(
      workout: easyRun(30),
      profile: profile,
      samples: synth([part(1800, easy, 140)]),
    );
    expect(c.efficiencyFactor, isNotNull);
    expect(c.decoupling, isNull);
  });

  test('strength steps are ignored', () {
    final w = Workout(
      sport: Sport.combined,
      title: 'Run + core',
      elements: [
        const WorkoutStep(
          kind: StepKind.active,
          end: TimeEnd(Duration(minutes: 30)),
          target: IntensityTarget(Intensity.easy),
        ),
        const WorkoutStep(
          kind: StepKind.strength,
          end: LapButtonEnd(),
          estimate: Duration(minutes: 15),
        ),
      ],
    );
    final c = ComplianceEvaluator.evaluate(
      workout: w,
      profile: profile,
      samples: synth([part(1800, easy, 140)]),
    );
    expect(c.steps, hasLength(1));
    expect(c.verdict, SessionVerdict.onTarget);
  });

  test('JSON round-trips', () {
    final parts = intervalParts();
    final c = ComplianceEvaluator.evaluate(
      workout: intervals(),
      profile: profile,
      samples: synth(parts),
      laps: lapsFor(parts),
    );
    final json = jsonDecode(jsonEncode(c.toJson())) as Map<String, Object?>;
    expect(json['v'], 1);
    expect(json['verdict'], 'onTarget');
    final back = SessionCompliance.fromJson(json);
    expect(back.toJson(), json);
    expect(back.steps[1].speedTarget!.lower,
        closeTo(profile.speedFor(Intensity.interval).lower, 1e-3));
    expect(back.steps[1].intensity, Intensity.interval);
  });
}
