import 'dart:convert';
import 'dart:typed_data';

import 'package:fit_io/fit_io.dart';

/// Wraps raw record bytes into a FIT file with a valid header and CRCs.
Uint8List wrapFit(List<int> records, {int headerSize = 14}) {
  final out = Uint8List(headerSize + records.length + 2);
  final data = ByteData.sublistView(out)
    ..setUint8(0, headerSize)
    ..setUint8(1, 0x10)
    ..setUint16(2, 2140, Endian.little)
    ..setUint32(4, records.length, Endian.little);
  out.setRange(8, 12, ascii.encode('.FIT'));
  if (headerSize == 14) {
    data.setUint16(12, fitCrc(out, end: 12), Endian.little);
  }
  out.setRange(headerSize, headerSize + records.length, records);
  data.setUint16(
      out.length - 2, fitCrc(out, end: out.length - 2), Endian.little);
  return out;
}

final activityStart = DateTime.utc(2026, 5, 3, 7, 30);

/// Synthetic 10-minute run: 1 Hz records at 3 m/s with HR ramping 120→159.
Uint8List syntheticRun({
  int serialNumber = 42,
  Duration duration = const Duration(minutes: 10),
  Endian endian = Endian.little,
}) {
  final start = toFitDateTime(activityStart);
  final seconds = duration.inSeconds;
  final w = FitWriter(endian: endian)
    ..write(FitMesgNum.fileId, [
      const FitField(
          FitFileIdField.type, FitBaseType.enumType, FitFileType.activity),
      const FitField(FitFileIdField.manufacturer, FitBaseType.uint16,
          FitManufacturer.garmin),
      FitField(FitFileIdField.serialNumber, FitBaseType.uint32z, serialNumber),
      FitField(FitFileIdField.timeCreated, FitBaseType.uint32, start),
    ]);
  for (var i = 0; i <= seconds; i++) {
    w.write(FitMesgNum.record, [
      FitField(FitCommonField.timestamp, FitBaseType.uint32, start + i),
      FitField(
          FitRecordField.positionLat, FitBaseType.sint32, 574000000 + i * 100),
      FitField(
          FitRecordField.positionLong, FitBaseType.sint32, 136000000 - i * 50),
      FitField(FitRecordField.distance, FitBaseType.uint32, i * 300),
      FitField(FitRecordField.enhancedSpeed, FitBaseType.uint32, 3000),
      FitField(
          FitRecordField.enhancedAltitude, FitBaseType.uint32, (520 + 500) * 5),
      FitField(FitRecordField.heartRate, FitBaseType.uint8,
          120 + i * 40 ~/ (seconds + 1)),
      const FitField(FitRecordField.cadence, FitBaseType.uint8, 85),
    ]);
  }
  final session = [
    FitField(FitCommonField.timestamp, FitBaseType.uint32, start + seconds),
    FitField(FitSessionField.startTime, FitBaseType.uint32, start),
    FitField(
        FitSessionField.sport, FitBaseType.enumType, FitSport.running.value),
    const FitField(
        FitSessionField.subSport, FitBaseType.enumType, FitSubSport.trail),
    FitField(
        FitSessionField.totalElapsedTime, FitBaseType.uint32, seconds * 1000),
    FitField(
        FitSessionField.totalTimerTime, FitBaseType.uint32, seconds * 1000),
    FitField(FitSessionField.totalDistance, FitBaseType.uint32, seconds * 300),
    const FitField(FitSessionField.avgSpeed, FitBaseType.uint16, 3000),
    const FitField(FitSessionField.enhancedAvgSpeed, FitBaseType.uint32, 3000),
    const FitField(FitSessionField.avgHeartRate, FitBaseType.uint8, 140),
    const FitField(FitSessionField.maxHeartRate, FitBaseType.uint8, 159),
    const FitField(FitSessionField.totalAscent, FitBaseType.uint16, 12),
  ];
  return (w
        ..write(FitMesgNum.lap, [
          const FitField(FitCommonField.messageIndex, FitBaseType.uint16, 0),
          FitField(
              FitCommonField.timestamp, FitBaseType.uint32, start + seconds),
          FitField(FitLapField.startTime, FitBaseType.uint32, start),
          FitField(
              FitLapField.totalTimerTime, FitBaseType.uint32, seconds * 1000),
          FitField(
              FitLapField.totalDistance, FitBaseType.uint32, seconds * 300),
          const FitField(FitLapField.avgHeartRate, FitBaseType.uint8, 140),
        ])
        ..write(FitMesgNum.session, session))
      .finish();
}
