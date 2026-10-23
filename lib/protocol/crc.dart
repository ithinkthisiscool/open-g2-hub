/// Checksums used on the G2 link (ports of g2.transport.transport.crc16_ccitt,
/// g2.widgets.evenhub.crc16_ccitt and g2.transport.file_service.crc32_efs).
library;

import 'dart:typed_data';

/// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection, no final XOR) as an int.
int crc16Ccitt(List<int> data, [int init = 0xFFFF]) {
  var crc = init;
  for (final byte in data) {
    crc ^= (byte & 0xFF) << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

/// The same CRC as the two wire bytes, little-endian (low byte first).
Uint8List crc16Bytes(List<int> data) {
  final c = crc16Ccitt(data);
  return Uint8List.fromList([c & 0xFF, (c >> 8) & 0xFF]);
}

final List<int> _crc32Table = () {
  final t = <int>[];
  for (var i = 0; i < 256; i++) {
    var c = i << 24;
    for (var k = 0; k < 8; k++) {
      c = (c & 0x80000000) != 0 ? ((c << 1) ^ 0x1EDC6F41) & 0xFFFFFFFF : (c << 1) & 0xFFFFFFFF;
    }
    t.add(c);
  }
  return t;
}();

/// CRC32' used by the EvenFile service: poly 0x1EDC6F41, MSB-first, init 0, no final XOR.
/// Check value for "123456789" is 0xC052A8C8.
int crc32Efs(List<int> data) {
  var crc = 0;
  for (final b in data) {
    crc = ((crc << 8) & 0xFFFFFFFF) ^ _crc32Table[((crc >> 24) ^ b) & 0xFF];
  }
  return crc;
}
