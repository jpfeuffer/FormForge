import 'package:test/test.dart';
import 'package:training_core/training_core.dart';

void main() {
  test('recording gaps count as pauses without timer events', () {
    final seconds = [0, 1, 2, 3, 63, 64, 65];
    expect(Pauses.detect(seconds, null), [const Pause(3, 63, PauseKind.paused)]);
  });

  test('timer events take precedence over gaps', () {
    final seconds = [0, 1, 2, 40, 41];
    expect(Pauses.detect(seconds, null, timerStops: [(2, 30)]),
        [const Pause(2, 30, PauseKind.paused)]);
  });

  test('standing still while the timer runs', () {
    final seconds = [for (var s = 0; s <= 120; s++) s];
    final speed = [for (final s in seconds) s >= 40 && s < 70 ? 0.1 : 3.0];
    expect(Pauses.detect(seconds, speed),
        [const Pause(40, 70, PauseKind.stopped)]);
  });

  test('short stops are ignored', () {
    final seconds = [for (var s = 0; s <= 60; s++) s];
    final speed = [for (final s in seconds) s >= 20 && s < 25 ? 0.0 : 3.0];
    expect(Pauses.detect(seconds, speed), isEmpty);
  });

  test('split within a range', () {
    const pauses = [
      Pause(100, 160, PauseKind.paused),
      Pause(300, 330, PauseKind.stopped),
    ];
    expect(Pauses.split(pauses, 0, 600),
        (elapsed: 600, paused: 60, stopped: 30, moving: 510));
    expect(Pauses.split(pauses, 130, 310),
        (elapsed: 180, paused: 30, stopped: 10, moving: 140));
  });

  test('a pause gap does not weight the next sample', () {
    final samples = [
      for (var s = 0; s <= 600; s++) Sample(second: s, speed: 3.0, hr: 140),
      // After a 10-minute pause: one fast sample that would dominate.
      for (var s = 1200; s <= 1210; s++) Sample(second: s, speed: 5.0, hr: 140),
    ];
    final ef = RunEvaluation.efficiencyFactor(samples)!;
    expect(ef, closeTo(3.0 * 60 / 140, 0.05));
  });
}
