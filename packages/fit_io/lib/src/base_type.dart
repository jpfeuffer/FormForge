import 'dart:typed_data';

/// FIT base types with their wire size and invalid (“no value”) bit pattern.
enum FitBaseType {
  enumType(0x00, 1, 0xFF),
  sint8(0x01, 1, 0x7F),
  uint8(0x02, 1, 0xFF),
  sint16(0x83, 2, 0x7FFF),
  uint16(0x84, 2, 0xFFFF),
  sint32(0x85, 4, 0x7FFFFFFF),
  uint32(0x86, 4, 0xFFFFFFFF),
  string(0x07, 1, 0x00),
  float32(0x88, 4, 0xFFFFFFFF),
  float64(0x89, 8, -1),
  uint8z(0x0A, 1, 0x00),
  uint16z(0x8B, 2, 0x00),
  uint32z(0x8C, 4, 0x00),
  byte(0x0D, 1, 0xFF),
  sint64(0x8E, 8, 0x7FFFFFFFFFFFFFFF),
  uint64(0x8F, 8, -1),
  uint64z(0x90, 8, 0x00);

  const FitBaseType(this.id, this.size, this.invalid);

  /// Base type field byte as written in definition messages.
  final int id;
  final int size;

  /// Raw unsigned bit pattern; 64-bit all-ones is `-1` in Dart's int.
  final int invalid;

  /// Resolves the low 5 bits (base type number); the endian flag is ignored.
  static FitBaseType? fromId(int id) {
    for (final t in values) {
      if (t.id & 0x1F == id & 0x1F) return t;
    }
    return null;
  }

  /// Reads one value at [offset]; returns `null` for the invalid pattern.
  Object? read(ByteData data, int offset, Endian endian) {
    final raw = switch (size) {
      1 => data.getUint8(offset),
      2 => data.getUint16(offset, endian),
      4 => data.getUint32(offset, endian),
      _ => data.getUint64(offset, endian),
    };
    if (raw == invalid) return null;
    return switch (this) {
      FitBaseType.sint8 => data.getInt8(offset),
      FitBaseType.sint16 => data.getInt16(offset, endian),
      FitBaseType.sint32 => data.getInt32(offset, endian),
      FitBaseType.sint64 => data.getInt64(offset, endian),
      FitBaseType.float32 => data.getFloat32(offset, endian),
      FitBaseType.float64 => data.getFloat64(offset, endian),
      _ => raw,
    };
  }

  /// Writes [value] at [offset]; `null` writes the invalid pattern.
  void write(ByteData data, int offset, Object? value, Endian endian) {
    if (value != null && this == FitBaseType.float32) {
      return data.setFloat32(offset, (value as num).toDouble(), endian);
    }
    if (value != null && this == FitBaseType.float64) {
      return data.setFloat64(offset, (value as num).toDouble(), endian);
    }
    final raw = value == null ? invalid : (value as num).round();
    switch (size) {
      case 1:
        data.setUint8(offset, raw & 0xFF);
      case 2:
        data.setUint16(offset, raw & 0xFFFF, endian);
      case 4:
        data.setUint32(offset, raw & 0xFFFFFFFF, endian);
      default:
        data.setInt64(offset, raw, endian);
    }
  }
}
