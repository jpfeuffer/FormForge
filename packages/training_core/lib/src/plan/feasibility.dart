import '../performance.dart';
import '../vdot.dart';
import '../workout.dart';
import 'request.dart';
import 'rules.dart';

/// Compares the target time with what current fitness predicts.
final class Feasibility {
  const Feasibility({
    required this.currentVdot,
    required this.predictedTime,
    required this.achievableVdot,
    required this.raceSpeed,
    this.targetTime,
    this.requiredVdot,
  });

  factory Feasibility.assess(PlanRequest r) {
    final current = r.fitness.vdot ?? PaceProfile.vdotFromMas(r.fitness.mas!);
    final achievable =
        current + r.weekCount * PlanRules.vdotGainPerWeek(r.experience);
    final target = r.targetTime;
    final needed = target == null
        ? null
        : Vdot.fromPerformance(
            RunPerformance(meters: r.goalMeters, time: target));
    double speedAt(double vdot) =>
        r.goalMeters /
        (Vdot.predictTime(vdot, r.goalMeters).inMilliseconds / 1000);
    return Feasibility(
      currentVdot: current,
      predictedTime: Vdot.predictTime(current, r.goalMeters),
      achievableVdot: achievable,
      targetTime: target,
      requiredVdot: needed,
      raceSpeed: target == null
          ? speedAt(current)
          : needed! <= achievable
              ? r.goalMeters / (target.inMilliseconds / 1000)
              : speedAt(achievable),
    );
  }

  final double currentVdot;
  final Duration predictedTime;
  final Duration? targetTime;
  final double? requiredVdot;

  /// Current VDOT plus a realistic gain over the plan length.
  final double achievableVdot;

  /// Goal race pace (m/s) used for [Intensity.racePace]; capped at the
  /// achievable fitness when the target is unrealistic.
  final double raceSpeed;

  bool get isRealistic =>
      requiredVdot == null || requiredVdot! <= achievableVdot;

  double? get requiredGain =>
      requiredVdot == null ? null : requiredVdot! - currentVdot;
}
