import 'dart:math';

import 'evaluation.dart';
import 'sample_series.dart';
import 'workout.dart';
import 'zone.dart';

enum StepVerdict { onTarget, tooFast, tooSlow, hrTooHigh, notCompleted }

enum SessionVerdict { onTarget, tooHard, tooEasy, incomplete }

/// A recorded lap; times share the time base of the samples.
final class LapSegment {
  const LapSegment({
    required this.startSecond,
    required this.durationS,
    this.distanceM,
    this.avgHr,
  });

  final int startSecond;
  final int durationS;
  final double? distanceM;
  final int? avgHr;
}

/// How one workout step was executed.
final class StepCompliance {
  const StepCompliance({
    required this.index,
    required this.kind,
    required this.verdict,
    required this.coverage,
    this.intensity,
    this.plannedSeconds,
    this.plannedMeters,
    this.speedTarget,
    this.hrTarget,
    this.startSecond,
    this.endSecond,
    this.avgSpeed,
    this.avgHr,
    this.paceInTarget,
    this.hrInTarget,
  });

  factory StepCompliance.fromJson(Map<String, Object?> json) => StepCompliance(
        index: (json['index'] as num).toInt(),
        kind: StepKind.values.byName(json['kind'] as String),
        verdict: StepVerdict.values.byName(json['verdict'] as String),
        coverage: (json['coverage'] as num).toDouble(),
        intensity: switch (json['intensity']) {
          final String n => Intensity.values.byName(n),
          _ => null,
        },
        plannedSeconds: (json['plannedSeconds'] as num?)?.toDouble(),
        plannedMeters: (json['plannedMeters'] as num?)?.toDouble(),
        speedTarget: _zone(json['speedTarget']),
        hrTarget: _zone(json['hrTarget']),
        startSecond: (json['startSecond'] as num?)?.toDouble(),
        endSecond: (json['endSecond'] as num?)?.toDouble(),
        avgSpeed: (json['avgSpeed'] as num?)?.toDouble(),
        avgHr: (json['avgHr'] as num?)?.toDouble(),
        paceInTarget: (json['paceInTarget'] as num?)?.toDouble(),
        hrInTarget: (json['hrInTarget'] as num?)?.toDouble(),
      );

  /// Position among the non-strength steps of the flattened workout.
  final int index;
  final StepKind kind;
  final StepVerdict verdict;

  /// Executed share of the planned step, 0–1.
  final double coverage;
  final Intensity? intensity;
  final double? plannedSeconds;
  final double? plannedMeters;

  /// Resolved target bands: speed in m/s, heart rate in bpm.
  final Zone? speedTarget;
  final Zone? hrTarget;
  final double? startSecond;
  final double? endSecond;
  final double? avgSpeed;
  final double? avgHr;

  /// Fraction (0–1) of the step spent inside the speed / HR band.
  final double? paceInTarget;
  final double? hrInTarget;

  Map<String, Object?> toJson() => {
        'index': index,
        'kind': kind.name,
        'verdict': verdict.name,
        'coverage': _r(coverage),
        if (intensity != null) 'intensity': intensity!.name,
        if (plannedSeconds != null) 'plannedSeconds': _r(plannedSeconds!, 1),
        if (plannedMeters != null) 'plannedMeters': _r(plannedMeters!, 1),
        if (speedTarget != null) 'speedTarget': _zoneJson(speedTarget!),
        if (hrTarget != null) 'hrTarget': _zoneJson(hrTarget!),
        if (startSecond != null) 'startSecond': _r(startSecond!, 1),
        if (endSecond != null) 'endSecond': _r(endSecond!, 1),
        if (avgSpeed != null) 'avgSpeed': _r(avgSpeed!),
        if (avgHr != null) 'avgHr': _r(avgHr!, 1),
        if (paceInTarget != null) 'paceInTarget': _r(paceInTarget!),
        if (hrInTarget != null) 'hrInTarget': _r(hrInTarget!),
      };
}

/// Executed-versus-planned evaluation of a whole run workout.
final class SessionCompliance {
  const SessionCompliance({
    required this.steps,
    required this.completion,
    required this.verdict,
    required this.alignment,
    this.paceCompliance,
    this.hrCompliance,
    this.speedRatio,
    this.efficiencyFactor,
    this.decoupling,
  });

  factory SessionCompliance.fromJson(Map<String, Object?> json) {
    if (json['v'] != version) {
      throw FormatException('Unsupported compliance version', json['v']);
    }
    return SessionCompliance(
      steps: [
        for (final s in json['steps'] as List)
          StepCompliance.fromJson((s as Map).cast<String, Object?>()),
      ],
      completion: (json['completion'] as num).toDouble(),
      verdict: SessionVerdict.values.byName(json['verdict'] as String),
      alignment: StepAlignment.values.byName(json['alignment'] as String),
      paceCompliance: (json['paceCompliance'] as num?)?.toDouble(),
      hrCompliance: (json['hrCompliance'] as num?)?.toDouble(),
      speedRatio: (json['speedRatio'] as num?)?.toDouble(),
      efficiencyFactor: (json['efficiencyFactor'] as num?)?.toDouble(),
      decoupling: (json['decoupling'] as num?)?.toDouble(),
    );
  }

  static const version = 1;

  final List<StepCompliance> steps;

  /// Planned time actually executed, 0–1.
  final double completion;
  final SessionVerdict verdict;
  final StepAlignment alignment;

  /// Time-in-target (0–1) over the work steps; null without a band / data.
  final double? paceCompliance;
  final double? hrCompliance;

  /// Actual / planned speed over the work steps; > 1 means faster than planned.
  final double? speedRatio;

  /// Only for steady (non-hard) runs.
  final double? efficiencyFactor;

  /// Pa:HR in percent; only for steady runs of 40+ minutes.
  final double? decoupling;

  Iterable<StepCompliance> get workSteps =>
      steps.where((s) => s.kind == StepKind.active);

  bool get tooFast => workSteps.any((s) => s.verdict == StepVerdict.tooFast);
  bool get hrTooHigh =>
      workSteps.any((s) => s.verdict == StepVerdict.hrTooHigh);

  Map<String, Object?> toJson() => {
        'v': version,
        'verdict': verdict.name,
        'alignment': alignment.name,
        'completion': _r(completion),
        if (paceCompliance != null) 'paceCompliance': _r(paceCompliance!),
        if (hrCompliance != null) 'hrCompliance': _r(hrCompliance!),
        if (speedRatio != null) 'speedRatio': _r(speedRatio!),
        if (efficiencyFactor != null) 'efficiencyFactor': _r(efficiencyFactor!),
        if (decoupling != null) 'decoupling': _r(decoupling!, 1),
        'steps': [for (final s in steps) s.toJson()],
      };
}

/// How executed segments were matched to workout steps.
enum StepAlignment { laps, time }

abstract final class ComplianceEvaluator {
  /// A step counts as executed from this share of its planned size.
  static const completedCoverage = 0.85;

  /// Below this overall completion the session is [SessionVerdict.incomplete].
  static const incompleteBelow = 0.75;

  /// Relative slack around a speed band before a step is too fast / slow.
  static const speedTolerance = 0.03;

  /// Relative slack above the HR band.
  static const hrTolerance = 0.03;

  /// HR is only judged on work steps at least this long (HR lags pace).
  static const minHrStep = Duration(minutes: 3);

  /// Share of work time needed for a session-level too hard / too easy verdict.
  static const verdictShare = 0.5;

  static const _minEfSeconds = 20 * 60;
  static const _minDecouplingSeconds = 40 * 60;

  /// Aligns [samples] (and [laps], preferred when they match the step
  /// structure) to the run steps of [workout]; strength steps are ignored.
  static SessionCompliance evaluate({
    required Workout workout,
    required PaceProfile profile,
    required List<Sample> samples,
    List<LapSegment> laps = const [],
  }) {
    final steps = [
      for (final s in workout.flatten())
        if (s.kind != StepKind.strength) s,
    ];
    final series = SampleSeries(samples);
    final useLaps = _lapsFit(steps, laps, profile);
    final segments = useLaps
        ? _fromLaps(steps, laps, series)
        : _fromTime(steps, series, profile);

    final results = <StepCompliance>[];
    final weights = <double>[];
    for (var i = 0; i < steps.length; i++) {
      final (result, weight) = _step(
        i,
        steps[i],
        segments[i],
        series,
        profile,
      );
      results.add(result);
      weights.add(weight);
    }
    return _summarize(
      steps,
      results,
      weights,
      samples,
      profile,
      useLaps ? StepAlignment.laps : StepAlignment.time,
    );
  }

  static bool _lapsFit(
    List<WorkoutStep> steps,
    List<LapSegment> laps,
    PaceProfile profile,
  ) {
    if (steps.length < 2 || (laps.length - steps.length).abs() > 1) {
      return false;
    }
    var mismatches = 0;
    for (var i = 0; i < min(steps.length, laps.length); i++) {
      if (steps[i].end is LapButtonEnd) continue;
      final planned = steps[i].estimatedDuration(profile).inSeconds;
      if (planned == 0) continue;
      if ((laps[i].durationS - planned).abs() > max(30, planned * 0.35)) {
        mismatches++;
      }
    }
    return mismatches <= steps.length ~/ 10;
  }

  static List<_Segment?> _fromLaps(
    List<WorkoutStep> steps,
    List<LapSegment> laps,
    SampleSeries series,
  ) =>
      [
        for (var i = 0; i < steps.length; i++)
          if (i >= laps.length)
            null
          else
            _lapSegment(steps[i], laps[i], series),
      ];

  static _Segment _lapSegment(
    WorkoutStep step,
    LapSegment lap,
    SampleSeries series,
  ) {
    final start = lap.startSecond.toDouble();
    final end = start + lap.durationS;
    final meters = lap.distanceM ??
        (series.isEmpty
            ? null
            : series.distanceAt(end) - series.distanceAt(start));
    final coverage = switch (step.end) {
      TimeEnd(:final duration) => lap.durationS / duration.inSeconds,
      DistanceEnd(meters: final planned) =>
        meters == null ? 1.0 : meters / planned,
      LapButtonEnd() => 1.0,
    };
    return _Segment(
      start,
      end,
      min(1, coverage),
      speed:
          meters != null && lap.durationS > 0 ? meters / lap.durationS : null,
      hr: lap.avgHr?.toDouble(),
    );
  }

  static List<_Segment?> _fromTime(
    List<WorkoutStep> steps,
    SampleSeries series,
    PaceProfile profile,
  ) {
    if (series.isEmpty) return List.filled(steps.length, null);
    final last = series.t.last;
    var cursor = series.t.first;
    final result = <_Segment?>[];
    for (final step in steps) {
      if (cursor >= last - 1) {
        result.add(null);
        continue;
      }
      final start = cursor;
      final double end;
      final double coverage;
      switch (step.end) {
        case TimeEnd(:final duration):
          end = start + duration.inSeconds;
          coverage = (min(end, last) - start) / duration.inSeconds;
        case DistanceEnd(:final meters):
          final target = series.distanceAt(start) + meters;
          end = series.secondAtDistance(target) ?? double.infinity;
          coverage =
              (series.distanceAt(min(end, last)) - series.distanceAt(start)) /
                  meters;
        case LapButtonEnd():
          final planned = step.estimatedDuration(profile).inSeconds;
          end = planned == 0 ? last : start + planned;
          coverage = planned == 0 ? 1 : (min(end, last) - start) / planned;
      }
      cursor = min(end, last);
      result.add(_Segment(start, cursor, min(1, coverage)));
    }
    return result;
  }

  static (StepCompliance, double) _step(
    int index,
    WorkoutStep step,
    _Segment? seg,
    SampleSeries series,
    PaceProfile profile,
  ) {
    final (:speed, :hr) = _bands(step, profile);
    final plannedSeconds = switch (step.end) {
      TimeEnd(:final duration) => duration.inSeconds.toDouble(),
      _ => step.estimatedDuration(profile).inSeconds.toDouble(),
    };
    final plannedMeters = switch (step.end) {
      DistanceEnd(:final meters) => meters,
      _ => null,
    };
    final intensity = switch (step.target) {
      IntensityTarget(:final intensity) => intensity,
      _ => null,
    };
    final seconds = seg == null ? 0.0 : seg.end - seg.start;
    final weight = plannedSeconds > 0 ? plannedSeconds : max(seconds, 1.0);

    if (seg == null || seconds <= 0 || seg.coverage < completedCoverage) {
      return (
        StepCompliance(
          index: index,
          kind: step.kind,
          verdict: StepVerdict.notCompleted,
          coverage: seg?.coverage ?? 0,
          intensity: intensity,
          plannedSeconds: plannedSeconds > 0 ? plannedSeconds : null,
          plannedMeters: plannedMeters,
          speedTarget: speed,
          hrTarget: hr,
          startSecond: seg?.start,
          endSecond: seg?.end,
        ),
        weight,
      );
    }

    final avgSpeed = series.avgSpeed(seg.start, seg.end) ?? seg.speed;
    final avgHr = series.avgHr(seg.start, seg.end) ?? seg.hr;
    double? inBand(Zone? zone, {required bool heartRate}) {
      if (zone == null) return null;
      final (:inside, :total) = series.timeInBand(
        seg.start,
        seg.end,
        zone,
        heartRate: heartRate,
      );
      return total == 0 ? null : inside / total;
    }

    final verdict = _verdict(
      step,
      speed,
      hr,
      avgSpeed,
      avgHr,
      seconds,
    );
    return (
      StepCompliance(
        index: index,
        kind: step.kind,
        verdict: verdict,
        coverage: seg.coverage,
        intensity: intensity,
        plannedSeconds: plannedSeconds > 0 ? plannedSeconds : null,
        plannedMeters: plannedMeters,
        speedTarget: speed,
        hrTarget: hr,
        startSecond: seg.start,
        endSecond: seg.end,
        avgSpeed: avgSpeed,
        avgHr: avgHr,
        paceInTarget: inBand(speed, heartRate: false),
        hrInTarget: inBand(hr, heartRate: true),
      ),
      weight,
    );
  }

  static ({Zone? speed, Zone? hr}) _bands(
    WorkoutStep step,
    PaceProfile profile,
  ) =>
      switch (step.target) {
        SpeedTarget(:final zone) => (speed: zone, hr: null),
        HeartRateTarget(:final zone) => (speed: null, hr: zone),
        IntensityTarget(:final intensity) => (
            speed: profile.speedFor(intensity),
            hr: profile.heartRateFor(intensity),
          ),
        NoTarget() => (speed: null, hr: null),
      };

  static StepVerdict _verdict(
    WorkoutStep step,
    Zone? speed,
    Zone? hr,
    double? avgSpeed,
    double? avgHr,
    double seconds,
  ) {
    if (step.kind == StepKind.recovery || step.kind == StepKind.rest) {
      return StepVerdict.onTarget;
    }
    if (speed != null &&
        avgSpeed != null &&
        avgSpeed > speed.upper * (1 + speedTolerance)) {
      return StepVerdict.tooFast;
    }
    if (hr != null &&
        avgHr != null &&
        step.kind == StepKind.active &&
        seconds >= minHrStep.inSeconds &&
        avgHr > hr.upper * (1 + hrTolerance)) {
      return StepVerdict.hrTooHigh;
    }
    if (speed != null &&
        avgSpeed != null &&
        avgSpeed < speed.lower * (1 - speedTolerance)) {
      return StepVerdict.tooSlow;
    }
    return StepVerdict.onTarget;
  }

  static SessionCompliance _summarize(
    List<WorkoutStep> steps,
    List<StepCompliance> results,
    List<double> weights,
    List<Sample> samples,
    PaceProfile profile,
    StepAlignment alignment,
  ) {
    final total = weights.fold(0.0, (a, b) => a + b);
    var done = 0.0;
    for (var i = 0; i < results.length; i++) {
      done += weights[i] * min(1, results[i].coverage);
    }
    final completion = total == 0 ? 0.0 : done / total;

    double? weighted(
      Iterable<int> idx,
      double? Function(StepCompliance) value,
    ) {
      var sum = 0.0, w = 0.0;
      for (final i in idx) {
        final v = value(results[i]);
        if (v == null) continue;
        sum += v * weights[i];
        w += weights[i];
      }
      return w == 0 ? null : sum / w;
    }

    final work = [
      for (var i = 0; i < results.length; i++)
        if (results[i].kind == StepKind.active &&
            results[i].verdict != StepVerdict.notCompleted)
          i,
    ];
    double share(bool Function(StepVerdict) test) {
      var hit = 0.0, all = 0.0;
      for (final i in work) {
        all += weights[i];
        if (test(results[i].verdict)) hit += weights[i];
      }
      return all == 0 ? 0 : hit / all;
    }

    final verdict = completion < incompleteBelow
        ? SessionVerdict.incomplete
        : share((v) =>
                    v == StepVerdict.tooFast || v == StepVerdict.hrTooHigh) >=
                verdictShare
            ? SessionVerdict.tooHard
            : share((v) => v == StepVerdict.tooSlow) >= verdictShare
                ? SessionVerdict.tooEasy
                : SessionVerdict.onTarget;

    final (ef, decoupling) = _steadyMetrics(steps, results, samples, profile);
    return SessionCompliance(
      steps: results,
      completion: completion,
      verdict: verdict,
      alignment: alignment,
      paceCompliance: weighted(work, (s) => s.paceInTarget),
      hrCompliance: weighted(work, (s) => s.hrInTarget),
      speedRatio: weighted(
        work,
        (s) => s.avgSpeed != null && s.speedTarget != null
            ? s.avgSpeed! / s.speedTarget!.mid
            : null,
      ),
      efficiencyFactor: ef,
      decoupling: decoupling,
    );
  }

  /// EF and decoupling over the work part of runs that contain no hard step.
  static (double?, double?) _steadyMetrics(
    List<WorkoutStep> steps,
    List<StepCompliance> results,
    List<Sample> samples,
    PaceProfile profile,
  ) {
    final active = [
      for (final r in results)
        if (r.kind == StepKind.active && r.startSecond != null) r,
    ];
    if (active.isEmpty) return (null, null);
    final steady = active.every((r) {
      final v = r.speedTarget?.mid;
      return v == null || !profile.isHard(v);
    });
    if (!steady) return (null, null);
    final from = active.map((r) => r.startSecond!).reduce(min);
    final to = active.map((r) => r.endSecond!).reduce(max);
    final window = [
      for (final s in samples)
        if (s.second >= from && s.second <= to) s,
    ];
    final length = to - from;
    return (
      length >= _minEfSeconds ? RunEvaluation.efficiencyFactor(window) : null,
      length >= _minDecouplingSeconds
          ? RunEvaluation.aerobicDecoupling(window)
          : null,
    );
  }
}

final class _Segment {
  const _Segment(this.start, this.end, this.coverage, {this.speed, this.hr});

  final double start;
  final double end;
  final double coverage;

  /// Lap-reported fallbacks for when no samples cover the segment.
  final double? speed;
  final double? hr;
}

Map<String, Object?> _zoneJson(Zone z) => {
      'lower': _r(z.lower),
      'upper': _r(z.upper),
    };

Zone? _zone(Object? json) => switch (json) {
      {'lower': final num lo, 'upper': final num hi} => Zone(
          'target',
          lo.toDouble(),
          hi.toDouble(),
        ),
      _ => null,
    };

double _r(double v, [int digits = 3]) {
  final f = pow(10, digits);
  return (v * f).round() / f;
}
