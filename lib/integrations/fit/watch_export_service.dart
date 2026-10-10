import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:file_picker/file_picker.dart';
import 'package:training_core/training_core.dart';

import '../../data/database.dart';
import 'workout_fit_export.dart';

sealed class WatchExportResult {
  const WatchExportResult();

  String get message;
}

final class ExportNothing extends WatchExportResult {
  const ExportNothing();

  @override
  String get message => 'No planned workouts to export in this period';
}

final class ExportCancelled extends WatchExportResult {
  const ExportCancelled();

  @override
  String get message => 'Export cancelled';
}

/// Files were written straight into `GARMIN/NewFiles` of a mounted watch.
final class ExportedToWatch extends WatchExportResult {
  const ExportedToWatch(this.count, this.directory);
  final int count;
  final String directory;

  @override
  String get message =>
      'Copied $count workouts to the watch. Eject it and they show up under '
      'Training > Workouts.';
}

/// No mounted watch found; the user has to copy the files over.
final class ExportedToFolder extends WatchExportResult {
  const ExportedToFolder(this.count, this.directory);
  final int count;
  final String? directory;

  String get instructions =>
      'Connect the watch and copy the FIT files into its GARMIN/NewFiles '
      'folder using File Explorer (Windows) or Android File Transfer / Finder. '
      'The workouts appear on the watch under Training > Workouts after it '
      'is disconnected.';

  @override
  String get message =>
      'Saved $count FIT workouts${directory == null ? '' : ' to $directory'}. '
      '$instructions';
}

final class ExportFailed extends WatchExportResult {
  const ExportFailed(this.reason);
  final String reason;

  @override
  String get message => 'FIT export failed: $reason';
}

/// Finds watches mounted as a drive and copies workout files into them.
class WatchUsbExporter {
  WatchUsbExporter({List<Directory> Function()? volumes})
    : _volumes = volumes ?? defaultVolumes;

  final List<Directory> Function() _volumes;

  /// `GARMIN/NewFiles` of every volume that has one.
  List<Directory> findNewFilesDirs() => [
    for (final volume in _volumes()) ?_newFiles(volume),
  ];

  Future<int> copyFiles(Directory target, List<FitWorkoutFile> files) async {
    for (final f in files) {
      await File(_join(target.path, f.name)).writeAsBytes(f.bytes);
    }
    return files.length;
  }

  /// Mount points where a watch could show up on this OS.
  static List<Directory> defaultVolumes() {
    if (Platform.isWindows) {
      return [
        for (final c in 'DEFGHIJKLMNOPQRSTUVWXYZ'.split(''))
          if (Directory('$c:\\').existsSync()) Directory('$c:\\'),
      ];
    }
    if (Platform.isMacOS) return _subdirs(Directory('/Volumes'));
    if (Platform.isLinux) {
      return [
        for (final base in ['/media', '/run/media'])
          for (final d in _subdirs(Directory(base))) ...[d, ..._subdirs(d)],
      ];
    }
    return const [];
  }

  static List<Directory> _subdirs(Directory dir) {
    try {
      return dir.listSync(followLinks: false).whereType<Directory>().toList();
    } on FileSystemException {
      return const [];
    }
  }

  static Directory? _newFiles(Directory volume) {
    final garmin = _child(volume, 'GARMIN');
    return garmin == null ? null : _child(garmin, 'NewFiles');
  }

  /// Case-insensitive, as FAT volumes are.
  static Directory? _child(Directory parent, String name) {
    for (final d in _subdirs(parent)) {
      if (d.path.split(RegExp(r'[\\/]')).last.toLowerCase() ==
          name.toLowerCase()) {
        return d;
      }
    }
    return null;
  }
}

String _join(String dir, String name) => dir.endsWith('/') || dir.endsWith(r'\')
    ? '$dir$name'
    : '$dir${Platform.pathSeparator}$name';

/// Exports planned workouts as FIT files to the watch or a user-chosen folder.
class WatchExportService {
  WatchExportService(
    this._db, {
    PaceProfile? Function()? paceProfile,
    WatchUsbExporter? usb,
    this._pickFolder,
    DateTime Function()? clock,
  }) : _paceProfile = paceProfile ?? (() => null),
       _usb = usb ?? WatchUsbExporter(),
       _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final PaceProfile? Function() _paceProfile;
  final WatchUsbExporter _usb;
  final Future<String?> Function()? _pickFolder;
  final DateTime Function() _clock;

  /// FIT files for the planned, not yet past workouts in `[from, to]`.
  Future<List<FitWorkoutFile>> buildFitFiles(DateTime from, DateTime to) async {
    final start = DateTime(from.year, from.month, from.day);
    final end = DateTime(to.year, to.month, to.day + 1);
    final now = _clock();
    final today = DateTime(now.year, now.month, now.day);
    final rows =
        await (_db.select(_db.plannedWorkouts)
              ..where(
                (t) =>
                    t.date.isBiggerOrEqualValue(start) &
                    t.date.isSmallerThanValue(end) &
                    t.status.equalsValue(WorkoutStatus.planned),
              )
              ..orderBy([
                (t) => OrderingTerm.asc(t.date),
                (t) => OrderingTerm.asc(t.startMinute),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();
    final profile = _paceProfile();
    final used = <String, int>{};
    final files = <FitWorkoutFile>[];
    for (final row in rows) {
      if (row.date.isBefore(today)) continue;
      final workout = Workout.fromJson(
        (jsonDecode(row.workoutJson) as Map).cast<String, Object?>(),
      );
      var name = fitFileName(row.date, row.title);
      final seen = used.update(name, (n) => n + 1, ifAbsent: () => 1);
      if (seen > 1) {
        name = fitFileName(row.date, row.title, duplicateIndex: seen);
      }
      final fit = toFitWorkout(workout, profile: profile, title: row.title);
      files.add(FitWorkoutFile(name, fit.encode(timeCreated: now)));
    }
    return files;
  }

  /// Copies the workouts onto a mounted watch, else lets the user pick where
  /// to save them (most watches are MTP devices and have no drive letter).
  Future<WatchExportResult> exportFitForRange(
    DateTime from,
    DateTime to,
  ) async {
    try {
      final files = await buildFitFiles(from, to);
      if (files.isEmpty) return const ExportNothing();

      final watch = _usb.findNewFilesDirs();
      if (watch.isNotEmpty) {
        final count = await _usb.copyFiles(watch.first, files);
        return ExportedToWatch(count, watch.first.path);
      }
      return await _saveWherePicked(files);
    } on Object catch (e) {
      return ExportFailed('$e');
    }
  }

  Future<WatchExportResult> _saveWherePicked(List<FitWorkoutFile> files) async {
    final mobile = Platform.isAndroid || Platform.isIOS;
    if (mobile && _pickFolder == null) {
      var saved = 0;
      for (final f in files) {
        final target = await FilePicker.saveFile(
          fileName: f.name,
          bytes: f.bytes,
          dialogTitle: 'Save FIT workout',
        );
        if (target == null) break;
        saved++;
      }
      return saved == 0
          ? const ExportCancelled()
          : ExportedToFolder(saved, null);
    }
    final dir = await (_pickFolder ?? _pickDesktopFolder)();
    if (dir == null) return const ExportCancelled();
    final count = await _usb.copyFiles(Directory(dir), files);
    return ExportedToFolder(count, dir);
  }

  static Future<String?> _pickDesktopFolder() => FilePicker.getDirectoryPath(
    dialogTitle: 'Folder for FIT workouts (e.g. the watch\'s GARMIN/NewFiles)',
  );
}
