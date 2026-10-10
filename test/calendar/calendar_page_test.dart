import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/database.dart';
import 'package:formforge/features/calendar/calendar_models.dart';
import 'package:formforge/features/calendar/calendar_page.dart';
import 'package:formforge/features/calendar/calendar_providers.dart';
import 'package:formforge/features/calendar/week_view.dart';
import 'package:formforge/features/calendar/workout_detail_page.dart';
import 'package:formforge/features/calendar/workout_spec.dart';
import 'package:formforge/providers.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  final monday = weekStartOf(DateTime.now());
  late int easyId;

  Future<int> seed(
    SessionKind kind,
    int dayOffset,
    String title, {
    bool key = false,
    int minutes = 45,
  }) {
    final spec = WorkoutSpec(kind)..runMinutes = minutes;
    final w = spec.build(fallbackPaceProfile, title: title);
    return db
        .into(db.plannedWorkouts)
        .insert(
          PlannedWorkoutsCompanion.insert(
            date: addDays(monday, dayOffset),
            kind: kind,
            title: title,
            workoutJson: jsonEncode(w.toJson()),
            isKey: Value(key),
          ),
        );
  }

  setUp(() => db = AppDatabase(NativeDatabase.memory()));

  /// Drift streams mix real async (queries) with fake-async timers (updates).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> pumpCalendar(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      easyId = await seed(SessionKind.easy, 1, 'Tempo-free jog');
      await seed(
        SessionKind.long,
        5,
        'Sunday-ish long',
        key: true,
        minutes: 90,
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: CalendarPage()),
      ),
    );
    await settle(tester);
  }

  Finder inDay(int offset, String title) => find.descendant(
    of: find.byKey(dayKey(addDays(monday, offset))),
    matching: find.text(title),
  );

  testWidgets('week view shows seeded workouts and follows repository moves', (
    tester,
  ) async {
    await pumpCalendar(tester);

    expect(inDay(1, 'Tempo-free jog'), findsOneWidget);
    expect(inDay(5, 'Sunday-ish long'), findsOneWidget);
    expect(find.textContaining('running'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(CalendarPage)),
    );
    await tester.runAsync(
      () => container
          .read(calendarRepositoryProvider)
          .move(easyId, addDays(monday, 3)),
    );
    await settle(tester);

    expect(inDay(1, 'Tempo-free jog'), findsNothing);
    expect(inDay(3, 'Tempo-free jog'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('dragging a card onto another day moves it', (tester) async {
    await pumpCalendar(tester);

    final from = tester.getCenter(inDay(1, 'Tempo-free jog'));
    final to = tester.getCenter(find.byKey(dayKey(addDays(monday, 2))));
    final g = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 400));
    await g.moveTo(to);
    await tester.pump();
    await g.up();
    await settle(tester);

    expect(inDay(2, 'Tempo-free jog'), findsOneWidget);
    expect(
      (await tester.runAsync(() => db.select(db.plannedWorkouts).get()))!
          .firstWhere((r) => r.id == easyId)
          .date,
      addDays(monday, 2),
    );

    await unmount(tester);
  });

  testWidgets('month view lists workouts as chips', (tester) async {
    await pumpCalendar(tester);
    await tester.tap(find.text('Month'));
    await settle(tester);
    expect(find.byType(Tooltip), findsWidgets);
    expect(find.text('45′'), findsOneWidget);
    expect(find.text('★ 90′'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('phone layout lists the days vertically', (tester) async {
    await pumpCalendar(tester, size: const Size(390, 800));
    expect(inDay(1, 'Tempo-free jog'), findsOneWidget);
    expect(find.text('Rest'), findsWidgets);
    await unmount(tester);
  });

  testWidgets('the editor creates an interval workout', (tester) async {
    await pumpCalendar(tester);
    await tester.tap(find.text('Workout'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Intervals'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await settle(tester);
    await tester.pumpAndSettle();

    final rows = (await tester.runAsync(
      () => db.select(db.plannedWorkouts).get(),
    ))!;
    final created = rows.singleWhere((r) => r.kind == SessionKind.interval);
    expect(created.title, '5 × 800 m interval');
    expect(created.planId, isNull);
    expect(created.isKey, isTrue);
    expect(find.text('5 × 800 m interval'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('detail page shows paces and adds a strength block', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final id = (await tester.runAsync(
      () => seed(SessionKind.easy, 2, 'Easy one'),
    ))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(home: WorkoutDetailPage(id: id)),
      ),
    );
    await settle(tester);
    expect(find.textContaining('/km'), findsWidgets);

    await tester.tap(find.text('Add strength block'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await settle(tester);

    final row = (await tester.runAsync(
      () => db.select(db.plannedWorkouts).getSingle(),
    ))!;
    expect(row.kind, SessionKind.combined);
    expect(row.strengthJson, isNotNull);
    expect(find.text('Remove strength block'), findsOneWidget);
    await unmount(tester);
  });
}
