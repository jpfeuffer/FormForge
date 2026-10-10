import 'package:test/test.dart';
import 'package:training_core/training_core.dart';

// Monday.
final mon = DateTime(2026, 10, 5);
DateTime day(int offset) => DateTime(mon.year, mon.month, mon.day + offset);

var _id = 0;

ScheduledItem item(
  int dayOffset,
  SessionKind kind, {
  int minutes = 45,
  bool isKey = false,
  bool heavy = false,
}) =>
    ScheduledItem(
      id: ++_id,
      date: day(dayOffset),
      kind: kind,
      isKey: isKey,
      heavyStrength: heavy,
      estimatedDuration: Duration(minutes: minutes),
    );

Set<String> codes(List<ScheduleIssue> issues) =>
    {for (final i in issues) i.code};

void main() {
  setUp(() => _id = 0);

  test('fixture date is a Monday', () => expect(mon.weekday, DateTime.monday));

  test('a sensible week has no issues', () {
    final issues = ScheduleChecker.check([
      item(0, SessionKind.easy),
      item(1, SessionKind.interval, isKey: true),
      item(2, SessionKind.recovery, minutes: 30),
      item(3, SessionKind.easy),
      item(5, SessionKind.long, minutes: 70, isKey: true),
    ]);
    expect(issues, isEmpty);
  });

  test('consecutive hard days are flagged on the second day', () {
    final issues = ScheduleChecker.check([
      item(1, SessionKind.threshold),
      item(2, SessionKind.long, isKey: true),
    ]);
    final i = issues.single;
    expect(i.code, 'consecutive_key_days');
    expect(i.severity, Severity.error);
    expect(i.date, day(2));
    expect(i.itemId, 2);
  });

  test('heavy strength the day before a key session is an error', () {
    final issues = ScheduleChecker.check([
      item(1, SessionKind.strength, heavy: true),
      item(2, SessionKind.interval, isKey: true),
    ]);
    final i = issues.single;
    expect(i.code, 'heavy_strength_before_key');
    expect(i.itemId, 1);
    expect(i.date, day(1));
  });

  test('heavy strength 48 h before a key session is a warning', () {
    final issues = ScheduleChecker.check([
      item(0, SessionKind.strength, heavy: true),
      item(2, SessionKind.long, isKey: true),
    ]);
    expect(issues.single.code, 'heavy_strength_48h');
    expect(issues.single.severity, Severity.warning);
  });

  test('light strength is fine before a key session', () {
    expect(
        ScheduleChecker.check([
          item(1, SessionKind.strength),
          item(2, SessionKind.interval, isKey: true),
        ]),
        isEmpty);
  });

  test('too many quality sessions in a rolling 7 days', () {
    final items = [
      item(0, SessionKind.threshold),
      item(2, SessionKind.interval),
      item(4, SessionKind.repetition),
    ];
    final issues = ScheduleChecker.check(items);
    expect(issues.single.code, 'too_many_quality');
    expect(issues.single.date, day(4));
    expect(ScheduleChecker.check(items, maxQualityPer7Days: 3), isEmpty);
    // The first session falls out of the 7-day window.
    expect(
        ScheduleChecker.check([
          item(0, SessionKind.threshold),
          item(3, SessionKind.interval),
          item(7, SessionKind.repetition),
        ]),
        isEmpty);
  });

  test('no rest day in a Mon–Sun week', () {
    final week = [
      for (var d = 0; d < 7; d++) item(d, SessionKind.easy, minutes: 30),
    ];
    final issues = ScheduleChecker.check(week);
    final rest = issues.singleWhere((i) => i.code == 'no_rest_day');
    expect(rest.weekly, isTrue);
    expect(rest.date, mon);
    // Seven days spanning two weeks is fine.
    final shifted = [
      for (var d = 3; d < 10; d++) item(d, SessionKind.easy, minutes: 30),
    ];
    expect(
        codes(ScheduleChecker.check(shifted)), isNot(contains('no_rest_day')));
  });

  test('long run share of the week', () {
    final issues = ScheduleChecker.check([
      item(0, SessionKind.easy, minutes: 30),
      item(1, SessionKind.easy, minutes: 30),
      item(2, SessionKind.easy, minutes: 30),
      item(3, SessionKind.easy, minutes: 30),
      item(5, SessionKind.long, minutes: 120),
    ]);
    final i = issues.singleWhere((i) => i.code == 'long_run_share');
    expect(i.itemId, 5);
    expect(i.severity, Severity.warning);
  });

  test('availability: unavailable day and max duration', () {
    final avail = WeeklyAvailability({
      DateTime.monday:
          const DayAvailability(maxDuration: Duration(minutes: 40)),
      DateTime.tuesday: const DayAvailability.off(),
    });
    final issues = ScheduleChecker.check([
      item(0, SessionKind.easy, minutes: 60),
      item(1, SessionKind.easy, minutes: 30),
    ], availability: avail);
    expect(codes(issues), containsAll(['max_duration', 'unavailable_day']));
    expect(ScheduleChecker.check([item(0, SessionKind.easy, minutes: 60)]),
        isEmpty);
  });

  test('race day is exempt from availability', () {
    final avail = WeeklyAvailability({});
    expect(
        ScheduleChecker.check([item(6, SessionKind.race, isKey: true)],
            availability: avail),
        isEmpty);
  });

  test('two runs on one day is info; strength does not count as a run', () {
    final issues = ScheduleChecker.check([
      item(0, SessionKind.easy),
      item(0, SessionKind.recovery, minutes: 20),
      item(2, SessionKind.easy),
      item(2, SessionKind.strength, minutes: 20),
    ]);
    final i = issues.single;
    expect(i.code, 'two_runs_same_day');
    expect(i.severity, Severity.info);
    expect(i.date, day(0));
  });

  test('week volume jump > 10% is a warning on the week', () {
    final prev = [
      item(-7, SessionKind.easy, minutes: 60),
      item(-5, SessionKind.easy, minutes: 60),
    ];
    final ok = ScheduleChecker.check([
      ...prev,
      item(0, SessionKind.easy, minutes: 66),
      item(2, SessionKind.easy, minutes: 66),
    ]);
    expect(ok, isEmpty);

    final jump = ScheduleChecker.check([
      ...prev,
      item(0, SessionKind.easy, minutes: 80),
      item(2, SessionKind.easy, minutes: 80),
    ]);
    final i = jump.single;
    expect(i.code, 'volume_ramp');
    expect(i.weekly, isTrue);
    expect(i.date, mon);
  });

  test('combined sessions count their run part only', () {
    final combined = ScheduledItem(
      id: 99,
      date: day(1),
      kind: SessionKind.combined,
      estimatedDuration: const Duration(minutes: 60),
      runDuration: const Duration(minutes: 40),
    );
    expect(combined.isRun, isTrue);
    expect(combined.moved(day(3)).date, day(3));
    expect(combined.moved(day(3)).runDuration, const Duration(minutes: 40));
  });

  test('result is deterministic and sorted by date', () {
    final items = [
      item(2, SessionKind.long, isKey: true),
      item(1, SessionKind.threshold),
      item(1, SessionKind.easy),
    ];
    final a = ScheduleChecker.check(items);
    final b = ScheduleChecker.check(items.reversed);
    expect(a.map((i) => '$i'), b.map((i) => '$i'));
    expect(
        a.map((i) => i.date), orderedEquals([...a.map((i) => i.date)]..sort()));
  });
}
