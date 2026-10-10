// Numbers from the Garmin FIT SDK profile (Profile.xlsx), cross-checked with
// the generated profile of python-fitparse (fitparse/profile.py).

abstract final class FitMesgNum {
  static const fileId = 0;
  static const session = 18;
  static const lap = 19;
  static const record = 20;
  static const event = 21;
  static const workout = 26;
  static const workoutStep = 27;
  static const activity = 34;
  static const fieldDescription = 206;
  static const developerDataId = 207;
}

/// Field numbers shared by many messages.
abstract final class FitCommonField {
  static const timestamp = 253;
  static const messageIndex = 254;
}

abstract final class FitFileIdField {
  static const type = 0;
  static const manufacturer = 1;
  static const product = 2;
  static const serialNumber = 3;
  static const timeCreated = 4;
  static const productName = 8;
}

abstract final class FitSessionField {
  static const startTime = 2;
  static const sport = 5;
  static const subSport = 6;
  static const totalElapsedTime = 7;
  static const totalTimerTime = 8;
  static const totalDistance = 9;
  static const avgSpeed = 14;
  static const maxSpeed = 15;
  static const avgHeartRate = 16;
  static const maxHeartRate = 17;
  static const totalAscent = 22;
  static const enhancedAvgSpeed = 124;
  static const enhancedMaxSpeed = 125;
}

abstract final class FitLapField {
  static const startTime = 2;
  static const totalElapsedTime = 7;
  static const totalTimerTime = 8;
  static const totalDistance = 9;
  static const avgSpeed = 13;
  static const avgHeartRate = 15;
  static const maxHeartRate = 16;
  static const totalAscent = 21;
  static const enhancedAvgSpeed = 110;
}

abstract final class FitRecordField {
  static const positionLat = 0;
  static const positionLong = 1;
  static const altitude = 2;
  static const heartRate = 3;
  static const cadence = 4;
  static const distance = 5;
  static const speed = 6;
  static const enhancedSpeed = 73;
  static const enhancedAltitude = 78;
}

abstract final class FitEventField {
  static const event = 0;
  static const eventType = 1;

  /// For timer events: timer_trigger (0 manual, 1 auto, 2 fitness equipment).
  static const data = 3;
}

abstract final class FitEventValue {
  static const timer = 0;
}

abstract final class FitEventType {
  static const start = 0;
  static const stop = 1;
  static const stopAll = 4;
  static const stopDisable = 8;
  static const stopDisableAll = 9;

  static bool isStop(int? t) =>
      t == stop || t == stopAll || t == stopDisable || t == stopDisableAll;
}

abstract final class FitWorkoutField {
  static const sport = 4;
  static const numValidSteps = 6;
  static const wktName = 8;
  static const subSport = 11;
}

abstract final class FitWorkoutStepField {
  static const wktStepName = 0;
  static const durationType = 1;
  static const durationValue = 2;
  static const targetType = 3;
  static const targetValue = 4;
  static const customTargetValueLow = 5;
  static const customTargetValueHigh = 6;
  static const intensity = 7;
  static const notes = 8;
}

abstract final class FitFileType {
  static const activity = 4;
  static const workout = 5;
  static const course = 6;
}

abstract final class FitManufacturer {
  static const garmin = 1;
  static const development = 255;
}

enum FitSport {
  generic(0),
  running(1),
  cycling(2),
  transition(3),
  fitnessEquipment(4),
  swimming(5),
  training(10),
  walking(11),
  crossCountrySkiing(12),
  rowing(15),
  hiking(17),
  multisport(18),
  eBiking(21);

  const FitSport(this.value);
  final int value;

  static FitSport? fromValue(int? value) {
    for (final s in values) {
      if (s.value == value) return s;
    }
    return null;
  }
}

abstract final class FitSubSport {
  static const generic = 0;
  static const treadmill = 1;
  static const street = 2;
  static const trail = 3;
  static const track = 4;
  static const indoorCycling = 6;
  static const strengthTraining = 20;
  static const indoorRunning = 45;
}

enum FitIntensity {
  active(0),
  rest(1),
  warmup(2),
  cooldown(3),
  recovery(4);

  const FitIntensity(this.value);
  final int value;

  static FitIntensity? fromValue(int? value) {
    for (final i in values) {
      if (i.value == value) return i;
    }
    return null;
  }
}

/// `wkt_step_duration` values.
abstract final class FitDurationType {
  static const time = 0;
  static const distance = 1;
  static const open = 5;
  static const repeatUntilStepsComplete = 6;
}

/// `wkt_step_target` values.
abstract final class FitTargetType {
  static const speed = 0;
  static const heartRate = 1;
  static const open = 2;
}
