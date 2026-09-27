import 'vdot.dart';
import 'strength.dart';
import 'zone.dart';

enum Sport { run, strength, combined }

enum StepKind { warmup, active, recovery, rest, cooldown, strength }

/// Symbolic intensity, resolved against a [PaceProfile] at execution time.
enum Intensity {
  recovery,
  easy,
  marathon,
  threshold,
  interval,
  repetition,

  /// Goal race pace of the plan.
  racePace,
}

enum TestType { timeTrial3k, timeTrial5k, halfCooper, friel30 }

/// Athlete-specific speed (m/s) and optional HR (bpm) bands per [Intensity].
final class PaceProfile {
  PaceProfile(Map<Intensity, Zone> speeds,
      {Map<Intensity, Zone>? heartRate, required this.vdotEquivalent})
      : _speeds = Map.unmodifiable(speeds),
        _heartRate = heartRate == null ? null : Map.unmodifiable(heartRate) {
    for (final i in Intensity.values) {
      if (!_speeds.containsKey(i)) {
        throw ArgumentError('Missing speed zone for $i');
      }
    }
  }

  /// Daniels-based profile. Race pace: [raceSpeed], else the VDOT
  /// prediction for [raceMeters], else marathon pace.
  factory PaceProfile.fromVdot(double vdot,
      {double? raceSpeed, double? raceMeters, double? lthr}) {
    final z = Vdot.trainingZones(vdot);
    return PaceProfile({
      Intensity.recovery: Zone('Recovery', Vdot.speedForVo2(vdot * 0.52),
          Vdot.speedForVo2(vdot * 0.60)),
      Intensity.easy: z[DanielsIntensity.easy]!,
      Intensity.marathon: z[DanielsIntensity.marathon]!,
      Intensity.threshold: z[DanielsIntensity.threshold]!,
      Intensity.interval: z[DanielsIntensity.interval]!,
      Intensity.repetition: z[DanielsIntensity.repetition]!,
      Intensity.racePace: _raceZone(vdot, raceSpeed, raceMeters) ??
          z[DanielsIntensity.marathon]!,
    }, heartRate: lthr == null ? null : _hrZones(lthr), vdotEquivalent: vdot);
  }

  /// %MAS-based profile for athletes with only a half-Cooper result.
  factory PaceProfile.fromMas(double mas,
      {double? raceSpeed, double? raceMeters, double? lthr}) {
    Zone band(String name, double lo, double hi) =>
        Zone(name, mas * lo, mas * hi);
    final vdot = vdotFromMas(mas);
    return PaceProfile({
      Intensity.recovery: band('Recovery', 0.60, 0.65),
      Intensity.easy: band('Easy', 0.65, 0.75),
      Intensity.marathon: band('Marathon', 0.78, 0.84),
      Intensity.threshold: band('Threshold', 0.85, 0.90),
      Intensity.interval: band('Interval', 0.95, 1.05),
      Intensity.repetition: band('Repetition', 1.05, 1.15),
      Intensity.racePace:
          _raceZone(vdot, raceSpeed, raceMeters) ?? band('Race', 0.78, 0.84),
    }, heartRate: lthr == null ? null : _hrZones(lthr), vdotEquivalent: vdot);
  }

  /// Prefers [vdot]; falls back to [mas].
  factory PaceProfile.fromFitness(
      {double? vdot,
      double? mas,
      double? raceSpeed,
      double? raceMeters,
      double? lthr}) {
    if (vdot != null) {
      return PaceProfile.fromVdot(vdot,
          raceSpeed: raceSpeed, raceMeters: raceMeters, lthr: lthr);
    }
    if (mas != null) {
      return PaceProfile.fromMas(mas,
          raceSpeed: raceSpeed, raceMeters: raceMeters, lthr: lthr);
    }
    throw ArgumentError('Either vdot or mas is required');
  }

  /// VDOT whose vVO2max equals [mas] (m/s).
  static double vdotFromMas(double mas) => Vdot.oxygenCost(mas * 60);

  final Map<Intensity, Zone> _speeds;
  final Map<Intensity, Zone>? _heartRate;
  final double vdotEquivalent;

  Zone speedFor(Intensity intensity) => _speeds[intensity]!;

  Zone? heartRateFor(Intensity intensity) => _heartRate?[intensity];

  double get thresholdSpeed => speedFor(Intensity.threshold).mid;

  /// Faster than marathon pace counts as "hard" for the 80/20 split.
  bool isHard(double speed) => speed > speedFor(Intensity.marathon).upper;

  static Zone? _raceZone(double vdot, double? speed, double? meters) {
    final v = speed ??
        (meters == null
            ? null
            : meters / (Vdot.predictTime(vdot, meters).inMilliseconds / 1000));
    return v == null ? null : Zone('Race pace', v * 0.99, v * 1.01);
  }

  static Map<Intensity, Zone> _hrZones(double lthr) {
    Zone band(String name, double lo, double hi) =>
        Zone(name, lthr * lo, lthr * hi);
    return {
      Intensity.recovery: band('Recovery', 0.70, 0.85),
      Intensity.easy: band('Easy', 0.80, 0.89),
      Intensity.marathon: band('Marathon', 0.89, 0.94),
      Intensity.threshold: band('Threshold', 0.95, 1.00),
      Intensity.interval: band('Interval', 1.00, 1.06),
      Intensity.repetition: band('Repetition', 1.03, 1.15),
    };
  }
}

sealed class StepEnd {
  const StepEnd();

  Map<String, Object?> toJson();

  static StepEnd fromJson(Map<String, Object?> json) => switch (json['type']) {
        'time' => TimeEnd(Duration(seconds: (json['seconds'] as num).toInt())),
        'distance' => DistanceEnd((json['meters'] as num).toDouble()),
        'lap' => const LapButtonEnd(),
        final t => throw FormatException('Unknown step end', t),
      };
}

final class TimeEnd extends StepEnd {
  const TimeEnd(this.duration);
  final Duration duration;

  @override
  Map<String, Object?> toJson() =>
      {'type': 'time', 'seconds': duration.inSeconds};
}

final class DistanceEnd extends StepEnd {
  const DistanceEnd(this.meters) : assert(meters > 0);
  final double meters;

  @override
  Map<String, Object?> toJson() => {'type': 'distance', 'meters': meters};
}

final class LapButtonEnd extends StepEnd {
  const LapButtonEnd();

  @override
  Map<String, Object?> toJson() => {'type': 'lap'};
}

sealed class Target {
  const Target();

  Map<String, Object?> toJson();

  static Target fromJson(Map<String, Object?> json) => switch (json['type']) {
        'none' => const NoTarget(),
        'speed' => SpeedTarget(_zoneFromJson(json['zone'])),
        'heartRate' => HeartRateTarget(_zoneFromJson(json['zone'])),
        'intensity' =>
          IntensityTarget(Intensity.values.byName(json['intensity'] as String)),
        final t => throw FormatException('Unknown target', t),
      };

  static Map<String, Object?> _zoneToJson(Zone z) =>
      {'name': z.name, 'lower': z.lower, 'upper': z.upper};

  static Zone _zoneFromJson(Object? json) {
    final m = json as Map<String, Object?>;
    return Zone(m['name'] as String, (m['lower'] as num).toDouble(),
        (m['upper'] as num).toDouble());
  }
}

final class NoTarget extends Target {
  const NoTarget();

  @override
  Map<String, Object?> toJson() => {'type': 'none'};
}

/// Absolute speed band in m/s.
final class SpeedTarget extends Target {
  const SpeedTarget(this.zone);
  final Zone zone;

  @override
  Map<String, Object?> toJson() =>
      {'type': 'speed', 'zone': Target._zoneToJson(zone)};
}

/// Absolute heart-rate band in bpm.
final class HeartRateTarget extends Target {
  const HeartRateTarget(this.zone);
  final Zone zone;

  @override
  Map<String, Object?> toJson() =>
      {'type': 'heartRate', 'zone': Target._zoneToJson(zone)};
}

final class IntensityTarget extends Target {
  const IntensityTarget(this.intensity);
  final Intensity intensity;

  @override
  Map<String, Object?> toJson() =>
      {'type': 'intensity', 'intensity': intensity.name};
}

sealed class WorkoutElement {
  const WorkoutElement();

  /// Steps with repeats expanded.
  Iterable<WorkoutStep> get steps;

  Map<String, Object?> toJson();

  static WorkoutElement fromJson(Map<String, Object?> json) =>
      switch (json['type']) {
        'step' => WorkoutStep.fromJson(json),
        'repeat' => RepeatBlock.fromJson(json),
        final t => throw FormatException('Unknown workout element', t),
      };
}

final class WorkoutStep extends WorkoutElement {
  const WorkoutStep({
    required this.kind,
    required this.end,
    this.target = const NoTarget(),
    this.note,
    this.estimate,
  });

  factory WorkoutStep.fromJson(Map<String, Object?> json) => WorkoutStep(
        kind: StepKind.values.byName(json['kind'] as String),
        end: StepEnd.fromJson(json['end'] as Map<String, Object?>),
        target: json['target'] == null
            ? const NoTarget()
            : Target.fromJson(json['target'] as Map<String, Object?>),
        note: json['note'] as String?,
        estimate: json['estimateSeconds'] == null
            ? null
            : Duration(seconds: (json['estimateSeconds'] as num).toInt()),
      );

  final StepKind kind;
  final StepEnd end;
  final Target target;
  final String? note;

  /// Nominal duration for lap-button, strength or all-out distance steps.
  final Duration? estimate;

  bool get isMoving => kind != StepKind.rest && kind != StepKind.strength;

  @override
  Iterable<WorkoutStep> get steps => [this];

  /// Planned speed (m/s) used for estimates; null when not moving.
  double? plannedSpeed(PaceProfile profile) {
    if (!isMoving) return null;
    return switch (target) {
      SpeedTarget(:final zone) => zone.mid,
      IntensityTarget(:final intensity) => profile.speedFor(intensity).mid,
      NoTarget() || HeartRateTarget() => profile
          .speedFor(
              kind == StepKind.recovery ? Intensity.recovery : Intensity.easy)
          .mid,
    };
  }

  Duration estimatedDuration(PaceProfile profile) {
    if (end case TimeEnd(:final duration)) return duration;
    if (estimate case final e?) return e;
    if (end case DistanceEnd(:final meters)) {
      final v = plannedSpeed(profile);
      if (v != null) return Duration(milliseconds: (meters / v * 1000).round());
    }
    return Duration.zero;
  }

  double estimatedDistance(PaceProfile profile) {
    if (!isMoving) return 0;
    if (end case DistanceEnd(:final meters)) return meters;
    return plannedSpeed(profile)! * _seconds(estimatedDuration(profile));
  }

  /// Average speed implied by the estimates (m/s); null when not moving.
  double? effectiveSpeed(PaceProfile profile) {
    if (!isMoving) return null;
    final s = _seconds(estimatedDuration(profile));
    return s == 0 ? plannedSpeed(profile) : estimatedDistance(profile) / s;
  }

  @override
  Map<String, Object?> toJson() => {
        'type': 'step',
        'kind': kind.name,
        'end': end.toJson(),
        'target': target.toJson(),
        if (note != null) 'note': note,
        if (estimate != null) 'estimateSeconds': estimate!.inSeconds,
      };
}

final class RepeatBlock extends WorkoutElement {
  RepeatBlock({required this.times, required List<WorkoutElement> elements})
      : elements = List.unmodifiable(elements) {
    if (times < 1) throw ArgumentError.value(times, 'times');
  }

  factory RepeatBlock.fromJson(Map<String, Object?> json) => RepeatBlock(
        times: (json['times'] as num).toInt(),
        elements: [
          for (final e in json['elements'] as List)
            WorkoutElement.fromJson(e as Map<String, Object?>)
        ],
      );

  final int times;
  final List<WorkoutElement> elements;

  @override
  Iterable<WorkoutStep> get steps sync* {
    for (var i = 0; i < times; i++) {
      for (final e in elements) {
        yield* e.steps;
      }
    }
  }

  @override
  Map<String, Object?> toJson() => {
        'type': 'repeat',
        'times': times,
        'elements': [for (final e in elements) e.toJson()],
      };
}

/// A structured session: run, strength or both.
final class Workout {
  Workout({
    required this.sport,
    required this.title,
    required List<WorkoutElement> elements,
    List<FocusArea> focusAreas = const [],
    this.notes,
    this.test,
  })  : elements = List.unmodifiable(elements),
        focusAreas = List.unmodifiable(focusAreas);

  static const version = 1;

  /// Intensity factor assumed for strength steps in [estimatedLoad].
  static const strengthIntensityFactor = 0.7;

  factory Workout.fromJson(Map<String, Object?> json) {
    final v = json['v'];
    if (v != version) {
      throw FormatException('Unsupported workout version', v);
    }
    return Workout(
      sport: Sport.values.byName(json['sport'] as String),
      title: json['title'] as String,
      elements: [
        for (final e in json['elements'] as List)
          WorkoutElement.fromJson(e as Map<String, Object?>)
      ],
      focusAreas: [
        for (final f in (json['focusAreas'] as List?) ?? const [])
          FocusArea.values.byName(f as String)
      ],
      notes: json['notes'] as String?,
      test: json['test'] == null
          ? null
          : TestType.values.byName(json['test'] as String),
    );
  }

  final Sport sport;
  final String title;
  final List<WorkoutElement> elements;
  final List<FocusArea> focusAreas;
  final String? notes;

  /// Set when this workout is a fitness test.
  final TestType? test;

  bool get isTest => test != null;

  Iterable<WorkoutStep> get steps => elements.expand((e) => e.steps);

  List<WorkoutStep> flatten() => steps.toList();

  Duration estimatedDuration(PaceProfile profile) => _sum(steps, profile);

  /// Duration excluding strength steps.
  Duration estimatedRunDuration(PaceProfile profile) =>
      _sum(steps.where((s) => s.kind != StepKind.strength), profile);

  /// Moving time faster than marathon pace.
  Duration estimatedHardDuration(PaceProfile profile) => _sum(steps.where((s) {
        final v = s.effectiveSpeed(profile);
        return v != null && profile.isHard(v);
      }), profile);

  double estimatedDistance(PaceProfile profile) =>
      steps.fold(0.0, (a, s) => a + s.estimatedDistance(profile));

  /// rTSS-like load: hours × IF² × 100 with IF = speed / threshold speed.
  double estimatedLoad(PaceProfile profile) {
    var load = 0.0;
    for (final s in steps) {
      final hours = _seconds(s.estimatedDuration(profile)) / 3600;
      final intensityFactor = s.kind == StepKind.strength
          ? strengthIntensityFactor
          : (s.effectiveSpeed(profile) ?? 0) / profile.thresholdSpeed;
      load += hours * intensityFactor * intensityFactor * 100;
    }
    return load;
  }

  Map<String, Object?> toJson() => {
        'v': version,
        'sport': sport.name,
        'title': title,
        if (focusAreas.isNotEmpty)
          'focusAreas': [for (final f in focusAreas) f.name],
        if (notes != null) 'notes': notes,
        if (test != null) 'test': test!.name,
        'elements': [for (final e in elements) e.toJson()],
      };

  static Duration _sum(Iterable<WorkoutStep> steps, PaceProfile p) =>
      steps.fold(Duration.zero, (a, s) => a + s.estimatedDuration(p));
}

double _seconds(Duration d) =>
    d.inMicroseconds / Duration.microsecondsPerSecond;
