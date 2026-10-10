enum PauseKind {
  /// Watch timer stopped (manual or auto pause), or a recording gap.
  paused,

  /// Timer running but not moving, e.g. waiting at a traffic light.
  stopped,
}

final class Pause {
  const Pause(this.start, this.end, this.kind);

  /// Seconds since activity start.
  final int start;
  final int end;
  final PauseKind kind;

  int get seconds => end - start;

  /// Seconds of this pause inside [from]..[to].
  int overlap(num from, num to) {
    final s = start < from ? from : start;
    final e = end > to ? to : end;
    return e > s ? (e - s).round() : 0;
  }

  @override
  bool operator ==(Object other) =>
      other is Pause &&
      other.start == start &&
      other.end == end &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(start, end, kind);

  @override
  String toString() => 'Pause(${kind.name} $start–$end)';
}

typedef TimeSplit = ({int elapsed, int paused, int stopped, int moving});

abstract final class Pauses {
  /// Longer gaps between samples count as a pause (smart recording leaves
  /// gaps of a few seconds while running).
  static const maxGap = 15;

  /// Slower than this counts as standing still (m/s).
  static const stopSpeed = 0.5;
  static const minStop = 15;

  /// [timerStops] are the watch's stop→start intervals in seconds since start;
  /// without them, recording gaps longer than [maxGap] count as paused.
  static List<Pause> detect(
    List<int> seconds,
    List<double?>? speed, {
    List<(int, int)>? timerStops,
  }) {
    final paused = timerStops != null
        ? [
            for (final (a, b) in timerStops)
              if (b > a) Pause(a, b, PauseKind.paused),
          ]
        : [
            for (var i = 1; i < seconds.length; i++)
              if (seconds[i] - seconds[i - 1] > maxGap)
                Pause(seconds[i - 1], seconds[i], PauseKind.paused),
          ];

    final stopped = <Pause>[];
    if (speed != null) {
      int? runStart;
      void close(int i) {
        if (runStart != null && seconds[i] - seconds[runStart!] >= minStop) {
          stopped.add(Pause(seconds[runStart!], seconds[i], PauseKind.stopped));
        }
        runStart = null;
      }

      for (var i = 0; i < seconds.length; i++) {
        final gap = i > 0 && seconds[i] - seconds[i - 1] > maxGap;
        if (gap) close(i - 1);
        final v = speed[i];
        if (v != null && v < stopSpeed) {
          runStart ??= i;
        } else if (runStart != null) {
          close(i);
        }
      }
      if (seconds.isNotEmpty) close(seconds.length - 1);
    }

    final all = [
      ...paused,
      for (final s in stopped)
        if (!paused.any((p) => p.overlap(s.start, s.end) > 0)) s,
    ]..sort((a, b) => a.start.compareTo(b.start));
    return all;
  }

  /// Elapsed, paused, stopped and moving seconds within [from]..[to].
  static TimeSplit split(List<Pause> pauses, num from, num to) {
    var paused = 0, stopped = 0;
    for (final p in pauses) {
      final o = p.overlap(from, to);
      if (p.kind == PauseKind.paused) {
        paused += o;
      } else {
        stopped += o;
      }
    }
    final elapsed = (to - from).round();
    return (
      elapsed: elapsed,
      paused: paused,
      stopped: stopped,
      moving: elapsed - paused - stopped,
    );
  }
}
