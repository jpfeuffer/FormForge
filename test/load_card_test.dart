import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/features/adaptation/adaptation_providers.dart';
import 'package:formforge/features/adaptation/eval_info.dart';
import 'package:formforge/features/today/load_card.dart';
import 'package:training_core/training_core.dart';

void main() {
  final points = [
    for (var i = 0; i < 50; i++)
      LoadPoint(
        day: DateTime.utc(2026, 8, 24).add(Duration(days: i)),
        load: 50,
        ctl: 20 + i * 0.6,
        atl: 25 + (i % 7) * 3.0,
        tsb: 0,
      ),
  ];

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [trainingLoadProvider.overrideWith((ref) async => points)],
        child: const MaterialApp(home: Scaffold(body: LoadCard())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows metric boxes and dated x ticks ending on today', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Fitness · CTL'), findsOneWidget);
    expect(find.text('Fatigue · ATL'), findsOneWidget);
    expect(find.text('Form · TSB'), findsOneWidget);
    // Last day is 2026-10-12; weekly ticks count back from it.
    expect(find.text('12 Oct'), findsOneWidget);
    expect(find.text('5 Oct'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hovering a box explains the metric', (tester) async {
    await pump(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Fitness · CTL')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('chronic training load'), findsOneWidget);
    expect(EvalInfo.fitness, contains('chronic training load'));
  });
}
