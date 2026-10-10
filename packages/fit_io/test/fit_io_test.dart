import 'dart:convert';
import 'dart:typed_data';

import 'package:fit_io/fit_io.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('crc', () {
    test('matches CRC-16/ARC check value', () {
      expect(fitCrc(ascii.encode('123456789')), 0xBB3D);
    });

    test('is resumable', () {
      final bytes = ascii.encode('123456789');
      expect(fitCrc(bytes, start: 4, crc: fitCrc(bytes, end: 4)), 0xBB3D);
    });
  });

  group('header', () {
    final records = [
      0x40, 0, 0, 0, 0, 1, FitFileIdField.type, 1, 0x00, //
      0x00, FitFileType.activity,
    ];

    test('decodes 12- and 14-byte headers', () {
      for (final size in [12, 14]) {
        final file = const FitDecoder(crcCheck: CrcCheck.strict)
            .decode(wrapFit(records, headerSize: size));
        expect(file.header.headerSize, size);
        expect(file.header.profileVersion, 2140);
        expect(file.messages.single.intValue(FitFileIdField.type), 4);
        expect(file.warnings, isEmpty);
      }
    });

    test('rejects missing signature and short input', () {
      final bytes = wrapFit(records)..[9] = 0x58;
      expect(() => const FitDecoder().decode(bytes),
          throwsA(isA<FitFormatException>()));
      expect(() => const FitDecoder().decode(Uint8List(5)),
          throwsA(isA<FitFormatException>()));
    });

    test('header CRC mismatch warns or throws', () {
      final bytes = wrapFit(records)..[12] ^= 0xFF;
      expect(const FitDecoder().decode(bytes).warnings,
          contains('Header CRC mismatch'));
      expect(() => const FitDecoder(crcCheck: CrcCheck.strict).decode(bytes),
          throwsA(isA<FitFormatException>()));
    });

    test('zero header CRC is accepted', () {
      final bytes = wrapFit(records);
      bytes[12] = 0;
      bytes[13] = 0;
      // The file CRC covers the header, so recompute it.
      ByteData.sublistView(bytes).setUint16(bytes.length - 2,
          fitCrc(bytes, end: bytes.length - 2), Endian.little);
      expect(const FitDecoder(crcCheck: CrcCheck.strict).decode(bytes).warnings,
          isEmpty);
    });

    test('file CRC mismatch warns, throws or is ignored', () {
      final bytes = wrapFit(records);
      bytes[bytes.length - 1] ^= 0x01;
      expect(const FitDecoder().decode(bytes).warnings,
          contains('File CRC mismatch'));
      expect(const FitDecoder(crcCheck: CrcCheck.ignore).decode(bytes).warnings,
          isEmpty);
      expect(() => const FitDecoder(crcCheck: CrcCheck.strict).decode(bytes),
          throwsA(isA<FitFormatException>()));
    });

    test('truncated file decodes complete records and warns', () {
      final full = syntheticRun();
      final file = const FitDecoder().decode(full.sublist(0, full.length ~/ 2));
      expect(file.warnings, isNotEmpty);
      expect(FitActivity.fromFile(file).records, isNotEmpty);
    });
  });

  group('records', () {
    test('compressed timestamp headers incl. rollover', () {
      const t = 1000000030; // low 5 bits = 30
      final ts = ByteData(4)..setUint32(0, t, Endian.little);
      final bytes = wrapFit([
        // local 0: record {timestamp uint32, heart_rate uint8}
        0x40, 0, 0, 20, 0, 2, 253, 4, 0x86, 3, 1, 0x02,
        0x00, ...ts.buffer.asUint8List(), 100,
        // local 1: record {heart_rate uint8}
        0x41, 0, 0, 20, 0, 1, 3, 1, 0x02,
        0x80 | (1 << 5) | 31, 101, // +1 s
        0x80 | (1 << 5) | 2, 102, // wraps: +4 s
      ]);
      final file = const FitDecoder(crcCheck: CrcCheck.strict).decode(bytes);
      expect(file.messages.map((m) => m.timestamp), [t, t + 1, t + 4]);
      expect(file.messages.map((m) => m.intValue(3)), [100, 101, 102]);
    });

    test('skips developer fields and handles big-endian definitions', () {
      final bytes = wrapFit([
        // big-endian record def with 1 dev field of 3 bytes
        0x60, 0, 1, 0, 20, 2, 6, 2, 0x84, 5, 4, 0x86, 1, 0, 3, 0,
        0x00, 0x0B, 0xB8, 0x00, 0x00, 0x75, 0x30, 0xAA, 0xBB, 0xCC,
        0x00, 0x0B, 0xB9, 0x00, 0x00, 0x75, 0x94, 0xAA, 0xBB, 0xCC,
      ]);
      final records = FitActivity.fromFile(
              const FitDecoder(crcCheck: CrcCheck.strict).decode(bytes))
          .records;
      expect(records.map((r) => r.speed), [3.0, 3.001]);
      expect(records.map((r) => r.distance), [300.0, 301.0]);
    });

    test('invalid values decode as null', () {
      final w = FitWriter()
        ..write(FitMesgNum.record, [
          const FitField(FitRecordField.heartRate, FitBaseType.uint8, 0xFF),
          const FitField(
              FitRecordField.positionLat, FitBaseType.sint32, 0x7FFFFFFF),
          const FitField(FitRecordField.speed, FitBaseType.uint16, 1500),
        ]);
      final r = FitActivity.fromFile(const FitDecoder().decode(w.finish()))
          .records
          .single;
      expect(r.heartRate, isNull);
      expect(r.positionLat, isNull);
      expect(r.speed, 1.5);
    });

    test('undefined local message type throws', () {
      expect(() => const FitDecoder().decode(wrapFit([0x03, 1, 2])),
          throwsA(isA<FitFormatException>()));
    });
  });

  group('activity', () {
    for (final endian in [Endian.little, Endian.big]) {
      test('synthetic run decodes (${endian == Endian.little ? 'LE' : 'BE'})',
          () {
        final file = const FitDecoder(crcCheck: CrcCheck.strict)
            .decode(syntheticRun(endian: endian));
        final a = FitActivity.fromFile(file);
        expect(a.isActivity, isTrue);
        expect(a.fileId!.serialNumber, 42);
        expect(a.fileId!.timeCreated, activityStart);

        final s = a.sessions.single;
        expect(FitSport.fromValue(s.sport), FitSport.running);
        expect(s.subSport, FitSubSport.trail);
        expect(s.startTime, activityStart);
        expect(s.totalTimerTime, 600);
        expect(s.totalDistance, 1800);
        expect(s.avgSpeed, 3.0);
        expect(s.avgHeartRate, 140);
        expect(s.maxHeartRate, 159);
        expect(s.totalAscent, 12);

        expect(a.laps.single.totalDistance, 1800);
        expect(a.records, hasLength(601));
        final r = a.records[10];
        expect(r.timestamp, activityStart.add(const Duration(seconds: 10)));
        expect(r.distance, 30);
        expect(r.speed, 3.0);
        expect(r.altitude, 520);
        expect(r.cadence, 85);
        expect(r.heartRate, 120);
        expect(r.latitude, closeTo(48.113, 0.001));
        expect(a.records.last.heartRate, 159);
      });
    }

    test('fitDateTime epoch and system-time values', () {
      expect(fitDateTime(0x10000000),
          DateTime.utc(1989, 12, 31).add(const Duration(seconds: 0x10000000)));
      expect(fitDateTime(5), isNull);
      expect(toFitDateTime(DateTime.utc(1989, 12, 31, 0, 1)), 60);
    });

    test('timer stop/start events become pauses', () {
      final t0 = toFitDateTime(activityStart);
      final w = FitWriter();
      void event(int offset, int type) => w.write(FitMesgNum.event, [
            FitField(FitCommonField.timestamp, FitBaseType.uint32, t0 + offset),
            const FitField(FitEventField.event, FitBaseType.enumType, 0),
            FitField(FitEventField.eventType, FitBaseType.enumType, type),
          ]);
      event(0, FitEventType.start);
      event(100, FitEventType.stopAll);
      event(160, FitEventType.start);
      event(300, FitEventType.stop);
      event(301, FitEventType.stopAll);
      event(330, FitEventType.start);
      event(600, FitEventType.stopAll);
      final a = FitActivity.fromFile(const FitDecoder().decode(w.finish()));
      DateTime at(int s) => activityStart.add(Duration(seconds: s));
      expect(a.timerPauses, [(at(100), at(160)), (at(300), at(330))]);
    });

    test('workout name of an activity started from a workout', () {
      FitActivity read(String? name) {
        final w = FitWriter();
        if (name != null) {
          w.write(FitMesgNum.workout, [
            FitField(FitWorkoutField.wktName, FitBaseType.string, name),
          ]);
        }
        return FitActivity.fromFile(const FitDecoder().decode(w.finish()));
      }

      expect(read('10 × 200 m [FF]').workoutName, '10 × 200 m [FF]');
      expect(read('  ').workoutName, isNull);
      expect(read(null).workoutName, isNull);
    });
  });

  group('workout', () {
    final workout = FitWorkout(
      name: '5x1k',
      steps: [
        const FitWorkoutStep(
          name: 'Warm up',
          intensity: FitIntensity.warmup,
          duration: FitTimeDuration(Duration(minutes: 10)),
          notes: 'Easy',
        ),
        const FitWorkoutStep(
          name: '1 km',
          duration: FitDistanceDuration(1000),
          target: FitSpeedTarget(4.0, 4.3),
        ),
        const FitWorkoutStep(
          intensity: FitIntensity.recovery,
          duration: FitTimeDuration(Duration(minutes: 2)),
          target: FitHeartRateTarget(120, 140),
        ),
        FitWorkoutStep.repeat(fromStep: 1, times: 5),
        const FitWorkoutStep(
          name: 'Cool down',
          intensity: FitIntensity.cooldown,
          duration: FitOpenDuration(),
        ),
      ],
    );
    final created = DateTime.utc(2026, 9, 1, 12);

    test('encode → decode round trip', () {
      final file = const FitDecoder(crcCheck: CrcCheck.strict)
          .decode(workout.encode(timeCreated: created, serialNumber: 7));
      final id = FitActivity.fromFile(file).fileId!;
      expect(id.type, FitFileType.workout);
      expect(id.manufacturer, FitManufacturer.development);
      expect(id.serialNumber, 7);
      expect(id.timeCreated, created);

      final w = FitWorkout.fromFile(file)!;
      expect(w.name, '5x1k');
      expect(w.sport, FitSport.running);
      expect(w.steps, hasLength(5));

      final [warm, rep, rec, repeat, cool] = w.steps;
      expect(warm.name, 'Warm up');
      expect(warm.notes, 'Easy');
      expect(warm.intensity, FitIntensity.warmup);
      expect((warm.duration as FitTimeDuration).duration,
          const Duration(minutes: 10));
      expect(warm.target, isA<FitOpenTarget>());

      expect((rep.duration as FitDistanceDuration).meters, 1000);
      final speed = rep.target as FitSpeedTarget;
      expect((speed.low, speed.high), (4.0, 4.3));

      expect(rec.intensity, FitIntensity.recovery);
      final hr = rec.target as FitHeartRateTarget;
      expect((hr.low, hr.high), (120, 140));

      final r = repeat.duration as FitRepeatDuration;
      expect((r.fromStep, r.times), (1, 5));
      expect(repeat.intensity, isNull);

      expect(cool.duration, isA<FitOpenDuration>());
      expect(cool.intensity, FitIntensity.cooldown);
    });

    test('raw field values follow the FIT profile', () {
      final file =
          const FitDecoder().decode(workout.encode(timeCreated: created));
      final wkt = file.byNum(FitMesgNum.workout).single;
      expect(wkt.intValue(FitWorkoutField.numValidSteps), 5);
      expect(wkt.intValue(FitWorkoutField.sport), 1);

      final steps = file.byNum(FitMesgNum.workoutStep).toList();
      int? v(int step, int field) => steps[step].intValue(field);
      expect(v(0, FitWorkoutStepField.durationType), FitDurationType.time);
      expect(v(0, FitWorkoutStepField.durationValue), 600000);
      expect(v(0, FitWorkoutStepField.targetType), FitTargetType.open);
      expect(v(1, FitWorkoutStepField.durationValue), 100000);
      expect(v(1, FitWorkoutStepField.targetValue), 0);
      expect(v(1, FitWorkoutStepField.customTargetValueLow), 4000);
      expect(v(1, FitWorkoutStepField.customTargetValueHigh), 4300);
      expect(v(2, FitWorkoutStepField.customTargetValueLow), 220);
      expect(v(2, FitWorkoutStepField.customTargetValueHigh), 240);
      expect(v(3, FitWorkoutStepField.durationType), 6);
      expect(v(3, FitWorkoutStepField.durationValue), 1);
      expect(v(3, FitWorkoutStepField.targetValue), 5);
      expect(v(4, FitWorkoutStepField.durationType), FitDurationType.open);
      expect(steps.map((s) => s.intValue(FitCommonField.messageIndex)),
          [0, 1, 2, 3, 4]);
    });

    test('long strings are truncated to 255 bytes', () {
      final long = FitWorkout(name: 'x' * 400, steps: const []);
      final w = FitWorkout.fromFile(const FitDecoder(crcCheck: CrcCheck.strict)
          .decode(long.encode(timeCreated: created)))!;
      expect(w.name.length, 254);
    });
  });
}
