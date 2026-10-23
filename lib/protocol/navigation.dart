/// Navigation (SID 0x08): turn-by-turn cards on the glasses' native Navigate screen.
/// Port of g2/apps/navigation.py (DECODED from the official app; untested live).
///
/// app → START (5), BASIC_INFO (7) per progress update, HEARTBEAT (0) every 5 s,
/// RECALCULATING (10) / ARRIVE (11) / STOP (12). glasses → NOTIFY_EXIT (13) or
/// END_SESSION_REQ (20) when the user leaves. Menu launch: glasses MENU_STARTUP (1) → app
/// LOCATION_LIST (2) or LOCATION_NONE (3) → glasses LOCATION_SELECTED (4).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'dashboard.dart' show decodeUtf8PrefixIgnore;
import 'limits.dart' as lim;
import 'pb.dart';
import 'pytext.dart';

const int sid = 0x08;

const int cmdHeartbeat = 0, cmdMenuStartup = 1, cmdLocationList = 2, cmdLocationNone = 3;
const int cmdLocationSelected = 4, cmdStart = 5, cmdErrorInfo = 6, cmdBasicInfo = 7, cmdMiniMap = 8;
const int cmdMaxMap = 9, cmdRecalculating = 10, cmdArrive = 11, cmdStop = 12, cmdNotifyExit = 13;
const int cmdViewChanged = 14, cmdCompassChanged = 15, cmdCompassCalibrateStart = 16;
const int cmdCompassCalibrateDone = 17, cmdSwitchTransportReq = 18, cmdSwitchTransportRsp = 19;
const int cmdEndSessionReq = 20;

const Map<int, String> cmdNames = {
  0: 'HEARTBEAT', 1: 'MENU_STARTUP', 2: 'LOCATION_LIST', 3: 'LOCATION_NONE', 4: 'LOCATION_SELECTED', //
  5: 'START', 6: 'ERROR_INFO', 7: 'BASIC_INFO', 8: 'MINI_MAP', 9: 'MAX_MAP', 10: 'RECALCULATING',
  11: 'ARRIVE', 12: 'STOP', 13: 'NOTIFY_EXIT', 14: 'VIEW_CHANGED', 15: 'COMPASS_CHANGED',
  16: 'COMPASS_CALIBRATE_START', 17: 'COMPASS_CALIBRATE_DONE', 18: 'SWITCH_TRANSPORT_REQ',
  19: 'SWITCH_TRANSPORT_RSP', 20: 'END_SESSION_REQ',
};

const int fExt = 3, fList = 4, fInfo = 5, fMiniMap = 6, fMaxMap = 7, fSelect = 8, fView = 9;
const int fCompass = 10, fTransportReq = 11, fTransportRsp = 12;

/// cmd -> (sub-message field, errorCode field inside it or null).
const Map<int, (int, int?)> _subForCmd = {
  cmdLocationList: (fList, 4),
  cmdBasicInfo: (fInfo, 9),
  cmdLocationSelected: (fSelect, 2),
  cmdMiniMap: (fMiniMap, 4),
  cmdMaxMap: (fMaxMap, 7),
  cmdViewChanged: (fView, null),
  cmdCompassChanged: (fCompass, null),
  cmdSwitchTransportReq: (fTransportReq, null),
  cmdSwitchTransportRsp: (fTransportRsp, null),
};

const int errSuccess = 0, errFail = 7;
const Map<int, String> errorNames = {
  0: 'SUCCESS', 1: 'CRC', 2: 'PKT_LOST', 3: 'TIMEOUT', 4: 'NO_RESOURCES', 5: 'PB_ERROR', 6: 'NULL', //
  7: 'FAIL', 8: 'NOT_SUPPORT', 9: 'SUPPORT', 10: 'HEAD_ID', 11: 'INVALID_LENGTH', 12: 'INVALID_SDID',
  13: 'DUPLICATE_PACKET', 90: 'RING_CONNECT_TIMEOUT',
};

const int methodWalking = 1, methodCycling = 2;
const Map<int, String> methodNames = {1: 'WALKING', 2: 'CYCLING'};

/// NavigateRoadSignType name → directionSignIndex (the arrow the glasses draw).
const Map<String, int> direction = {
  'DEPART': 1, 'STRAIGHT': 2, 'TURN_RIGHT': 3, 'TURN_LEFT': 4, 'TURN_SLIGHT_RIGHT': 5, //
  'TURN_SLIGHT_LEFT': 6, 'TURN_SHARP_RIGHT': 7, 'TURN_SHARP_LEFT': 8, 'UTURN_CLOCKWISE': 9,
  'UTURN_COUNTERCLOCKWISE': 10, 'ROUNDABOUT_SHARP_RIGHT_CW': 11, 'ROUNDABOUT_RIGHT_CCW': 12,
  'ROUNDABOUT_RIGHT_CW': 13, 'ROUNDABOUT_SLIGHT_RIGHT_CCW': 14, 'ROUNDABOUT_SLIGHT_RIGHT_CW': 15,
  'ROUNDABOUT_STRAIGHT_CCW': 16, 'ROUNDABOUT_STRAIGHT_CW': 17, 'ROUNDABOUT_SLIGHT_LEFT_CCW': 18,
  'ROUNDABOUT_SLIGHT_LEFT_CW': 19, 'ROUNDABOUT_LEFT_CCW': 20, 'ROUNDABOUT_LEFT_CW': 21,
  'ROUNDABOUT_SHARP_LEFT_CCW': 22, 'ROUNDABOUT_SHARP_LEFT_CW': 23, 'ROUNDABOUT_UTURN_CCW': 24,
  'ROUNDABOUT_UTURN_CW': 25, 'ROUNDABOUT_CCW': 26, 'ROUNDABOUT_CW': 27, 'ROUNDABOUT_EXIT_CCW': 28,
  'ROUNDABOUT_EXIT_CW': 29, 'MERGE_RIGHT': 30, 'MERGE_LEFT': 31, 'FORK_RIGHT': 32, 'FORK_LEFT': 33,
  'MERGE_UNSPECIFIED': 34, 'ROUNDABOUT_SHARP_RIGHT_CCW': 35,
};
const Map<String, String> directionAliases = {
  'RIGHT': 'TURN_RIGHT', 'LEFT': 'TURN_LEFT', 'SLIGHT_RIGHT': 'TURN_SLIGHT_RIGHT', //
  'SLIGHT_LEFT': 'TURN_SLIGHT_LEFT', 'UTURN': 'UTURN_COUNTERCLOCKWISE',
};

const int textMaxBytes = 60;
const String missing = '--';
const Duration heartbeatInterval = Duration(seconds: 5);
const Duration heartbeatGiveUp = Duration(seconds: 30);

Uint8List buildPackage(int cmd, int magic, int field, List<int> inner) =>
    cat([encodeVarintField(1, cmd), encodeVarintField(2, magic), encodeMessageField(field, inner)]);

/// ≤limit UTF-8 bytes without splitting a character; null/blank → "--". Returns bytes.
Uint8List truncateUtf8(Object? text, [int limit = textMaxBytes]) {
  if (text == null || pyStrip(text.toString()).isEmpty) return Uint8List.fromList(utf8.encode(missing));
  final b = utf8.encode(text.toString());
  final cut = b.length > limit ? b.sublist(0, limit) : b;
  return Uint8List.fromList(utf8.encode(decodeUtf8PrefixIgnore(cut)));
}

Uint8List _simple(int cmd, int magic) => buildPackage(cmd, magic, fExt, Uint8List(0));
Uint8List buildStart(int magic) => _simple(cmdStart, magic);
Uint8List buildHeartbeat(int magic) => _simple(cmdHeartbeat, magic);
Uint8List buildRecalculating(int magic) => _simple(cmdRecalculating, magic);
Uint8List buildArrive(int magic) => _simple(cmdArrive, magic);
Uint8List buildStop(int magic) => _simple(cmdStop, magic);
Uint8List buildLocationNone(int magic) => _simple(cmdLocationNone, magic);

Uint8List buildErrorInfo(int magic, String message, {int index = 0, int error = errFail}) => buildPackage(
    cmdErrorInfo,
    magic,
    fExt,
    cat([encodeVarintField(1, error), encodeBytesField(2, truncateUtf8(message)), if (index != 0) encodeVarintField(3, index)]));

/// A directionSignIndex (int) or a name ('TURN_RIGHT', 'turn right', 'left', ...). Throws on unknown.
int directionIndex(Object direction_) {
  if (direction_ is int) return direction_;
  final key = pyStrip(direction_.toString()).toUpperCase().replaceAll(' ', '_').replaceAll('-', '_');
  final v = direction[directionAliases[key] ?? key];
  if (v == null) throw ArgumentError('unknown direction $direction_');
  return v;
}

/// BASIC_INFO (cmd 7) {5:{1 dir, 2 distance, 3 road, 4 spendTime, 5 remainDistance, 6 eta,
/// 7 speed, 8 method, 10 counter}}. eta gets an "ETA: " prefix unless it already has one.
Uint8List buildBasicInfo(int magic, Object dir,
    {String? distance,
    String? road,
    String? remainingTime,
    String? remainingDistance,
    String? eta,
    String? speed,
    int method = methodWalking,
    int counter = 0}) {
  var e = eta;
  if (e != null && pyStrip(e).isNotEmpty && !e.startsWith('ETA')) e = 'ETA: $e';
  final p = Pb().varint(1, directionIndex(dir));
  final texts = [(2, distance), (3, road), (4, remainingTime), (5, remainingDistance), (6, e), (7, speed)];
  for (final (field, text) in texts) {
    p.bytes(field, truncateUtf8(text));
  }
  if (method != 0) p.varint(8, method);
  if (counter != 0) p.varint(10, counter);
  return buildPackage(cmdBasicInfo, magic, fInfo, p.toBytes());
}

/// LOCATION_LIST (cmd 2) {4:{1 n, 2 names[], 3 packed icons}}: favorites for a menu launch.
Uint8List buildLocationList(int magic, List<String> names, [List<int>? icons]) {
  lim.checkCount('Navigation LocationList names', names.length, lim.navLocationMaxNames);
  if (icons != null && icons.isNotEmpty) {
    lim.checkCount('Navigation LocationList icons', icons.length, lim.navLocationMaxNames);
  }
  final p = Pb().varint(1, names.length);
  for (final n in names) {
    p.bytes(2, truncateUtf8(n));
  }
  if (icons != null && icons.isNotEmpty) p.bytes(3, cat([for (final i in icons) encodeVarint(i)]));
  return buildPackage(cmdLocationList, magic, fList, p.toBytes());
}

Uint8List buildSwitchTransportResponse(int magic, [int status = 0]) =>
    buildPackage(cmdSwitchTransportRsp, magic, fTransportRsp, status != 0 ? encodeVarintField(1, status) : Uint8List(0));

String _repr(String s) {
  final useDouble = s.contains("'") && !s.contains('"');
  final q = useDouble ? '"' : "'";
  final b = StringBuffer(q);
  for (final c in s.runes) {
    if (c == 0x5C) {
      b.write(r'\\');
    } else if (String.fromCharCode(c) == q) {
      b.write('\\$q');
    } else if (c == 0x0A) {
      b.write(r'\n');
    } else if (c == 0x0D) {
      b.write(r'\r');
    } else if (c == 0x09) {
      b.write(r'\t');
    } else if (c < 0x20 || c == 0x7F) {
      b.write('\\x${c.toRadixString(16).padLeft(2, '0')}');
    } else {
      b.writeCharCode(c);
    }
  }
  b.write(q);
  return b.toString();
}

/// Decode a navigation message: {cmd, name, magic, value, location, method, error, label}.
Map<String, Object?> decode(List<int> pb) {
  final cmd = readVarintField(pb, 1, 0);
  final magic = readVarintField(pb, 2, -1);
  final name = cmdNames[cmd] ?? 'cmd=$cmd';
  final out = <String, Object?>{
    'cmd': cmd, 'name': name, 'magic': magic, 'value': null, 'location': null, 'method': null, 'error': null, //
  };
  var label = name;
  final (field, errField) = _subForCmd[cmd] ?? (fExt, 1);
  final sub = readBytesField(pb, field);
  if (sub != null) {
    if (cmd == cmdLocationSelected) {
      out['location'] = readStringField(sub, 1, '');
      out['value'] = readVarintField(sub, 3, 0);
      out['method'] = readVarintField(sub, 4, 0);
      label += ' #${out['value']} ${_repr(out['location'] as String)} ${methodNames[out['method']] ?? out['method']}';
    } else if (cmd == cmdViewChanged || cmd == cmdCompassChanged) {
      out['value'] = readVarintField(sub, 1, 0);
      label += ' ${out['value']}';
    } else if (cmd == cmdSwitchTransportReq) {
      out['method'] = readVarintField(sub, 1, 0);
      label += ' ${methodNames[out['method']] ?? out['method']}';
    }
    if (errField != null) {
      out['error'] = readVarintField(sub, errField, 0);
      final e = out['error'] as int;
      if (e != 0) label += ' errorCode=${errorNames[e] ?? e}';
    }
  }
  out['label'] = label;
  return out;
}

/// True when the glasses left navigation (cmd 13 or 20).
bool isExit(Map<String, Object?> msg) => msg['cmd'] == cmdNotifyExit || msg['cmd'] == cmdEndSessionReq;
