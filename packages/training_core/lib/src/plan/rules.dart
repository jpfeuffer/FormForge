import 'dart:math';

import 'request.dart';

enum Phase { base, build, peak, taper }

/// Goal distance bucket used to pick rules and templates.
enum RaceCategory {
  fiveK,
  tenK,
  half,
  marathon,
  ultra50,
  ultra100;

  static RaceCategory of(double meters) => meters <= 7500
      ? fiveK
      : meters <= 16000
          ? tenK
          : meters <= 32000
              ? half
              : meters <= 46000
                  ? marathon
                  : meters <= 75000
                      ? ultra50
                      : ultra100;

  bool get isShort => index <= tenK.index;
  bool get isUltra => index >= ultra50.index;
}

/// Periodization and guardrail numbers shared by generator and validator.
abstract final class PlanRules {
  static const maxWeeklyRamp = 0.10;
  static const recoveryVolumeFactor = 0.75;
  static const maxHardFraction = 0.25;

  /// Slack for rounding when comparing durations.
  static const tolerance = Duration(minutes: 1);
  static const minRun = Duration(minutes: 20);

  static int recoveryCycle(Experience e) => e == Experience.beginner ? 3 : 4;

  static double weeklyGrowth(Experience e) =>
      e == Experience.beginner ? 0.08 : maxWeeklyRamp;

  static int maxRunDays(Experience e) => switch (e) {
        Experience.beginner => 4,
        Experience.intermediate => 5,
        Experience.advanced => 6,
      };

  static int maxQualityPerWeek(Experience e) =>
      e == Experience.advanced ? 3 : 2;

  /// Long run share of weekly volume; low-frequency runners and
  /// marathon/ultra goals get more room.
  static double longRunShareCap(int runDays, RaceCategory c) {
    if (runDays <= 2) return 0.50;
    final base = runDays >= 5
        ? 0.30
        : runDays == 4
            ? 0.35
            : 0.40;
    return base + (c.index >= RaceCategory.marathon.index ? 0.05 : 0);
  }

  static Duration longRunCap(RaceCategory c) => Duration(
          minutes: switch (c) {
        RaceCategory.fiveK => 90,
        RaceCategory.tenK => 105,
        RaceCategory.half => 135,
        RaceCategory.marathon => 180,
        RaceCategory.ultra50 => 210,
        RaceCategory.ultra100 => 240,
      });

  /// Weekly long-run growth limit in minutes.
  static int longRunStep(RaceCategory c) => c.isUltra ? 20 : 15;

  /// Target peak weekly running volume.
  static Duration peakVolume(RaceCategory c, Experience e) {
    final hours = switch (c) {
      RaceCategory.fiveK => (3.0, 4.5, 6.5),
      RaceCategory.tenK => (3.5, 5.0, 7.0),
      RaceCategory.half => (4.0, 5.5, 7.5),
      RaceCategory.marathon => (5.0, 7.0, 9.0),
      RaceCategory.ultra50 => (6.0, 8.0, 10.0),
      RaceCategory.ultra100 => (7.0, 9.5, 12.0),
    };
    final h = switch (e) {
      Experience.beginner => hours.$1,
      Experience.intermediate => hours.$2,
      Experience.advanced => hours.$3,
    };
    return Duration(minutes: (h * 60).round());
  }

  static int minPlanWeeks(RaceCategory c) => switch (c) {
        RaceCategory.fiveK => 6,
        RaceCategory.tenK => 8,
        RaceCategory.half => 10,
        RaceCategory.marathon => 12,
        RaceCategory.ultra50 => 14,
        RaceCategory.ultra100 => 16,
      };

  /// Realistic VDOT gain per week of training.
  static double vdotGainPerWeek(Experience e) => switch (e) {
        Experience.beginner => 1 / 3,
        Experience.intermediate => 1 / 3.5,
        Experience.advanced => 1 / 4,
      };

  /// Taper volume factors, each relative to the previous week.
  static List<double> taperFactors(RaceCategory c, int weeks) => switch (c) {
        RaceCategory.fiveK || RaceCategory.tenK => const [0.65],
        RaceCategory.half => const [0.85, 0.65],
        RaceCategory.marathon =>
          weeks >= 16 ? const [0.85, 0.8, 0.6] : const [0.75, 0.6],
        RaceCategory.ultra50 =>
          weeks >= 12 ? const [0.85, 0.8, 0.6] : const [0.8, 0.6],
        RaceCategory.ultra100 => weeks >= 20
            ? const [0.9, 0.85, 0.75, 0.6]
            : weeks >= 12
                ? const [0.85, 0.8, 0.6]
                : const [0.8, 0.6],
      };

  static int taperWeeks(RaceCategory c, int weeks) =>
      min(taperFactors(c, weeks).length, weeks - 1);

  static List<Phase> phases(int weeks, RaceCategory c) {
    final taper = taperWeeks(c, weeks);
    final r = weeks - taper;
    final (fb, fp) = switch (c) {
      RaceCategory.fiveK || RaceCategory.tenK => (0.35, 0.25),
      RaceCategory.half || RaceCategory.marathon => (0.40, 0.25),
      _ => (0.45, 0.20),
    };
    final peak = r >= 2 ? max(1, (r * fp).round()) : r;
    final base = r >= 3 ? max(1, (r * fb).round()) : 0;
    final build = r - base - peak;
    return [
      for (var i = 0; i < base; i++) Phase.base,
      for (var i = 0; i < build; i++) Phase.build,
      for (var i = 0; i < peak; i++) Phase.peak,
      for (var i = 0; i < taper; i++) Phase.taper,
    ];
  }

  /// Every [recoveryCycle]th week, never the last week before the taper.
  static Set<int> recoveryWeeks(List<Phase> phases, Experience e) {
    final cycle = recoveryCycle(e);
    return {
      for (var i = cycle - 1; i + 1 < phases.length; i += cycle)
        if (phases[i + 1] != Phase.taper) i
    };
  }
}
