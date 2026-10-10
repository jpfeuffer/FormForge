import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:training_core/training_core.dart' show Phase, SessionKind;

import '../../data/database.dart' show WorkoutStatus;

IconData kindIcon(SessionKind kind) => switch (kind) {
  SessionKind.easy => Icons.directions_run,
  SessionKind.recovery => Icons.self_improvement,
  SessionKind.long => Icons.route,
  SessionKind.threshold => Icons.speed,
  SessionKind.interval => Icons.bolt,
  SessionKind.repetition => Icons.flash_on,
  SessionKind.marathonPace => Icons.timer,
  SessionKind.racePace => Icons.flag_circle,
  SessionKind.test => Icons.science,
  SessionKind.strength => Icons.fitness_center,
  SessionKind.combined => Icons.sports_gymnastics,
  SessionKind.race => Icons.emoji_events,
};

String phaseLabel(Phase p) => switch (p) {
  Phase.base => 'Base',
  Phase.build => 'Build',
  Phase.peak => 'Peak',
  Phase.taper => 'Taper',
};

String formatVolume(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  return h == 0 ? '$m min' : '$h h ${m.toString().padLeft(2, '0')} min';
}

final _dayFormat = DateFormat('EEE d MMM');

String formatDay(DateTime d) => _dayFormat.format(d);

/// One planned session; key sessions get a highlighted background.
class SessionRow extends StatelessWidget {
  const SessionRow({
    super.key,
    required this.date,
    required this.kind,
    required this.title,
    this.isKey = false,
    this.status,
  });

  final DateTime date;
  final SessionKind kind;
  final String title;
  final bool isKey;
  final WorkoutStatus? status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodyMedium;
    final statusIcon = switch (status) {
      WorkoutStatus.done => Icons.check_circle,
      WorkoutStatus.partial => Icons.timelapse,
      WorkoutStatus.skipped => Icons.cancel_outlined,
      _ => null,
    };
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: isKey ? scheme.tertiaryContainer : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        spacing: 8,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              formatDay(date),
              style: style?.copyWith(color: scheme.outline),
            ),
          ),
          Icon(kindIcon(kind), size: 20),
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: isKey
                  ? style?.copyWith(fontWeight: FontWeight.w600)
                  : style,
            ),
          ),
          if (statusIcon != null)
            Icon(statusIcon, size: 18, color: scheme.primary),
        ],
      ),
    );
  }
}
