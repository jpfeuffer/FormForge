import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/util/format.dart';

void main() {
  test('parseDuration', () {
    expect(parseDuration('20:00'), const Duration(minutes: 20));
    expect(parseDuration('1:30:15'),
        const Duration(hours: 1, minutes: 30, seconds: 15));
    expect(parseDuration('abc'), isNull);
    expect(parseDuration('0:00'), isNull);
  });

  test('formatDuration', () {
    expect(formatDuration(const Duration(minutes: 19, seconds: 57)), '19:57');
    expect(formatDuration(const Duration(hours: 3, minutes: 10, seconds: 49)),
        '3:10:49');
  });
}
