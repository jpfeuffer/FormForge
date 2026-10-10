import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/features/calendar/workout_spec.dart';
import 'package:training_core/training_core.dart';

void main() {
  final profile = PaceProfile.fromVdot(48);

  test('every generated quality session is editable without changing reps',
      () {
    const kinds = [
      SessionKind.threshold,
      SessionKind.interval,
      SessionKind.repetition,
      SessionKind.marathonPace,
      SessionKind.racePace,
    ];
    var checked = 0;
    for (final category in RaceCategory.values) {
      for (final phase in Phase.values) {
        for (final kind in kinds) {
          final w = SessionTemplates.quality(
            kind,
            budget: const Duration(minutes: 90),
            profile: profile,
            category: category,
            phase: phase,
            weeklyVolume: const Duration(hours: 6),
          );
          if (w == null) continue;
          final spec = WorkoutSpec.tryParse(kind, w, null);
          expect(spec, isNotNull, reason: '$kind/$category/$phase: ${w.title}');
          final rebuilt = spec!.build(profile);
          String reps(Workout x) =>
              jsonEncode(x.elements.whereType<RepeatBlock>().single.toJson());
          expect(reps(rebuilt), reps(w), reason: w.title);
          checked++;
        }
      }
    }
    expect(checked, greaterThan(20));
  });
}
