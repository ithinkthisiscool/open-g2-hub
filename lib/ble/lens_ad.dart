/// Lens advertisement parsing (port of g2.transport.ble.parse_name / parse_manufacturer) and
/// the GATT UUIDs. Pure Dart.
///
/// Each lens is its own BLE peripheral named like "Even G2_42_L_ABCDEF" (pair id 42, side L/R,
/// last 3 bytes of its address), with manufacturer data (company 0x5245 "RE") carrying the pair
/// SERIAL (same on both lenses), the lens MAC (little-endian) and one flag byte. A lens stops
/// advertising while any phone/PC holds a connection to it.
library;

const String uuidBase = '00002760-08c2-11e1-9073-0e8ac72e';
String g2Uuid(int short) => '$uuidBase${short.toRadixString(16).padLeft(4, '0')}';

/// Control service and characteristics (LIVE-CONFIRMED).
final String serviceControl = g2Uuid(0x5450);
final String charWrite = g2Uuid(0x5401); // write without response: control frames
final String charNotify = g2Uuid(0x5402); // notify: replies, acks, device events
final String charAppHello = g2Uuid(0x5403); // the official app writes 00 here (purpose unknown)

/// Microphone (raw LC3, no frame header).
final String serviceAudio = g2Uuid(0x6450);
final String charAudioNotify = g2Uuid(0x6402);

/// EvenFile service (SIDs 0xC4-0xC7).
final String serviceFile = g2Uuid(0x7450);
final String charFileWrite = g2Uuid(0x7401);
final String charFileNotify = g2Uuid(0x7402);

const int manufacturerId = 0x5245;
final RegExp nameRe = RegExp(r'G2_(\w+?)_([LR])_([0-9A-Fa-f]{6})');

enum LensSide { left, right }

class LensName {
  LensName(this.pairId, this.side, this.macTail);
  final String pairId;
  final LensSide side;
  final String macTail;
  Map<String, Object?> toJson() => {'pair_id': pairId, 'side': side == LensSide.right ? 'right' : 'left', 'mac_tail': macTail};
}

/// "Even G2_42_L_ABCDEF" -> pair 42, left, ABCDEF; null for anything else.
LensName? parseName(String? name) {
  final m = nameRe.firstMatch(name ?? '');
  if (m == null) return null;
  return LensName(m.group(1)!, m.group(2) == 'R' ? LensSide.right : LensSide.left, m.group(3)!.toUpperCase());
}

class LensManufacturer {
  LensManufacturer(this.serial, this.mac, this.flag);
  final String serial;
  final String mac;
  final int flag;
  Map<String, Object?> toJson() => {'serial': serial, 'mac': mac, 'flag': flag};
}

/// 0x5245 payload: `<serial ascii> <6-byte MAC little-endian> <flag>`. Null if < 8 bytes.
LensManufacturer? parseManufacturer(List<int>? data) {
  final d = data ?? const <int>[];
  if (d.length < 8) return null;
  final serialBytes = d.sublist(0, d.length - 7);
  final serial = String.fromCharCodes(serialBytes.map((c) => c < 0x80 ? c : 0xFFFD));
  final mac = d.sublist(d.length - 7, d.length - 1).reversed.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');
  return LensManufacturer(serial, mac, d.last);
}
