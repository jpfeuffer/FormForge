import 'dart:typed_data';

import 'package:fit_io/fit_io.dart';

final runStart = DateTime.utc(2026, 9, 20, 6, 45);

/// Synthetic steady run: 1 Hz records at 3 m/s; HR 140 then 147 in the
/// second half (≈4.8 % decoupling).
Uint8List syntheticRunFit({int serialNumber = 1234, int seconds = 1200}) {
  final start = toFitDateTime(runStart);
  final w = FitWriter()
    ..write(FitMesgNum.fileId, [
      const FitField(
        FitFileIdField.type,
        FitBaseType.enumType,
        FitFileType.activity,
      ),
      const FitField(
        FitFileIdField.manufacturer,
        FitBaseType.uint16,
        FitManufacturer.garmin,
      ),
      FitField(FitFileIdField.serialNumber, FitBaseType.uint32z, serialNumber),
      FitField(FitFileIdField.timeCreated, FitBaseType.uint32, start),
    ]);
  for (var i = 0; i <= seconds; i++) {
    w.write(FitMesgNum.record, [
      FitField(FitCommonField.timestamp, FitBaseType.uint32, start + i),
      FitField(FitRecordField.distance, FitBaseType.uint32, i * 300),
      const FitField(FitRecordField.enhancedSpeed, FitBaseType.uint32, 3000),
      FitField(
        FitRecordField.heartRate,
        FitBaseType.uint8,
        i <= seconds ~/ 2 ? 140 : 147,
      ),
      FitField(FitRecordField.positionLat, FitBaseType.sint32, 574000000 + i),
      FitField(FitRecordField.positionLong, FitBaseType.sint32, 136000000 + i),
    ]);
  }
  w.write(FitMesgNum.session, [
    FitField(FitCommonField.timestamp, FitBaseType.uint32, start + seconds),
    FitField(FitSessionField.startTime, FitBaseType.uint32, start),
    FitField(
      FitSessionField.sport,
      FitBaseType.enumType,
      FitSport.running.value,
    ),
    const FitField(
      FitSessionField.subSport,
      FitBaseType.enumType,
      FitSubSport.street,
    ),
    FitField(
      FitSessionField.totalElapsedTime,
      FitBaseType.uint32,
      seconds * 1000,
    ),
    FitField(
      FitSessionField.totalTimerTime,
      FitBaseType.uint32,
      seconds * 1000,
    ),
    FitField(FitSessionField.totalDistance, FitBaseType.uint32, seconds * 300),
    const FitField(FitSessionField.enhancedAvgSpeed, FitBaseType.uint32, 3000),
    const FitField(FitSessionField.avgHeartRate, FitBaseType.uint8, 143),
    const FitField(FitSessionField.maxHeartRate, FitBaseType.uint8, 147),
  ]);
  return w.finish();
}
