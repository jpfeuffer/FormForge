import 'package:test/test.dart';
import 'package:training_core/training_core.dart';

import 'synthetic_samples.dart';

List<Pause> pausesOf(List<Sample> samples) => Pauses.detect(
      [for (final s in samples) s.second],
      [for (final s in samples) s.speed],
    );

/// Appends [b] after a recording gap of [seconds] without samples.
List<Sample> withGap(List<Sample> a, int seconds, List<Sample> b) {
  final dt = a.last.second + seconds;
  final dd = a.last.distance!;
  return [
    ...a,
    for (final s in b.skip(1))
      Sample(
        second: s.second + dt,
        speed: s.speed,
        hr: s.hr,
        distance: s.distance! + dd,
      ),
  ];
}

void main() {
  final profile = PaceProfile.fromVdot(50, lthr: 170);
  final easy = profile.speedFor(Intensity.easy).mid;
  final tempo = profile.speedFor(Intensity.threshold).mid;
  final rep = profile.speedFor(Intensity.interval).mid;

  group('EffortSegmenter', () {
    test('10 × 200 m with jog recoveries', () {
      final repSeconds = (200 / rep).round();
      final samples = synth([
        part(600, easy),
        for (var i = 0; i < 10; i++) ...[
          part(repSeconds, 200 / repSeconds),
          if (i < 9) part(60, 2.3),
        ],
        part(300, easy),
      ]);
      final segments = EffortSegmenter.segment(
        samples,
        profile,
        pauses: pausesOf(samples),
      );
      final hard = segments.where((s) => s.hard).toList();
      expect(hard, hasLength(10));
      expect(segments, hasLength(21));
      for (final s in hard) {
        expect(s.durationS, closeTo(repSeconds, 8));
        expect(s.distance, closeTo(200, 40));
        expect(s.avgSpeed, closeTo(rep, 0.5));
      }
      expect(segments.first.hard, isFalse);
      expect(segments.last.hard, isFalse);
    });

    test('tempo run', () {
      final samples = synth([
        part(600, easy),
        part(1200, tempo),
        part(600, easy),
      ]);
      final segments = EffortSegmenter.segment(samples, profile);
      expect([for (final s in segments) s.hard], [false, true, false]);
      expect(segments[1].durationS, closeTo(1200, 12));
      expect(segments[1].startSecond, closeTo(600, 8));
    });

    test('easy run is a single easy segment', () {
      final samples = synth([part(1800, easy)]);
      final segments = EffortSegmenter.segment(samples, profile);
      expect(segments, hasLength(1));
      expect(segments.single.hard, isFalse);
      expect(segments.single.movingS, closeTo(1800, 2));
    });

    test('short surges and wobble do not split an easy run', () {
      final samples = synth([
        part(600, easy),
        part(8, rep),
        part(600, easy),
        part(15, tempo),
        part(600, easy),
      ]);
      final segments = EffortSegmenter.segment(samples, profile);
      expect(segments, hasLength(1));
      expect(segments.single.hard, isFalse);
    });

    test('traffic-light stop and watch pause are ignored, not split', () {
      final run = withGap(
        synth([part(600, easy), part(30, 0), part(600, easy)]),
        120,
        synth([part(300, easy)]),
      );
      final pauses = pausesOf(run);
      expect(pauses.map((p) => p.kind), [PauseKind.stopped, PauseKind.paused]);
      final segments = EffortSegmenter.segment(run, profile, pauses: pauses);
      expect(segments, hasLength(1));
      expect(segments.single.hard, isFalse);
      expect(segments.single.movingS, closeTo(1500, 15));
      expect(segments.single.durationS, closeTo(1650, 5));
      expect(segments.single.avgSpeed, closeTo(easy, 0.05));
    });

    test('hard blocks on both sides of a rest stay separate', () {
      final run = synth([
        part(300, easy),
        part(120, tempo),
        part(60, 0),
        part(120, tempo),
        part(300, easy),
      ]);
      final segments = EffortSegmenter.segment(
        run,
        profile,
        pauses: pausesOf(run),
      );
      expect([for (final s in segments) s.hard], [false, true, true, false]);
    });

    test('empty and tiny input', () {
      expect(EffortSegmenter.segment(const [], profile), isEmpty);
      expect(
        EffortSegmenter.segment([const Sample(second: 0, speed: 3)], profile),
        isEmpty,
      );
    });
  });
}
