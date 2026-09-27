import 'dart:convert';
import 'dart:typed_data';

import 'base_type.dart';
import 'crc.dart';

/// One field value to encode. `null` values are left out of the message.
class FitField {
  const FitField(this.num, this.type, this.value, {this.size});

  final int num;
  final FitBaseType type;

  /// `num`, `List<num>` or (for [FitBaseType.string]) `String`.
  final Object? value;

  /// Fixed byte size; defaults to the value's natural size (strings incl. NUL).
  final int? size;

  int get byteSize {
    final natural = switch (value) {
      final String s => utf8.encode(s).length + 1,
      final List<Object?> l => l.length * type.size,
      _ => type.size,
    };
    return (size ?? natural).clamp(type.size, 255 - 255 % type.size);
  }
}

/// Low-level FIT encoder: emits definitions on demand, header and CRCs.
class FitWriter {
  FitWriter({this.endian = Endian.little, this.profileVersion = 2140});

  final Endian endian;
  final int profileVersion;

  final _body = BytesBuilder(copy: false);
  final _definitions = <int, String>{};

  void write(int globalNum, List<FitField> fields, {int localNum = 0}) {
    final present = [
      for (final f in fields)
        if (f.value != null) (field: f, size: f.byteSize),
    ];
    final signature = [
      globalNum,
      for (final p in present) '${p.field.num}:${p.size}:${p.field.type.id}',
    ].join(',');
    if (_definitions[localNum] != signature) {
      _definitions[localNum] = signature;
      final def = ByteData(6 + present.length * 3)
        ..setUint8(0, 0x40 | (localNum & 0x0F))
        ..setUint8(2, endian == Endian.little ? 0 : 1)
        ..setUint16(3, globalNum, endian)
        ..setUint8(5, present.length);
      for (final (i, p) in present.indexed) {
        def
          ..setUint8(6 + i * 3, p.field.num)
          ..setUint8(7 + i * 3, p.size)
          ..setUint8(8 + i * 3, p.field.type.id);
      }
      _body.add(def.buffer.asUint8List());
    }

    final total = present.fold(1, (s, p) => s + p.size);
    final msg = ByteData(total)..setUint8(0, localNum & 0x0F);
    var offset = 1;
    for (final (:field, :size) in present) {
      switch (field.value) {
        case final String s:
          final encoded = utf8.encode(s);
          final n = encoded.length < size ? encoded.length : size - 1;
          for (var i = 0; i < n; i++) {
            msg.setUint8(offset + i, encoded[i]);
          }
        case final List<Object?> values:
          for (var i = 0; i < size ~/ field.type.size; i++) {
            field.type.write(msg, offset + i * field.type.size,
                i < values.length ? values[i] : null, endian);
          }
        case final value:
          field.type.write(msg, offset, value, endian);
      }
      offset += size;
    }
    _body.add(msg.buffer.asUint8List());
  }

  /// Returns the complete file (14-byte header, data, file CRC).
  Uint8List finish() {
    final body = _body.takeBytes();
    final out = Uint8List(14 + body.length + 2);
    final data = ByteData.sublistView(out)
      ..setUint8(0, 14)
      ..setUint8(1, 0x10)
      ..setUint16(2, profileVersion, Endian.little)
      ..setUint32(4, body.length, Endian.little);
    out.setRange(8, 12, ascii.encode('.FIT'));
    data.setUint16(12, fitCrc(out, end: 12), Endian.little);
    out.setRange(14, 14 + body.length, body);
    data.setUint16(
        out.length - 2, fitCrc(out, end: out.length - 2), Endian.little);
    _definitions.clear();
    return out;
  }
}
