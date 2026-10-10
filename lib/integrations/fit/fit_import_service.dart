import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fit_io/fit_io.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/activity_merge.dart';
import '../../data/activity_streams.dart';
import '../../data/database.dart';
import '../../features/adaptation/matching_service.dart';

class FitImportException implements Exception {
  const FitImportException(this.message);
  final String message;

  @override
  String toString() => message;
}

class FitImportFailure {
  const FitImportFailure(this.file, this.reason);
  final String file;
  final String reason;
}

class FitImportSummary {
  final imported = <int>[];
  final duplicates = <String>[];
  final failed = <FitImportFailure>[];

  String get message => [
    'Imported ${imported.length}',
    if (duplicates.isNotEmpty) '${duplicates.length} already imported',
    if (failed.isNotEmpty)
      '${failed.length} failed (${failed.map((f) => '${f.file}: ${f.reason}').join('; ')})',
  ].join(' · ');
}

/// Imports activity FIT files into [Activities] and [ActivityStreams].
class FitImportService {
  FitImportService(
    this._db, {
    Future<Directory> Function()? storageDir,
    MatchingService? matcher,
  }) : _storageDir = storageDir ?? getApplicationDocumentsDirectory,
       _matcher = matcher ?? MatchingService(_db);

  final AppDatabase _db;
  final Future<Directory> Function() _storageDir;
  final MatchingService _matcher;

  /// Lets the user pick `.fit` files; `null` if the picker was cancelled.
  Future<FitImportSummary?> pickAndImport() async {
    // Mobile pickers filter by MIME/UTI, which `.fit` lacks.
    final mobile = Platform.isAndroid || Platform.isIOS;
    final files = await FilePicker.pickFiles(
      type: mobile ? FileType.any : FileType.custom,
      allowedExtensions: mobile ? null : const ['fit', 'FIT'],
    );
    if (files.isEmpty) return null;
    return importAll([
      for (final f in files) (name: f.name, bytes: await f.readAsBytes()),
    ]);
  }

  Future<FitImportSummary> importAll(
    List<({String name, Uint8List bytes})> files,
  ) async {
    final summary = FitImportSummary();
    for (final f in files) {
      try {
        final id = await _importBytes(f.name, f.bytes);
        id == null ? summary.duplicates.add(f.name) : summary.imported.add(id);
      } on FitImportException catch (e) {
        summary.failed.add(FitImportFailure(f.name, e.message));
      } on FitFormatException catch (e) {
        summary.failed.add(
          FitImportFailure(f.name, 'not a FIT file (${e.message})'),
        );
      } catch (e) {
        summary.failed.add(FitImportFailure(f.name, '$e'));
      }
    }
    await _matcher.matchAll();
    return summary;
  }

  /// Returns the new activity id, or `null` if the file was imported before.
  /// An activity already synced from Garmin is enriched instead of duplicated
  /// (its id is returned only if the file added something).
  Future<int?> importBytes(String fileName, Uint8List bytes) async {
    final id = await _importBytes(fileName, bytes);
    await _matcher.matchAll();
    return id;
  }

  Future<int?> _importBytes(String fileName, Uint8List bytes) async {
    final fit = FitActivity.fromFile(await _decode(bytes));
    if (!fit.isActivity) {
      throw FitImportException(
        'not an activity file (${_fileTypes[fit.fileId?.type] ?? 'type ${fit.fileId?.type}'})',
      );
    }
    final records = fit.records.where((r) => r.timestamp != null).toList();
    if (fit.sessions.isEmpty && records.isEmpty) {
      throw const FitImportException('no session or record data');
    }

    final externalId = _externalId(fit.fileId, bytes);
    final existing = await (_db.select(
      _db.activities,
    )..where((t) => t.externalId.equals(externalId))).getSingleOrNull();
    if (existing != null) return null;

    final activity = _activity(fit, records, externalId);
    final start = activity.startTime.value;
    final streams = records.isEmpty
        ? null
        : ActivityStreamData.fromFitRecords(
            records,
            start,
            pauses: fit.timerPauses,
          );

    final dir = Directory('${(await _storageDir()).path}/fit');
    await dir.create(recursive: true);
    final file = File(
      '${dir.path}/${externalId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.fit',
    );
    await file.writeAsBytes(bytes, flush: true);
    try {
      final merger = ActivityMerger(_db);
      final twin = await merger.findTwin(
        source: ActivitySource.fitFile,
        sport: activity.sport.value,
        start: start,
      );
      if (twin != null && twin.source == ActivitySource.garmin) {
        final changed = await merger.enrich(
          twin.id,
          streams: streams,
          fitPath: file.path,
          workoutName: fit.workoutName,
        );
        if (!changed && twin.fitPath != file.path) await file.delete();
        return changed ? twin.id : null;
      }
      return await _db.transaction(() async {
        final id = await _db
            .into(_db.activities)
            .insert(
              activity.copyWith(
                fitPath: Value(file.path),
                workoutName: Value(fit.workoutName),
                workoutChecked: const Value(true),
              ),
            );
        if (streams != null) {
          await _db.into(_db.activityStreams).insert(streams.toCompanion(id));
        }
        return id;
      });
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  static Future<FitFile> _decode(Uint8List bytes) =>
      Isolate.run(() => const FitDecoder().decode(bytes));

  static const _fileTypes = {
    FitFileType.workout: 'workout',
    FitFileType.course: 'course',
    1: 'device',
    2: 'settings',
    3: 'sport',
    32: 'monitoring',
  };

  static String _externalId(FitFileId? id, Uint8List bytes) =>
      switch ((id?.serialNumber, id?.timeCreatedRaw)) {
        (final int serial, final int created) => 'fit:$serial:$created',
        _ => 'fit:sha256:${sha256.convert(bytes)}',
      };

  static ActivitiesCompanion _activity(
    FitActivity fit,
    List<FitRecord> records,
    String externalId,
  ) {
    final sessions = fit.sessions;
    final start =
        sessions.map((s) => s.startTime).nonNulls.firstOrNull ??
        records.firstOrNull?.timestamp ??
        fit.fileId?.timeCreated ??
        (throw const FitImportException('no start time'));

    double? sum(Iterable<num?> values) => values.nonNulls.isEmpty
        ? null
        : values.nonNulls.fold<double>(0, (a, b) => a + b);

    final durationS =
        sum(sessions.map((s) => s.totalTimerTime ?? s.totalElapsedTime)) ??
        (records.length < 2
            ? 0
            : records.last.timestamp!
                  .difference(records.first.timestamp!)
                  .inSeconds);
    final distanceM =
        sum(sessions.map((s) => s.totalDistance)) ??
        records.map((r) => r.distance).nonNulls.lastOrNull;
    final hrs = records.map((r) => r.heartRate).nonNulls.toList();
    final weighted = sessions.where(
      (s) => s.avgHeartRate != null && (s.totalTimerTime ?? 0) > 0,
    );
    final avgHr = weighted.isNotEmpty
        ? sum(weighted.map((s) => s.avgHeartRate! * s.totalTimerTime!))! /
              sum(weighted.map((s) => s.totalTimerTime))!
        : hrs.isEmpty
        ? null
        : hrs.reduce((a, b) => a + b) / hrs.length;
    final maxHr =
        sessions
            .map((s) => s.maxHeartRate)
            .nonNulls
            .fold<int?>(null, (a, b) => a == null ? b : max(a, b)) ??
        (hrs.isEmpty ? null : hrs.reduce(max));
    final avgSpeed =
        (sessions.length == 1 ? sessions.single.avgSpeed : null) ??
        (distanceM != null && durationS > 0 ? distanceM / durationS : null);

    final sport = _sport(sessions.firstOrNull);
    final sportName = sessions.map((s) => s.sport).toSet().length > 1
        ? 'multisport'
        : sport;
    return ActivitiesCompanion.insert(
      source: ActivitySource.fitFile,
      externalId: Value(externalId),
      startTime: start,
      sport: sportName,
      name: Value(_title(sportName)),
      distanceM: Value(distanceM),
      durationS: durationS.round(),
      avgHr: Value(avgHr),
      maxHr: Value(maxHr?.toDouble()),
      avgSpeed: Value(avgSpeed),
    );
  }

  /// Snake-case sport key, aligned with Garmin Connect activity type keys.
  static String _sport(FitSession? s) {
    final sport = FitSport.fromValue(s?.sport);
    return switch ((sport, s?.subSport)) {
      (FitSport.running, FitSubSport.trail) => 'trail_running',
      (FitSport.running, FitSubSport.treadmill || FitSubSport.indoorRunning) =>
        'treadmill_running',
      (FitSport.running, FitSubSport.track) => 'track_running',
      (FitSport.cycling, FitSubSport.indoorCycling) => 'indoor_cycling',
      (FitSport.training, FitSubSport.strengthTraining) => 'strength_training',
      (final FitSport sport, _) => sport.name.replaceAllMapped(
        RegExp('[A-Z]'),
        (m) => '_${m[0]!.toLowerCase()}',
      ),
      _ => s?.sport == null ? 'generic' : 'sport_${s!.sport}',
    };
  }

  static String _title(String sport) {
    final words = sport.replaceAll('_', ' ');
    return words[0].toUpperCase() + words.substring(1);
  }
}
