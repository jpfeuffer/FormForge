# FormForge

Local-first running & strength training planner with Garmin sync. No server:
your data stays on your device, you bring your own Garmin account and AI key.

- Adaptive running plans from target paces and past runs (VDOT, MAS, critical
  speed, LTHR), regular test runs, HR/pace evaluation.
- Garmin Connect sync (activities in, structured workouts + calendar out),
  FIT import as fallback.
- Strength/calisthenics sessions by focus area, scheduled alongside runs.

Targets: Android, Windows, macOS, iOS (Flutter).

## Development

```sh
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter test
(cd packages/training_core && dart test)
flutter run -d windows
```

Training science lives in [packages/training_core](packages/training_core)
(pure Dart, no Flutter).
