import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';

import 'database.dart';

const snapshotLimit = 512 * 1024 * 1024;

class Snapshot {
  Snapshot(this.payload);

  final Map<String, Object?> payload;
  String get revision =>
      sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  Uint8List encode() {
    final bytes = utf8.encode(jsonEncode(payload));
    if (bytes.length > snapshotLimit) {
      throw const FormatException(
        'Backup exceeds the 512 MiB expanded size limit',
      );
    }
    return Uint8List.fromList(gzip.encode(bytes));
  }

  static Future<Snapshot> decode(List<int> bytes) async {
    if (bytes.length > snapshotLimit) {
      throw const FormatException('Backup is too large');
    }
    final output = BytesBuilder(copy: false);
    await for (final chunk in gzip.decoder.bind(Stream.value(bytes))) {
      if (output.length + chunk.length > snapshotLimit) {
        throw const FormatException('Expanded backup is too large');
      }
      output.add(chunk);
    }
    final value = jsonDecode(utf8.decode(output.takeBytes()));
    if (value is! Map<String, dynamic> ||
        value['format'] != 1 ||
        value['schema'] != 5 ||
        value['tables'] is! Map<String, dynamic> ||
        value['files'] is! Map<String, dynamic>) {
      throw const FormatException(
        'Unsupported FormForge backup format or schema',
      );
    }
    return Snapshot(Map<String, Object?>.from(value));
  }

  static Future<Snapshot> capture(AppDatabase db) => db.transaction(() async {
    final tables = <String, Object?>{};
    final files = <String, String>{};
    for (final table in db.allTables) {
      final order = table.$primaryKey.map((c) => '"${c.name}"').join(',');
      final rows = await db
          .customSelect(
            'SELECT * FROM "${table.actualTableName}" ORDER BY $order',
          )
          .get();
      tables[table.actualTableName] = [
        for (final row in rows)
          await _encodeRow(table.actualTableName, row.data, files),
      ];
    }
    return Snapshot({
      'format': 1,
      'schema': db.schemaVersion,
      'tables': tables,
      'files': Map.fromEntries(
        files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
      ),
    });
  });

  static Future<Map<String, Object?>> _encodeRow(
    String table,
    Map<String, Object?> row,
    Map<String, String> files,
  ) async {
    final encoded = <String, Object?>{};
    for (final entry in row.entries) {
      final value = entry.value;
      if (table == 'activities' && entry.key == 'fit_path' && value != null) {
        final bytes = await File(value as String).readAsBytes();
        final digest = sha256.convert(bytes).toString();
        files[digest] = base64Encode(bytes);
        encoded[entry.key] = digest;
      } else {
        encoded[entry.key] = value is Uint8List
            ? {'blob': base64Encode(value)}
            : value;
      }
    }
    return encoded;
  }

  Future<void> validate() async {
    final db = AppDatabase(NativeDatabase.memory());
    try {
      await apply(db, null);
      for (final table in db.allTables) {
        await db.select(table).get();
      }
      final streams = await db.select(db.activityStreams).get();
      for (final stream in streams) {
        final count = stream.sampleCount;
        if (count < 0 ||
            stream.seconds.length != count * 4 ||
            [
              stream.speed,
              stream.distance,
              stream.latitude,
              stream.longitude,
              stream.altitude,
            ].any((blob) => blob != null && blob.length != count * 4) ||
            (stream.heartRate != null && stream.heartRate!.length != count) ||
            (stream.timerStops != null && stream.timerStops!.length % 8 != 0)) {
          throw const FormatException('Invalid activity stream lengths');
        }
      }
    } finally {
      await db.close();
    }
  }

  Future<void> apply(AppDatabase db, Directory? filesDirectory) async {
    final tables = Map<String, dynamic>.from(payload['tables'] as Map);
    final files = Map<String, dynamic>.from(payload['files'] as Map);
    final expected = db.allTables.map((t) => t.actualTableName).toSet();
    if (tables.length != expected.length ||
        !expected.containsAll(tables.keys)) {
      throw const FormatException('Backup tables do not match this app');
    }
    final paths = <String, String>{};
    for (final entry in files.entries) {
      if (entry.value is! String) {
        throw const FormatException('Invalid FIT data');
      }
      final bytes = base64Decode(entry.value as String);
      if (sha256.convert(bytes).toString() != entry.key) {
        throw const FormatException('FIT file checksum mismatch');
      }
      paths[entry.key] = entry.key;
      if (filesDirectory != null) {
        await filesDirectory.create(recursive: true);
        final file = File(
          '${filesDirectory.path}${Platform.pathSeparator}${entry.key}.fit',
        );
        if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
        if (sha256.convert(await file.readAsBytes()).toString() != entry.key) {
          throw const FormatException('Stored FIT file checksum mismatch');
        }
        paths[entry.key] = file.path;
      }
    }
    await db.transaction(() async {
      await db.customStatement('PRAGMA defer_foreign_keys = ON');
      for (final table in db.allTables) {
        await db.customStatement('DELETE FROM "${table.actualTableName}"');
      }
      for (final table in db.allTables) {
        final rows = tables[table.actualTableName];
        if (rows is! List) throw const FormatException('Invalid backup rows');
        final columns = table.$columns.map((c) => c.name).toList();
        for (final raw in rows) {
          if (raw is! Map) throw const FormatException('Invalid backup row');
          final row = Map<String, dynamic>.from(raw);
          if (row.length != columns.length || !columns.every(row.containsKey)) {
            throw const FormatException('Invalid backup columns');
          }
          final values = <Object?>[];
          for (final column in columns) {
            var value = row[column];
            if (table.actualTableName == 'activities' &&
                column == 'fit_path' &&
                value != null) {
              value = paths[value];
              if (value == null) {
                throw const FormatException('Missing FIT file');
              }
            } else if (value is Map) {
              if (value.length != 1 || value['blob'] is! String) {
                throw const FormatException('Invalid binary field');
              }
              value = base64Decode(value['blob'] as String);
            } else if (value != null && value is! String && value is! num) {
              throw const FormatException('Invalid field value');
            }
            values.add(value);
          }
          await db.customStatement(
            'INSERT INTO "${table.actualTableName}" (${columns.map((c) => '"$c"').join(',')}) '
            'VALUES (${List.filled(columns.length, '?').join(',')})',
            values,
          );
        }
      }
      if ((await db.customSelect('PRAGMA foreign_key_check').get())
          .isNotEmpty) {
        throw const FormatException('Broken backup references');
      }
      db.markTablesUpdated(db.allTables.toSet());
    });
  }
}
