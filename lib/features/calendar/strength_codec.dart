import 'dart:convert';

import 'package:training_core/training_core.dart';

/// JSON for `PlannedWorkouts.strengthJson`.
String encodeStrength(StrengthSession s) => jsonEncode({
  'focusAreas': [for (final f in s.focusAreas) f.name],
  'durationSeconds': s.duration.inSeconds,
  'rpe': s.rpe,
  'style': s.style.name,
});

StrengthSession? decodeStrength(String? json) {
  if (json == null) return null;
  try {
    final m = jsonDecode(json) as Map<String, Object?>;
    return StrengthSession(
      focusAreas: [
        for (final f in m['focusAreas'] as List)
          FocusArea.values.byName(f as String),
      ],
      duration: Duration(seconds: (m['durationSeconds'] as num).toInt()),
      rpe: (m['rpe'] as num).toInt(),
      style: StrengthStyle.values.byName(m['style'] as String),
    );
  } on Object {
    return null;
  }
}
