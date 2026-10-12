import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/activity_streams.dart';
import 'package:formforge/features/activities/activity_charts.dart';
import 'package:training_core/training_core.dart';

void main() {
  testWidgets('hovering a chart with planned targets does not throw', (
    tester,
  ) async {
    const n = 1800;
    final streams = ActivityStreamData(
      seconds: [for (var i = 0; i < n; i++) i],
      speed: [for (var i = 0; i < n; i++) 2.8 + (i % 60) / 600],
      heartRate: [for (var i = 0; i < n; i++) 140 + i % 15],
      distance: [for (var i = 0; i < n; i++) i * 2.9],
    );
    final steps = [
      StepCompliance(
        index: 0,
        kind: StepKind.active,
        verdict: StepVerdict.onTarget,
        coverage: 1,
        startSecond: 0,
        endSecond: 900,
        speedTarget: const Zone('t', 2.5, 3.0),
        hrTarget: const Zone('t', 130, 150),
      ),
      StepCompliance(
        index: 1,
        kind: StepKind.recovery,
        verdict: StepVerdict.onTarget,
        coverage: 1,
        startSecond: 900,
        endSecond: 1800,
        speedTarget: const Zone('t', 2.0, 2.4),
        hrTarget: const Zone('t', 120, 135),
      ),
    ];

    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ActivityCharts(
              streams: streams,
              paces: PaceProfile.fromVdot(45),
              hrZones: HeartRate.frielZones(170),
              plannedSteps: steps,
            ),
          ),
        ),
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    for (final chart in find.byType(LineChart).evaluate()) {
      final rect = tester.getRect(find.byWidget(chart.widget));
      for (final dy in [10.0, rect.height / 2, rect.height - 30]) {
        // Target bars only have points at their ends: the plot edges here.
        for (final dx in [46.0, 60.0, rect.width / 2, rect.width / 2 + 3, rect.width - 4]) {
          await mouse.moveTo(rect.topLeft + Offset(dx, dy));
          await tester.pump();
        }
      }
    }
    expect(tester.takeException(), isNull);
  });
}
