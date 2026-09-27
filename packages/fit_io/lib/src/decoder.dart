import 'dart:convert';
import 'dart:typed_data';

import 'base_type.dart';
import 'crc.dart';
import 'profile.dart';

enum CrcCheck { ignore, warn, strict }

class FitFormatException implements Exception {
  const FitFormatException(this.message, [this.offset]);

  final String message;
  final int? offset;

  @override
  String toString() =>
      'FitFormatException: $message${offset == null ? '' : ' (at byte $offset)'}';
}

class FitHeader {
  const FitHeader({
    required this.headerSize,
    required this.protocolVersion,
    required this.profileVersion,
    required this.dataSize,
  });

  final int headerSize;
  final int protocolVersion;
  final int profileVersion;
  final int dataSize;
}

/// A decoded data message. Invalid values are omitted from [fields];
/// multi-value fields are lists, strings are [String], unknown types raw bytes.
class FitMessage {
  FitMessage(this.globalNum, this.fields);

  final int globalNum;
  final Map<int, Object?> fields;

  Object? operator [](int field) => fields[field];

  int? intValue(int field) => switch (fields[field]) {
        final int v => v,
        [final int v, ...] => v,
        _ => null,
      };

  num? numValue(int field) => switch (fields[field]) {
        final num v => v,
        [final num v, ...] => v,
        _ => null,
      };

  String? stringValue(int field) => switch (fields[field]) {
        final String v => v,
        _ => null,
      };

  int? get timestamp => intValue(FitCommonField.timestamp);
}

class FitFile {
  const FitFile(this.header, this.messages, this.warnings);

  final FitHeader header;
  final List<FitMessage> messages;

  /// Non-fatal problems (CRC mismatches in [CrcCheck.warn] mode, truncation).
  final List<String> warnings;

  Iterable<FitMessage> byNum(int globalNum) =>
      messages.where((m) => m.globalNum == globalNum);
}

class _FieldDef {
  const _FieldDef(this.num, this.size, this.type);
  final int num;
  final int size;
  final FitBaseType? type;
}

class _Definition {
  _Definition(this.globalNum, this.endian, this.fields, this.devSize)
      : size = fields.fold(devSize, (s, f) => s + f.size);

  final int globalNum;
  final Endian endian;
  final List<_FieldDef> fields;
  final int devSize;
  final int size;
}

class FitDecoder {
  const FitDecoder({this.crcCheck = CrcCheck.warn});

  final CrcCheck crcCheck;

  FitFile decode(Uint8List bytes) {
    final warnings = <String>[];
    void crcProblem(String message) {
      switch (crcCheck) {
        case CrcCheck.strict:
          throw FitFormatException(message);
        case CrcCheck.warn:
          warnings.add(message);
        case CrcCheck.ignore:
      }
    }

    if (bytes.length < 12) {
      throw const FitFormatException('Too short for a FIT header');
    }
    final headerSize = bytes[0];
    if (headerSize < 12 || headerSize > bytes.length) {
      throw FitFormatException('Invalid header size $headerSize', 0);
    }
    if (ascii.decode(bytes.sublist(8, 12), allowInvalid: true) != '.FIT') {
      throw const FitFormatException('Missing ".FIT" signature', 8);
    }
    final data = ByteData.sublistView(bytes);
    final header = FitHeader(
      headerSize: headerSize,
      protocolVersion: bytes[1],
      profileVersion: data.getUint16(2, Endian.little),
      dataSize: data.getUint32(4, Endian.little),
    );
    if (headerSize >= 14) {
      final stored = data.getUint16(12, Endian.little);
      if (stored != 0 && stored != fitCrc(bytes, end: 12)) {
        crcProblem('Header CRC mismatch');
      }
    }

    var end = headerSize + header.dataSize;
    if (end > bytes.length) {
      warnings.add('Truncated file: ${end - bytes.length} data bytes missing');
      end = bytes.length;
    } else if (end + 2 > bytes.length) {
      crcProblem('Missing file CRC');
    } else if (data.getUint16(end, Endian.little) != fitCrc(bytes, end: end)) {
      crcProblem('File CRC mismatch');
    }

    final messages = <FitMessage>[];
    final definitions = <int, _Definition>{};
    int? lastTimestamp;
    var pos = headerSize;

    while (pos < end) {
      final recordStart = pos;
      final h = bytes[pos++];
      final compressed = (h & 0x80) != 0;

      if (!compressed && (h & 0x40) != 0) {
        if (pos + 5 > end) break;
        final endian = bytes[pos + 1] == 0 ? Endian.little : Endian.big;
        final globalNum = data.getUint16(pos + 2, endian);
        final count = bytes[pos + 4];
        pos += 5;
        if (pos + count * 3 > end) break;
        final fields = [
          for (var i = 0; i < count; i++)
            _FieldDef(bytes[pos + i * 3], bytes[pos + i * 3 + 1],
                FitBaseType.fromId(bytes[pos + i * 3 + 2])),
        ];
        pos += count * 3;
        var devSize = 0;
        if ((h & 0x20) != 0) {
          if (pos >= end) break;
          final devCount = bytes[pos++];
          if (pos + devCount * 3 > end) break;
          for (var i = 0; i < devCount; i++) {
            devSize += bytes[pos + i * 3 + 1];
          }
          pos += devCount * 3;
        }
        definitions[h & 0x0F] = _Definition(globalNum, endian, fields, devSize);
        continue;
      }

      final local = compressed ? (h >> 5) & 0x03 : h & 0x0F;
      final def = definitions[local] ??
          (throw FitFormatException(
              'Data message for undefined local type $local', recordStart));
      if (pos + def.size > end) break;

      final fields = <int, Object?>{};
      for (final f in def.fields) {
        final value = _value(bytes, data, pos, f, def.endian);
        if (value != null) fields[f.num] = value;
        pos += f.size;
      }
      pos += def.devSize;

      if (compressed) {
        if (lastTimestamp == null) {
          warnings
              .add('Compressed timestamp without reference at $recordStart');
        } else {
          final offset = h & 0x1F;
          var ts = (lastTimestamp & ~0x1F) + offset;
          if (offset < (lastTimestamp & 0x1F)) ts += 0x20;
          fields[FitCommonField.timestamp] = ts;
        }
      }
      final ts = fields[FitCommonField.timestamp];
      if (ts is int) lastTimestamp = ts;
      messages.add(FitMessage(def.globalNum, fields));
    }
    if (pos < end) warnings.add('Truncated record at byte $pos');

    return FitFile(header, messages, warnings);
  }

  static Object? _value(
      Uint8List bytes, ByteData data, int offset, _FieldDef f, Endian endian) {
    final type = f.type;
    if (type == null || f.size % type.size != 0) {
      return Uint8List.sublistView(bytes, offset, offset + f.size);
    }
    if (type == FitBaseType.string) {
      var len = 0;
      while (len < f.size && bytes[offset + len] != 0) {
        len++;
      }
      return len == 0
          ? null
          : utf8.decode(bytes.sublist(offset, offset + len),
              allowMalformed: true);
    }
    final count = f.size ~/ type.size;
    if (count == 1) return type.read(data, offset, endian);
    final list = [
      for (var i = 0; i < count; i++)
        type.read(data, offset + i * type.size, endian),
    ];
    return list.every((v) => v == null) ? null : list;
  }
}
