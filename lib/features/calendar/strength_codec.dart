import 'dart:convert';

import 'package:training_core/training_core.dart';

/// JSON for `PlannedWorkouts.strengthJson` (shared with the plan repository).
String encodeStrength(StrengthSession s) => jsonEncode(s.toJson());

StrengthSession? decodeStrength(String? json) {
  if (json == null) return null;
  try {
    return StrengthSession.fromJson(jsonDecode(json) as Map<String, Object?>);
  } on Object {
    return null;
  }
}
