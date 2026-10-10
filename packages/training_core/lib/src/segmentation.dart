import 'dart:math';

import 'evaluation.dart';
import 'pauses.dart';
import 'sample_series.dart';
import 'workout.dart';

/// A stretch of a run at constant effort class (hard or easy).
final class EffortSegment {
  const EffortSegment({
    required this.startSecond,
    required this.endSecond,
    required this.movingS,
    required this.avgSpeed,
    required this.hard,
    this.distance,
  });

  final int startSecond;
  final int endSecond;

  /// Seconds inside the span that were neither paused nor standing still.
  final int movingS;

  /// Metres covered while moving.
  final double? distance;

  /// Metres per second while moving.
  final double avgSpeed;
  final bool hard;

  int get durationS => endSecond - startSecond;

  @override
  String toString() =>
      'EffortSegment(${hard ? 'hard' : 'easy'} $startSecond–$endSecond)';
}

/// Splits a run into hard and easy stretches, relative to a [PaceProfile].
abstract final class EffortSegmenter {
  /// Rolling mean window for the speed signal, in seconds.
  static const smoothing = 10;

  static const minHardSeconds = 20;
  static const minEasySeconds = 20;

  /// Hard starts above marathon pace and ends again below the middle between
  /// the easy and marathon band, so pace wobble does not split a block.
  static ({double enter, double exit}) thresholds(PaceProfile profile) {
    final enter = profile.speedFor(Intensity.marathon).upper;
    final exit = (profile.speedFor(Intensity.easy).upper + enter) / 2;
    return (enter: enter, exit: min(exit, enter));
  }

  /// [pauses] (see [Pauses.detect]) and sample gaps are excluded; easy
  /// segments on both sides of a pause are joined, hard ones are not.
  static List<EffortSegment> segment(
    List<Sample> samples,
    PaceProfile profile, {
    List<Pause> pauses = const [],
  }) {
    final series = SampleSeries(samples);
    if (series.length < 2) return const [];
    final from = series.t.first.ceil(), to = series.t.last.floor();
    if (to - from < 1) return const [];

    final (:enter, :exit) = thresholds(profile);
    final valid = _validSeconds(series, pauses, from, to);
    const half = smoothing / 2;
    final labels = List<int>.filled(to - from, _pause);
    var hard = false;
    for (var s = from; s < to; s++) {
      if (!valid[s - from]) {
        hard = false;
        continue;
      }
      final a = max(from.toDouble(), s + 0.5 - half);
      final b = min(to.toDouble(), s + 0.5 + half);
      final v =
          b > a ? (series.distanceAt(b) - series.distanceAt(a)) / (b - a) : 0;
      hard = hard ? v >= exit : v >= enter;
      labels[s - from] = hard ? _hard : _easy;
    }

    final runs = _merge(_runs(labels, from), valid, from);
    return [
      for (final r in runs)
        if (r.label != _pause) _build(r, series, valid, from),
    ];
  }

  static const _pause = -1, _easy = 0, _hard = 1;

  static List<bool> _validSeconds(
    SampleSeries series,
    List<Pause> pauses,
    int from,
    int to,
  ) {
    final valid = List<bool>.filled(to - from, true);
    void mark(num a, num b) {
      for (var s = max(a.ceil(), from); s < min(b.ceil(), to); s++) {
        valid[s - from] = false;
      }
    }

    for (final p in pauses) {
      mark(p.start, p.end);
    }
    for (var i = 1; i < series.length; i++) {
      if (series.t[i] - series.t[i - 1] > Pauses.maxGap) {
        mark(series.t[i - 1], series.t[i]);
      }
    }
    return valid;
  }

  static List<_Run> _runs(List<int> labels, int offset) {
    final runs = <_Run>[];
    var start = 0;
    for (var i = 1; i <= labels.length; i++) {
      if (i == labels.length || labels[i] != labels[start]) {
        runs.add(_Run(offset + start, offset + i, labels[start]));
        start = i;
      }
    }
    return runs;
  }

  /// Absorbs runs shorter than their minimum into the longer neighbour that
  /// touches them, then joins easy runs across pauses.
  static List<_Run> _merge(List<_Run> input, List<bool> valid, int from) {
    var runs = _join(input);
    while (true) {
      final short = [
        for (var i = 0; i < runs.length; i++)
          if (runs[i].label != _pause &&
              runs[i].length <
                  (runs[i].label == _hard ? minHardSeconds : minEasySeconds))
            i,
      ]..sort((a, b) => runs[a].length.compareTo(runs[b].length));
      if (short.isEmpty) break;
      final i = short.first;
      final run = runs[i];
      final left = i > 0 && runs[i - 1].label != _pause ? i - 1 : null;
      final right =
          i < runs.length - 1 && runs[i + 1].label != _pause ? i + 1 : null;
      final next = [...runs];
      if (left == null && right == null) {
        for (var s = run.start; s < run.end; s++) {
          valid[s - from] = false;
        }
        next[i] = _Run(run.start, run.end, _pause);
      } else {
        final j = left == null
            ? right!
            : right == null
                ? left
                : runs[left].length >= runs[right].length
                    ? left
                    : right;
        final t = runs[j];
        next[j] = _Run(min(t.start, run.start), max(t.end, run.end), t.label);
        next.removeAt(i);
      }
      runs = _join(next);
    }
    return _joinEasyAcrossPauses(runs);
  }

  static List<_Run> _join(List<_Run> runs) {
    final out = <_Run>[];
    for (final r in runs) {
      if (out.isNotEmpty && out.last.label == r.label) {
        out.last = _Run(out.last.start, r.end, r.label);
      } else {
        out.add(r);
      }
    }
    return out;
  }

  static List<_Run> _joinEasyAcrossPauses(List<_Run> runs) {
    final out = <_Run>[];
    for (final r in runs) {
      if (r.label == _easy &&
          out.length >= 2 &&
          out.last.label == _pause &&
          out[out.length - 2].label == _easy) {
        out.removeLast();
        final before = out.removeLast();
        out.add(_Run(before.start, r.end, _easy));
      } else {
        out.add(r);
      }
    }
    return out;
  }

  static EffortSegment _build(
    _Run r,
    SampleSeries series,
    List<bool> valid,
    int from,
  ) {
    var moving = 0;
    var meters = 0.0;
    for (var s = r.start; s < r.end; s++) {
      if (!valid[s - from]) continue;
      moving++;
      meters += series.distanceAt(s + 1.0) - series.distanceAt(s.toDouble());
    }
    return EffortSegment(
      startSecond: r.start,
      endSecond: r.end,
      movingS: moving,
      distance: meters,
      avgSpeed: moving == 0 ? 0 : meters / moving,
      hard: r.label == _hard,
    );
  }
}

final class _Run {
  const _Run(this.start, this.end, this.label);

  final int start;
  final int end;
  final int label;

  int get length => end - start;
}
