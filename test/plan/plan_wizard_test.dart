import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/database.dart';
import 'package:formforge/features/plan/plan_providers.dart';
import 'package:formforge/features/plan/plan_wizard_page.dart';
import 'package:formforge/features/plan/wizard_inputs.dart';
import 'package:formforge/providers.dart';
import 'package:training_core/training_core.dart';

Future<AppDatabase> _db(WidgetTester tester, {bool withFitness = true}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  if (withFitness) {
    await tester.runAsync(
      () => db
          .into(db.fitnessSnapshots)
          .insert(
            FitnessSnapshotsCompanion.insert(
              date: DateTime.now(),
              source: FitnessSource.race,
              vdot: const Value(47),
            ),
          ),
    );
  }
  return db;
}

Future<void> _pump(WidgetTester tester, AppDatabase db) async {
  tester.view
    ..physicalSize = const Size(400, 800)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: PlanWizardPage()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _next(WidgetTester tester, [int times = 1]) async {
  for (var i = 0; i < times; i++) {
    await tester.tap(find.widgetWithText(FilledButton, 'Next'));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('walks through all steps to the review with defaults', (
    tester,
  ) async {
    final db = await _db(tester);
    await _pump(tester, db);

    expect(find.text('What are you training for?'), findsOneWidget);
    await _next(tester);
    expect(find.textContaining('Stored fitness: VDOT 47.0'), findsOneWidget);
    await _next(tester);
    expect(find.text('Current training'), findsOneWidget);
    await _next(tester);
    expect(find.text('Which days can you train?'), findsOneWidget);
    await _next(tester);
    expect(find.text('Strength training'), findsOneWidget);
    await _next(tester);

    expect(find.text('Save plan'), findsOneWidget);
    expect(find.textContaining('12 weeks'), findsWidgets);
    expect(find.text('All training guardrails satisfied'), findsOneWidget);
    expect(find.text('First weeks'), findsOneWidget);
  });

  testWidgets('blocks the fitness step until a result is entered', (
    tester,
  ) async {
    final db = await _db(tester, withFitness: false);
    await _pump(tester, db);
    await _next(tester);

    expect(find.textContaining('Enter a recent race'), findsWidgets);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Next'))
          .onPressed,
      isNull,
    );

    await tester.enterText(find.widgetWithText(TextFormField, 'Time'), '20:00');
    await tester.pumpAndSettle();
    expect(find.textContaining('VDOT 49'), findsOneWidget);
    await _next(tester);
    expect(find.text('Current training'), findsOneWidget);
  });

  testWidgets('saving stores the plan, the inputs and the entered result', (
    tester,
  ) async {
    final db = await _db(tester, withFitness: false);
    await _pump(tester, db);
    await _next(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Time'), '25:00');
    await tester.pumpAndSettle();
    await _next(tester, 4);

    await tester.tap(find.text('Save plan'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    final plans = await tester.runAsync(
      () => db.select(db.trainingPlans).get(),
    );
    expect(plans, hasLength(1));
    final saved = await tester.runAsync(() => db.getSetting(wizardInputsKey));
    final inputs = WizardInputs.decode(saved, DateTime.now());
    expect(inputs.preset, GoalPreset.k10);
    expect(inputs.weeks, 12);
    final snapshots = await tester.runAsync(
      () => db.select(db.fitnessSnapshots).get(),
    );
    expect(snapshots!.single.source, FitnessSource.race);
    expect(snapshots.single.distanceM, 5000);
  });

  group('WizardInputs', () {
    test('defaults build a valid request', () {
      final today = DateTime(2026, 5, 4);
      final i = WizardInputs()..vdot = 45;
      final r = i.toRequest(today)!;
      expect(r.weekCount, 12);
      expect(r.goalMeters, 10000);
      expect(r.availability.longRunWeekday, DateTime.sunday);
    });

    test('encode/decode keeps answers but drops stale race dates', () {
      final today = DateTime(2026, 5, 4);
      final i = WizardInputs()
        ..preset = GoalPreset.custom
        ..customKm = '15'
        ..useRaceDate = true
        ..raceDate = DateTime(2026, 5, 10)
        ..unit = VolumeUnit.hours
        ..weeklyVolume = '3.5'
        ..days = {1, 3}
        ..strengthKind = StrengthGoalKind.secondaryGoal
        ..focus = {FocusArea.core};
      final back = WizardInputs.decode(i.encode(), today);
      expect(back.preset, GoalPreset.custom);
      expect(back.customKm, '15');
      expect(back.useRaceDate, isFalse);
      expect(back.raceDate, isNull);
      expect(back.unit, VolumeUnit.hours);
      expect(back.weeklyVolume, '3.5');
      expect(back.days, {1, 3});
      expect(back.focus, {FocusArea.core});
      expect(WizardInputs.decode('garbage', today).preset, GoalPreset.k10);
    });

    test('flags invalid fields', () {
      final today = DateTime(2026, 5, 4);
      final i = WizardInputs()
        ..preset = GoalPreset.custom
        ..customKm = '500';
      expect(i.stepError(WizardStep.goal, today), isNotNull);
      i
        ..customKm = '12'
        ..targetTime = 'fast';
      expect(i.targetError, isNotNull);
      i
        ..targetTime = '1:00:00'
        ..days = {};
      expect(i.stepError(WizardStep.goal, today), isNull);
      expect(i.stepError(WizardStep.availability, today), isNotNull);
      expect(i.toRequest(today), isNull);
    });
  });
}
