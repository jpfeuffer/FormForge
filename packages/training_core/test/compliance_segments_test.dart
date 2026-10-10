import 'package:test/test.dart';
import 'package:training_core/training_core.dart';

import 'synthetic_samples.dart';

void main() {
  final profile = PaceProfile.fromVdot(50, lthr: 170);
  final easy = profile.speedFor(Intensity.easy).mid;
  final interval = profile.speedFor(Intensity.interval).mid;

  // warm-up 10 min, 4 × (3 min hard / 2 min jog), cool-down 5 min.
  final workout = Workout(
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

  List<Part> run({int warmup = 600, int reps = 4}) => [
        part(warmup, easy, 135),
        for (var i = 0; i < reps; i++) ...[
          part(180, interval, 172),
          part(120, 2.3, 150),
        ],
        part(300, easy, 140),
      ];

  test('late start of the reps is aligned by effort segments', () {
    final c = ComplianceEvaluator.evaluate(
      workout: workout,
      profile: profile,
      samples: synth(run(warmup: 900)),
    );
    expect(c.alignment, StepAlignment.segments);
    expect(c.verdict, SessionVerdict.onTarget);
    expect(c.completion, closeTo(1, 0.02));
    expect(c.steps[1].avgSpeed, closeTo(interval, 0.05));
    expect(c.steps[1].startSecond, closeTo(900, 8));
    expect(c.workSteps.every((s) => s.verdict == StepVerdict.onTarget), isTrue);
  });

  test('time alignment is kept when the run follows the plan', () {
    final c = ComplianceEvaluator.evaluate(
      workout: workout,
      profile: profile,
      samples: synth(run()),
    );
    expect(c.alignment, StepAlignment.time);
    expect(c.verdict, SessionVerdict.onTarget);
  });

  test('skipped warm-up is tolerated', () {
    final c = ComplianceEvaluator.evaluate(
      workout: workout,
      profile: profile,
      samples: synth(run(warmup: 0)),
    );
    expect(c.alignment, StepAlignment.segments);
    expect(c.steps.first.verdict, StepVerdict.notCompleted);
    expect(c.steps[1].avgSpeed, closeTo(interval, 0.05));
  });

  test('segment count that differs from the plan keeps time alignment', () {
    final c = ComplianceEvaluator.evaluate(
      workout: workout,
      profile: profile,
      samples: synth(run(reps: 2)),
    );
    expect(c.alignment, StepAlignment.time);
    expect(c.verdict, SessionVerdict.incomplete);
  });
}
