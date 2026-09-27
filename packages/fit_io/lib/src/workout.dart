import 'dart:typed_data';

import 'activity.dart';
import 'base_type.dart';
import 'decoder.dart';
import 'profile.dart';
import 'writer.dart';

sealed class FitStepDuration {
  const FitStepDuration();
}

final class FitTimeDuration extends FitStepDuration {
  const FitTimeDuration(this.duration);
  final Duration duration;
}

final class FitDistanceDuration extends FitStepDuration {
  const FitDistanceDuration(this.meters);
  final double meters;
}

/// Ends when the lap button is pressed.
final class FitOpenDuration extends FitStepDuration {
  const FitOpenDuration();
}

/// Jumps back to step index [fromStep] until it ran [times] times in total.
final class FitRepeatDuration extends FitStepDuration {
  const FitRepeatDuration({required this.fromStep, required this.times});
  final int fromStep;
  final int times;
}

sealed class FitStepTarget {
  const FitStepTarget();
}

final class FitOpenTarget extends FitStepTarget {
  const FitOpenTarget();
}

/// Speed range in m/s.
final class FitSpeedTarget extends FitStepTarget {
  const FitSpeedTarget(this.low, this.high);
  final double low;
  final double high;
}

/// Heart-rate range in bpm.
final class FitHeartRateTarget extends FitStepTarget {
  const FitHeartRateTarget(this.low, this.high);
  final int low;
  final int high;
}

class FitWorkoutStep {
  const FitWorkoutStep({
    this.name,
    this.intensity = FitIntensity.active,
    required this.duration,
    this.target = const FitOpenTarget(),
    this.notes,
  });

  FitWorkoutStep.repeat({required int fromStep, required int times})
      : this(
            duration: FitRepeatDuration(fromStep: fromStep, times: times),
            intensity: null);

  final String? name;

  /// `null` for repeat steps.
  final FitIntensity? intensity;
  final FitStepDuration duration;
  final FitStepTarget target;
  final String? notes;
}

class FitWorkout {
  const FitWorkout({
    required this.name,
    this.sport = FitSport.running,
    this.subSport,
    required this.steps,
  });

  final String name;
  final FitSport sport;
  final int? subSport;
  final List<FitWorkoutStep> steps;

  /// Encodes a workout file (e.g. for GARMIN/NewFiles on a watch).
  Uint8List encode({DateTime? timeCreated, int serialNumber = 1}) {
    final w = FitWriter()
      ..write(FitMesgNum.fileId, [
        const FitField(
            FitFileIdField.type, FitBaseType.enumType, FitFileType.workout),
        const FitField(FitFileIdField.manufacturer, FitBaseType.uint16,
            FitManufacturer.development),
        const FitField(FitFileIdField.product, FitBaseType.uint16, 0),
        FitField(
            FitFileIdField.serialNumber, FitBaseType.uint32z, serialNumber),
        FitField(FitFileIdField.timeCreated, FitBaseType.uint32,
            toFitDateTime(timeCreated ?? DateTime.now())),
      ])
      ..write(FitMesgNum.workout, [
        FitField(FitWorkoutField.sport, FitBaseType.enumType, sport.value),
        FitField(FitWorkoutField.subSport, FitBaseType.enumType, subSport),
        FitField(
            FitWorkoutField.numValidSteps, FitBaseType.uint16, steps.length),
        FitField(FitWorkoutField.wktName, FitBaseType.string, name),
      ]);
    for (final (i, s) in steps.indexed) {
      w.write(FitMesgNum.workoutStep, [
        FitField(FitCommonField.messageIndex, FitBaseType.uint16, i),
        ..._stepFields(s),
      ]);
    }
    return w.finish();
  }

  static List<FitField> _stepFields(FitWorkoutStep s) {
    const f = FitField.new;
    final (durationType, durationValue, repeatTimes) = switch (s.duration) {
      FitTimeDuration(:final duration) => (
          FitDurationType.time,
          duration.inMilliseconds,
          null
        ),
      FitDistanceDuration(:final meters) => (
          FitDurationType.distance,
          (meters * 100).round(),
          null
        ),
      FitOpenDuration() => (FitDurationType.open, null, null),
      FitRepeatDuration(:final fromStep, :final times) => (
          FitDurationType.repeatUntilStepsComplete,
          fromStep,
          times
        ),
    };
    final (targetType, low, high) = repeatTimes != null
        ? (null, null, null)
        : switch (s.target) {
            FitOpenTarget() => (FitTargetType.open, null, null),
            FitSpeedTarget(:final low, :final high) => (
                FitTargetType.speed,
                (low * 1000).round(),
                (high * 1000).round()
              ),
            FitHeartRateTarget(:final low, :final high) => (
                FitTargetType.heartRate,
                low + 100,
                high + 100
              ),
          };
    return [
      f(FitWorkoutStepField.wktStepName, FitBaseType.string, s.name),
      f(FitWorkoutStepField.durationType, FitBaseType.enumType, durationType),
      f(FitWorkoutStepField.durationValue, FitBaseType.uint32, durationValue),
      f(FitWorkoutStepField.targetType, FitBaseType.enumType, targetType),
      f(FitWorkoutStepField.targetValue, FitBaseType.uint32,
          repeatTimes ?? (low != null ? 0 : null)),
      f(FitWorkoutStepField.customTargetValueLow, FitBaseType.uint32, low),
      f(FitWorkoutStepField.customTargetValueHigh, FitBaseType.uint32, high),
      f(FitWorkoutStepField.intensity, FitBaseType.enumType,
          s.intensity?.value),
      f(FitWorkoutStepField.notes, FitBaseType.string, s.notes),
    ];
  }

  /// Reads the workout of a decoded file; `null` if it has none.
  static FitWorkout? fromFile(FitFile file) {
    final w = file.byNum(FitMesgNum.workout).firstOrNull;
    if (w == null) return null;
    final steps = file.byNum(FitMesgNum.workoutStep).toList()
      ..sort((a, b) => (a.intValue(FitCommonField.messageIndex) ?? 0)
          .compareTo(b.intValue(FitCommonField.messageIndex) ?? 0));
    return FitWorkout(
      name: w.stringValue(FitWorkoutField.wktName) ?? '',
      sport: FitSport.fromValue(w.intValue(FitWorkoutField.sport)) ??
          FitSport.generic,
      subSport: w.intValue(FitWorkoutField.subSport),
      steps: steps.map(_parseStep).toList(),
    );
  }

  static FitWorkoutStep _parseStep(FitMessage m) {
    final value = m.intValue(FitWorkoutStepField.durationValue);
    final targetValue = m.intValue(FitWorkoutStepField.targetValue);
    final duration =
        switch ((m.intValue(FitWorkoutStepField.durationType), value)) {
      (FitDurationType.time, final int v) =>
        FitTimeDuration(Duration(milliseconds: v)),
      (FitDurationType.distance, final int v) => FitDistanceDuration(v / 100),
      (FitDurationType.repeatUntilStepsComplete, final int v) =>
        FitRepeatDuration(fromStep: v, times: targetValue ?? 1),
      _ => const FitOpenDuration(),
    };
    final custom = (targetValue ?? 0) == 0;
    final target = switch ((
      m.intValue(FitWorkoutStepField.targetType),
      m.intValue(FitWorkoutStepField.customTargetValueLow),
      m.intValue(FitWorkoutStepField.customTargetValueHigh),
    )) {
      (FitTargetType.speed, final int low, final int high) when custom =>
        FitSpeedTarget(low / 1000, high / 1000),
      (FitTargetType.heartRate, final int low, final int high)
          when custom && low > 100 && high > 100 =>
        FitHeartRateTarget(low - 100, high - 100),
      _ => const FitOpenTarget(),
    };
    return FitWorkoutStep(
      name: m.stringValue(FitWorkoutStepField.wktStepName),
      intensity:
          FitIntensity.fromValue(m.intValue(FitWorkoutStepField.intensity)),
      duration: duration,
      target: target,
      notes: m.stringValue(FitWorkoutStepField.notes),
    );
  }
}
