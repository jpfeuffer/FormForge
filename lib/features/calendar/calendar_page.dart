import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/database.dart';
import '../../providers.dart';

class CalendarPage extends ConsumerWidget {
  const CalendarPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day);
    final to = from.add(const Duration(days: 14));
    final db = ref.watch(databaseProvider);
    final dayFmt = DateFormat.MMMEd();

    return Scaffold(
      appBar: AppBar(title: const Text('Next 2 weeks')),
      body: StreamBuilder<List<PlannedWorkout>>(
        stream: db.watchPlanned(from, to),
        builder: (context, snap) {
          final byDay = <DateTime, List<PlannedWorkout>>{};
          for (final w in snap.data ?? const <PlannedWorkout>[]) {
            final d = DateTime(w.date.year, w.date.month, w.date.day);
            (byDay[d] ??= []).add(w);
          }
          return ListView.builder(
            itemCount: 14,
            itemBuilder: (context, i) {
              final day = from.add(Duration(days: i));
              final items = byDay[day] ?? const [];
              return ListTile(
                title: Text(dayFmt.format(day)),
                subtitle: Text(items.isEmpty
                    ? 'Rest / unplanned'
                    : items.map((w) => w.title).join(' · ')),
              );
            },
          );
        },
      ),
    );
  }
}
