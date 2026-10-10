import 'dart:typed_data';

import 'package:fit_io/fit_io.dart';
import 'package:training_core/training_core.dart';

import '../workout_resolve.dart';

const _maxFitNameLength = 24;
const _maxFileSlugLength = 20;

/// Planned workout as FIT workout file for the watch.
FitWorkout toFitWorkout(
  Workout workout, {
  PaceProfile? profile,
  String? title,
}) {
  final steps = <FitWorkoutStep>[];
  for (final e in flattenNestedRepeats(workout.elements)) {
    switch (e) {
      case WorkoutStep():
        steps.add(_step(e, profile));
      case RepeatBlock():
        final first = steps.length;
        steps.addAll([
          for (final s in e.elements.whereType<WorkoutStep>())
            _step(s, profile),
        ]);
        steps.add(FitWorkoutStep.repeat(fromStep: first, times: e.times));
    }
  }
  final strengthOnly = workout.sport == Sport.strength;
  return FitWorkout(
    name: _cut(title ?? workout.title, _maxFitNameLength),
    sport: strengthOnly ? FitSport.training : FitSport.running,
    subSport: strengthOnly ? FitSubSport.strengthTraining : null,
    steps: steps,
  );
}

FitWorkoutStep _step(WorkoutStep step, PaceProfile? profile) {
  final intensity = switch (step.kind) {
    StepKind.warmup => FitIntensity.warmup,
    StepKind.active => FitIntensity.active,
    StepKind.recovery => FitIntensity.recovery,
    StepKind.cooldown => FitIntensity.cooldown,
    StepKind.rest || StepKind.strength => FitIntensity.rest,
  };
  final duration = switch (step.end) {
    TimeEnd(:final duration) => FitTimeDuration(duration),
    DistanceEnd(:final meters) => FitDistanceDuration(meters),
    LapButtonEnd() => const FitOpenDuration(),
  };
  final target = switch (resolveTarget(step.target, profile)) {
    (kind: BandKind.speed, :final low, :final high) => FitSpeedTarget(
      low,
      high,
    ),
    (kind: BandKind.heartRate, :final low, :final high) => FitHeartRateTarget(
      low.round(),
      high.round(),
    ),
    null => const FitOpenTarget(),
  };
  final note = step.note?.trim();
  return FitWorkoutStep(
    name: step.kind == StepKind.strength ? 'Strength' : null,
    intensity: intensity,
    duration: duration,
    target: target,
    notes: note == null || note.isEmpty ? null : note,
  );
}

String _cut(String s, int max) {
  final t = s.trim();
  return t.length > max ? t.substring(0, max).trimRight() : t;
}

/// `FF_yyyyMMdd_title.fit` using only characters that every Garmin firmware accepts.
String fitFileName(DateTime date, String title, {int? duplicateIndex}) {
  final day =
      '${date.year.toString().padLeft(4, '0')}'
      '${date.month.toString().padLeft(2, '0')}'
      '${date.day.toString().padLeft(2, '0')}';
  var slug = _slug(title);
  if (slug.length > _maxFileSlugLength) {
    slug = slug.substring(0, _maxFileSlugLength).replaceAll(RegExp(r'_+$'), '');
  }
  if (slug.isEmpty) slug = 'workout';
  final suffix = duplicateIndex == null ? '' : '_$duplicateIndex';
  return 'FF_${day}_$slug$suffix.fit';
}

const _transliterations = {
  'ä': 'ae',
  'ö': 'oe',
  'ü': 'ue',
  'Ä': 'Ae',
  'Ö': 'Oe',
  'Ü': 'Ue',
  'ß': 'ss',
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'é': 'e',
  'è': 'e',
  'ê': 'e',
  'ë': 'e',
  'í': 'i',
  'ì': 'i',
  'î': 'i',
  'ó': 'o',
  'ò': 'o',
  'ô': 'o',
  'ú': 'u',
  'ù': 'u',
  'û': 'u',
  'ç': 'c',
  'ñ': 'n',
  'å': 'a',
  'ø': 'o',
  'æ': 'ae',
};

String _slug(String title) {
  final ascii = title.split('').map((c) => _transliterations[c] ?? c).join();
  return ascii
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
}

class FitWorkoutFile {
  const FitWorkoutFile(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}
