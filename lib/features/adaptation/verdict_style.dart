import 'package:flutter/material.dart';
import 'package:training_core/training_core.dart';

extension StepVerdictStyle on StepVerdict {
  String get label => switch (this) {
    StepVerdict.onTarget => 'On target',
    StepVerdict.tooFast => 'Too fast',
    StepVerdict.tooSlow => 'Too slow',
    StepVerdict.hrTooHigh => 'HR too high',
    StepVerdict.notCompleted => 'Not completed',
  };

  IconData get icon => switch (this) {
    StepVerdict.onTarget => Icons.check_circle,
    StepVerdict.tooFast => Icons.arrow_upward,
    StepVerdict.tooSlow => Icons.arrow_downward,
    StepVerdict.hrTooHigh => Icons.favorite,
    StepVerdict.notCompleted => Icons.cancel,
  };

  Color color(ColorScheme s) => switch (this) {
    StepVerdict.onTarget => Colors.green,
    StepVerdict.tooFast || StepVerdict.hrTooHigh => s.error,
    StepVerdict.tooSlow => Colors.orange,
    StepVerdict.notCompleted => s.outline,
  };
}

extension SessionVerdictStyle on SessionVerdict {
  String get label => switch (this) {
    SessionVerdict.onTarget => 'As planned',
    SessionVerdict.tooHard => 'Too hard',
    SessionVerdict.tooEasy => 'Too easy',
    SessionVerdict.incomplete => 'Incomplete',
  };

  Color color(ColorScheme s) => switch (this) {
    SessionVerdict.onTarget => Colors.green,
    SessionVerdict.tooHard => s.error,
    SessionVerdict.tooEasy => Colors.orange,
    SessionVerdict.incomplete => s.outline,
  };
}

extension SuggestionSeverityStyle on SuggestionSeverity {
  IconData get icon => switch (this) {
    SuggestionSeverity.info => Icons.lightbulb_outline,
    SuggestionSeverity.warning => Icons.warning_amber,
    SuggestionSeverity.critical => Icons.error_outline,
  };

  Color color(ColorScheme s) => switch (this) {
    SuggestionSeverity.info => s.primary,
    SuggestionSeverity.warning => Colors.orange,
    SuggestionSeverity.critical => s.error,
  };
}

String paceRange(Zone zone) =>
    '${Pace.format(zone.upper)}–${Pace.format(zone.lower)} /km';

String percent(double fraction) => '${(fraction * 100).round()} %';
