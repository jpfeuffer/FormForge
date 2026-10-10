import 'dart:convert';

import 'package:test/test.dart';
import 'package:training_core/training_core.dart';

void main() {
  PlanRequest full() => PlanRequest(
        goalMeters: 21097.5,
        raceDate: DateTime(2027, 3, 14),
        targetTime: const Duration(hours: 1, minutes: 45),
        startDate: DateTime(2026, 11, 2),
        fitness: const CurrentFitness(vdot: 46.5, mas: 4.4, lthr: 168),
        availability: WeeklyAvailability({
          DateTime.monday: const DayAvailability(),
          DateTime.wednesday:
              const DayAvailability(maxDuration: Duration(minutes: 60)),
          DateTime.saturday: const DayAvailability(),
          DateTime.sunday:
              const DayAvailability(maxDuration: Duration(hours: 2)),
        }, longRunWeekday: DateTime.sunday),
        currentWeeklyDuration: const Duration(hours: 3),
        currentWeeklyKm: 30,
        longestRecentRun: const Duration(minutes: 75),
        longestRecentRunKm: 12,
        experience: Experience.advanced,
        strength: const StrengthGoal(
          kind: StrengthGoalKind.secondaryGoal,
          focusAreas: [FocusArea.core, FocusArea.upperPull],
          sessionsPerWeek: 2,
          style: StrengthStyle.gym,
          sessionDuration: Duration(minutes: 45),
        ),
        preferredTests: const [TestType.timeTrial5k, TestType.halfCooper],
      );

  Object? roundTrip(Map<String, Object?> json) => jsonDecode(jsonEncode(json));

  group('PlanRequest JSON', () {
    test('is versioned and uses seconds and yyyy-MM-dd', () {
      final json = full().toJson();
      expect(json['v'], 1);
      expect(json['raceDate'], '2027-03-14');
      expect(json['startDate'], '2026-11-02');
      expect(json['targetTimeS'], 6300);
      expect(json['preferredTests'], ['timeTrial5k', 'halfCooper']);
    });

    test('round-trips through encoded JSON', () {
      final back = PlanRequest.fromJson(
          roundTrip(full().toJson()) as Map<String, Object?>);
      final r = full();
      expect(back.toJson(), r.toJson());
      expect(back.goalMeters, r.goalMeters);
      expect(back.raceDate, r.raceDate);
      expect(back.startDate, r.startDate);
      expect(back.targetTime, r.targetTime);
      expect(back.fitness.vdot, 46.5);
      expect(back.availability.availableWeekdays, [1, 3, 6, 7]);
      expect(back.availability[DateTime.wednesday].maxDuration,
          const Duration(minutes: 60));
      expect(back.availability.longRunWeekday, DateTime.sunday);
      expect(back.experience, Experience.advanced);
      expect(back.strength.style, StrengthStyle.gym);
      expect(back.strength.focusAreas, [FocusArea.core, FocusArea.upperPull]);
      expect(back.preferredTests, r.preferredTests);
    });

    test('minimal request with weeks and MAS only', () {
      final r = PlanRequest(
        goalMeters: 5000,
        weeks: 8,
        startDate: DateTime(2026, 5, 4),
        fitness: const CurrentFitness(mas: 4.2),
        availability: WeeklyAvailability.on([1, 3, 5]),
      );
      final back =
          PlanRequest.fromJson(roundTrip(r.toJson())! as Map<String, Object?>);
      expect(back.raceDate, isNull);
      expect(back.weeks, 8);
      expect(back.fitness.vdot, isNull);
      expect(back.strength.isActive, isFalse);
      expect(back.toJson(), r.toJson());
    });

    test('regenerates the same plan', () {
      final a = PlanGenerator.generate(full());
      final b = PlanGenerator.generate(PlanRequest.fromJson(
          roundTrip(full().toJson()) as Map<String, Object?>));
      expect(b.weeks.length, a.weeks.length);
      expect(b.sessions.map((s) => jsonEncode(s.workout.toJson())).toList(),
          a.sessions.map((s) => jsonEncode(s.workout.toJson())).toList());
    });

    test('rejects unknown versions', () {
      final json = full().toJson()..['v'] = 2;
      expect(() => PlanRequest.fromJson(json), throwsFormatException);
    });

    test('withFitness replaces only the fitness', () {
      final r = full().withFitness(const CurrentFitness(vdot: 50));
      expect(r.fitness.vdot, 50);
      expect(r.fitness.lthr, isNull);
      expect(r.goalMeters, 21097.5);
      expect(r.raceDate, DateTime(2027, 3, 14));
    });
  });

  group('StrengthSession JSON', () {
    test('round-trips', () {
      const s = StrengthSession(
        focusAreas: [FocusArea.lowerBody, FocusArea.mobility],
        duration: Duration(minutes: 40),
        rpe: 7,
        style: StrengthStyle.gym,
      );
      final json = roundTrip(s.toJson()) as Map<String, Object?>;
      expect(json['v'], 1);
      expect(json['durationS'], 2400);
      final back = StrengthSession.fromJson(json);
      expect(back.focusAreas, s.focusAreas);
      expect(back.duration, s.duration);
      expect(back.rpe, 7);
      expect(back.style, StrengthStyle.gym);
    });

    test('rejects unknown versions', () {
      expect(
          () => StrengthSession.fromJson({
                'v': 9,
                'focusAreas': <String>[],
                'durationS': 60,
                'rpe': 5,
                'style': 'gym'
              }),
          throwsFormatException);
    });
  });
}
