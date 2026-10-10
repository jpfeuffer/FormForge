import 'package:flutter/material.dart';
import 'package:training_core/training_core.dart';

extension SessionKindStyle on SessionKind {
  String get label => switch (this) {
    SessionKind.easy => 'Easy',
    SessionKind.recovery => 'Recovery',
    SessionKind.long => 'Long run',
    SessionKind.threshold => 'Threshold',
    SessionKind.interval => 'Intervals',
    SessionKind.repetition => 'Repetitions',
    SessionKind.marathonPace => 'Marathon pace',
    SessionKind.racePace => 'Race pace',
    SessionKind.test => 'Test',
    SessionKind.strength => 'Strength',
    SessionKind.combined => 'Run + strength',
    SessionKind.race => 'Race',
  };

  IconData get icon => switch (this) {
    SessionKind.easy => Icons.directions_run,
    SessionKind.recovery => Icons.self_improvement,
    SessionKind.long => Icons.route,
    SessionKind.threshold => Icons.speed,
    SessionKind.interval => Icons.timer,
    SessionKind.repetition => Icons.bolt,
    SessionKind.marathonPace || SessionKind.racePace => Icons.flag,
    SessionKind.test => Icons.science,
    SessionKind.strength => Icons.fitness_center,
    SessionKind.combined => Icons.sports_gymnastics,
    SessionKind.race => Icons.emoji_events,
  };

  Color color(ColorScheme cs) => switch (this) {
    SessionKind.easy => cs.secondary,
    SessionKind.recovery => cs.outline,
    SessionKind.long => cs.primary,
    SessionKind.threshold ||
    SessionKind.marathonPace ||
    SessionKind.racePace => cs.tertiary,
    SessionKind.interval ||
    SessionKind.repetition ||
    SessionKind.test ||
    SessionKind.race => cs.error,
    SessionKind.strength => cs.onSurfaceVariant,
    SessionKind.combined => Color.lerp(cs.secondary, cs.onSurfaceVariant, .5)!,
  };
}

extension FocusAreaLabel on FocusArea {
  String get label => switch (this) {
    FocusArea.runningStrength => 'Running strength',
    FocusArea.core => 'Core',
    FocusArea.lowerBody => 'Lower body',
    FocusArea.upperPush => 'Push',
    FocusArea.upperPull => 'Pull',
    FocusArea.plyometrics => 'Plyometrics',
    FocusArea.mobility => 'Mobility',
    FocusArea.fullBody => 'Full body',
  };
}

extension SeverityStyle on Severity {
  IconData get icon => switch (this) {
    Severity.error => Icons.error,
    Severity.warning => Icons.warning_amber,
    Severity.info => Icons.info_outline,
  };

  Color color(ColorScheme cs) => switch (this) {
    Severity.error => cs.error,
    Severity.warning => cs.tertiary,
    Severity.info => cs.outline,
  };
}

/// Most severe first in [Severity] order.
Severity? worstSeverity(Iterable<ScheduleIssue> issues) {
  Severity? worst;
  for (final i in issues) {
    if (worst == null || i.severity.index < worst.index) worst = i.severity;
  }
  return worst;
}
