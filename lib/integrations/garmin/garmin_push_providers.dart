import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../fit/watch_export_service.dart';
import 'garmin_providers.dart';
import 'garmin_push_service.dart';

final garminPushServiceProvider = Provider<GarminPushService>(
  (ref) => GarminPushService(
    ref.watch(databaseProvider),
    ref.watch(garminClientProvider),
    paceProfile: () => ref.read(paceProfileProvider),
  ),
);

final watchExportServiceProvider = Provider<WatchExportService>(
  (ref) => WatchExportService(
    ref.watch(databaseProvider),
    paceProfile: () => ref.read(paceProfileProvider),
  ),
);
