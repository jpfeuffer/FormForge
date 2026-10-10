import 'dart:convert';

import 'package:training_core/training_core.dart';

import '../../util/format.dart';

enum GoalPreset {
  k5('5K', 5000),
  k10('10K', 10000),
  half('Half marathon', 21097.5),
  marathon('Marathon', 42195),
  ultra50('50K', 50000),
  ultra100('100K', 100000),
  custom('Custom', 0);

  const GoalPreset(this.label, this.meters);

  final String label;
  final double meters;
}

enum VolumeUnit { km, hours }

enum WizardStep { goal, fitness, background, availability, strength, review }

/// Shortest plan the wizard accepts when a race date is given.
const minRaceDays = 14;
const maxWeeks = 52;

double? _number(String s) => double.tryParse(s.trim().replaceAll(',', '.'));

/// Everything the plan wizard collects. Text fields stay raw so invalid
/// input can be flagged; all `*Error` getters return null when the field is
/// fine (or empty and optional).
class WizardInputs {
  GoalPreset preset = GoalPreset.k10;
  String customKm = '';
  bool useRaceDate = false;
  DateTime? raceDate;
  int weeks = 12;
  String targetTime = '';

  double? vdot;
  double? mas;
  String lthr = '';

  /// Derive VDOT from [resultMeters] / [resultTime] instead of stored fitness.
  bool enterResult = false;
  double resultMeters = 5000;
  String resultTime = '';

  VolumeUnit unit = VolumeUnit.km;
  String weeklyVolume = '';

  /// Kilometres or minutes, depending on [unit].
  String longestRun = '';
  Experience experience = Experience.intermediate;

  Set<int> days = {
    DateTime.tuesday,
    DateTime.thursday,
    DateTime.saturday,
    DateTime.sunday,
  };
  Map<int, String> maxMinutes = {};
  int? longRunDay = DateTime.sunday;

  StrengthGoalKind strengthKind = StrengthGoalKind.none;
  Set<FocusArea> focus = {};
  int sessionsPerWeek = 2;
  StrengthStyle style = StrengthStyle.calisthenics;
  int sessionMinutes = 30;

  WizardInputs();

  factory WizardInputs.fromJson(Map<String, Object?> json) {
    final i = WizardInputs();
    if (json['v'] != 1) return i;
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.asNameMap()[name] ?? fallback;
    i
      ..preset = pick(GoalPreset.values, json['preset'], i.preset)
      ..customKm = json['customKm'] as String? ?? ''
      ..useRaceDate = json['useRaceDate'] as bool? ?? false
      ..raceDate = DateTime.tryParse(json['raceDate'] as String? ?? '')
      ..weeks = ((json['weeks'] as int?) ?? 12).clamp(3, maxWeeks)
      ..targetTime = json['targetTime'] as String? ?? ''
      ..unit = pick(VolumeUnit.values, json['unit'], i.unit)
      ..weeklyVolume = json['weeklyVolume'] as String? ?? ''
      ..longestRun = json['longestRun'] as String? ?? ''
      ..experience = pick(Experience.values, json['experience'], i.experience)
      ..days = {
        for (final d in (json['days'] as List?) ?? i.days)
          if (d is int && d >= DateTime.monday && d <= DateTime.sunday) d,
      }
      ..maxMinutes = {
        for (final e in ((json['maxMinutes'] as Map?) ?? const {}).entries)
          int.parse(e.key as String): e.value as String,
      }
      ..longRunDay = json['longRunDay'] as int?
      ..strengthKind = pick(
        StrengthGoalKind.values,
        json['strengthKind'],
        i.strengthKind,
      )
      ..focus = {
        for (final f in (json['focus'] as List?) ?? const [])
          ?FocusArea.values.asNameMap()[f],
      }
      ..sessionsPerWeek = ((json['sessionsPerWeek'] as int?) ?? 2).clamp(1, 4)
      ..style = pick(StrengthStyle.values, json['style'], i.style)
      ..sessionMinutes = ((json['sessionMinutes'] as int?) ?? 30).clamp(15, 90);
    return i;
  }

  /// Tolerates missing or broken data (returns defaults).
  static WizardInputs decode(String? json, DateTime today) {
    try {
      final i = json == null
          ? WizardInputs()
          : WizardInputs.fromJson(jsonDecode(json) as Map<String, Object?>);
      if (i.raceDate != null &&
          i.raceDate!.difference(today).inDays < minRaceDays) {
        i
          ..raceDate = null
          ..useRaceDate = false;
      }
      return i;
    } on Object {
      return WizardInputs();
    }
  }

  /// Fitness values are not stored: they come from the latest result.
  String encode() => jsonEncode({
    'v': 1,
    'preset': preset.name,
    'customKm': customKm,
    'useRaceDate': useRaceDate,
    'raceDate': raceDate?.toIso8601String(),
    'weeks': weeks,
    'targetTime': targetTime,
    'unit': unit.name,
    'weeklyVolume': weeklyVolume,
    'longestRun': longestRun,
    'experience': experience.name,
    'days': days.toList()..sort(),
    'maxMinutes': {for (final e in maxMinutes.entries) '${e.key}': e.value},
    'longRunDay': longRunDay,
    'strengthKind': strengthKind.name,
    'focus': [for (final f in focus) f.name],
    'sessionsPerWeek': sessionsPerWeek,
    'style': style.name,
    'sessionMinutes': sessionMinutes,
  });

  double? get goalMeters {
    if (preset != GoalPreset.custom) return preset.meters;
    final km = _number(customKm);
    return km == null ? null : km * 1000;
  }

  Duration? get target => parseDuration(targetTime);
  Duration? get result => parseDuration(resultTime);

  /// VDOT of the entered result, if [enterResult] and valid.
  double? get resultVdot => !enterResult || result == null
      ? null
      : Vdot.fromPerformance(
          RunPerformance(meters: resultMeters, time: result!),
        );

  CurrentFitness? get fitness {
    final v = resultVdot ?? (enterResult ? null : vdot);
    final m = enterResult ? null : mas;
    if (v == null && m == null) return null;
    return CurrentFitness(vdot: v, mas: m, lthr: _number(lthr));
  }

  String? get customKmError {
    if (preset != GoalPreset.custom) return null;
    final m = goalMeters;
    return m == null || m < 1000 || m > 110000 ? 'Enter 1–110 km' : null;
  }

  String? raceDateError(DateTime today) {
    if (!useRaceDate) return null;
    final d = raceDate;
    if (d == null) return 'Pick the race date';
    final days = d.difference(today).inDays;
    if (days < minRaceDays) return 'At least $minRaceDays days from now';
    return days > maxWeeks * 7 ? 'At most $maxWeeks weeks ahead' : null;
  }

  String? get targetError => targetTime.trim().isNotEmpty && target == null
      ? 'Use mm:ss or h:mm:ss'
      : null;

  String? get resultError => !enterResult
      ? null
      : result == null
      ? 'Use mm:ss or h:mm:ss'
      : null;

  String? get fitnessError => fitness == null
      ? 'Enter a recent race or time trial to estimate your fitness'
      : null;

  String? get lthrError {
    if (lthr.trim().isEmpty) return null;
    final v = _number(lthr);
    return v == null || v < 80 || v > 230 ? '80–230 bpm' : null;
  }

  String? _optionalPositive(String s) {
    if (s.trim().isEmpty) return null;
    final v = _number(s);
    return v == null || v <= 0 ? 'Enter a positive number' : null;
  }

  String? get weeklyVolumeError => _optionalPositive(weeklyVolume);
  String? get longestRunError => _optionalPositive(longestRun);

  String? maxMinutesError(int day) {
    final s = maxMinutes[day] ?? '';
    if (s.trim().isEmpty) return null;
    final v = int.tryParse(s.trim());
    return v == null || v < 20 || v > 600 ? '20–600 min' : null;
  }

  String? get daysError => days.isEmpty
      ? 'Choose at least one training day'
      : days.any((d) => maxMinutesError(d) != null)
      ? 'Fix the daily limits'
      : null;

  String? stepError(WizardStep step, DateTime today) => switch (step) {
    WizardStep.goal => customKmError ?? raceDateError(today) ?? targetError,
    WizardStep.fitness => fitnessError ?? resultError ?? lthrError,
    WizardStep.background => weeklyVolumeError ?? longestRunError,
    WizardStep.availability => daysError,
    WizardStep.strength => null,
    WizardStep.review => null,
  };

  StrengthGoal get strengthGoal => strengthKind == StrengthGoalKind.none
      ? const StrengthGoal.none()
      : StrengthGoal(
          kind: strengthKind,
          focusAreas: FocusArea.values.where(focus.contains).toList(),
          sessionsPerWeek: sessionsPerWeek,
          style: style,
          sessionDuration: Duration(minutes: sessionMinutes),
        );

  /// Null while any step before review is invalid.
  PlanRequest? toRequest(DateTime today) {
    for (final s in WizardStep.values) {
      if (stepError(s, today) != null) return null;
    }
    final volume = _number(weeklyVolume);
    final longest = _number(longestRun);
    final hours = unit == VolumeUnit.hours;
    Duration? mins(double? m) =>
        m == null ? null : Duration(minutes: m.round());
    return PlanRequest(
      goalMeters: goalMeters!,
      raceDate: useRaceDate ? raceDate : null,
      weeks: useRaceDate ? null : weeks,
      targetTime: target,
      startDate: today,
      fitness: fitness!,
      availability: WeeklyAvailability({
        for (final d in days)
          d: DayAvailability(
            maxDuration: mins(
              int.tryParse(maxMinutes[d]?.trim() ?? '')?.toDouble(),
            ),
          ),
      }, longRunWeekday: days.contains(longRunDay) ? longRunDay : null),
      currentWeeklyKm: hours ? null : volume,
      currentWeeklyDuration: hours && volume != null
          ? Duration(minutes: (volume * 60).round())
          : null,
      longestRecentRunKm: hours ? null : longest,
      longestRecentRun: hours ? mins(longest) : null,
      experience: experience,
      strength: strengthGoal,
    );
  }

  String defaultName(PlanRequest r) {
    final label = preset == GoalPreset.custom
        ? '${(r.goalMeters / 1000).toStringAsFixed(1)} km'
        : preset.label;
    final date = r.raceDate ?? r.startDate.add(Duration(days: r.weekCount * 7));
    return '$label plan – ${date.year}-${date.month.toString().padLeft(2, '0')}';
  }
}
