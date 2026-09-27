const _table = [
  0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401, //
  0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
];

/// FIT CRC-16 (CRC-16/ARC) over `bytes[start, end)`, continuing from [crc].
int fitCrc(List<int> bytes, {int start = 0, int? end, int crc = 0}) {
  for (var i = start; i < (end ?? bytes.length); i++) {
    final b = bytes[i];
    var tmp = _table[crc & 0xF];
    crc = (crc >> 4) & 0x0FFF;
    crc ^= tmp ^ _table[b & 0xF];
    tmp = _table[crc & 0xF];
    crc = (crc >> 4) & 0x0FFF;
    crc ^= tmp ^ _table[(b >> 4) & 0xF];
  }
  return crc;
}
