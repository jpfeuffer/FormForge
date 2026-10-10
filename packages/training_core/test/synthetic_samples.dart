import 'package:training_core/training_core.dart';

/// A stretch of constant [speed] (m/s) and [hr] (bpm, 0 = none), at 1 Hz.
typedef Part = ({int seconds, double speed, int hr});

Part part(int seconds, double speed, [int hr = 0]) =>
    (seconds: seconds, speed: speed, hr: hr);

/// Concatenates [parts] into 1 Hz samples with cumulative distance.
List<Sample> synth(List<Part> parts, {bool distance = true}) {
  final out = <Sample>[
    Sample(second: 0, speed: 0, distance: distance ? 0 : null),
  ];
  var t = 0, d = 0.0;
  for (final p in parts) {
    for (var i = 0; i < p.seconds; i++) {
      t++;
      d += p.speed;
      out.add(
        Sample(
          second: t,
          speed: p.speed,
          hr: p.hr == 0 ? null : p.hr,
          distance: distance ? d : null,
        ),
      );
    }
  }
  return out;
}
