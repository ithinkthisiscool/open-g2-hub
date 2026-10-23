/// Device config (SID 0x80: auth, role, time sync, keep-alive), onboarding (SID 0x10) and
/// case (SID 0x81), plus the official app's connect sequence. Port of g2/device/device.py.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'pb.dart';
import 'settings.dart' as st;

const int sid = 0x80;
const int sidOnboarding = 0x10;
const int sidCase = 0x81;
const int flagRequest = 0x20;
const int flagPlain = 0x00;

const int cmdAuth = 4,
    cmdRoleChange = 5,
    cmdRingConnectInfo = 6,
    cmdBleConnectParam = 7,
    cmdDisconnect = 8,
    cmdUnpair = 9,
    cmdException = 10,
    cmdSetDeviceInfo = 11,
    cmdGetDeviceInfo = 12,
    cmdFactoryReset = 13,
    cmdKeepalive = 14,
    cmdQuickRestart = 15,
    cmdTimeSync = 128,
    cmdAudControl = 129,
    cmdError = 255;

const Map<int, String> cmdNames = {
  4: 'AUTHENTICATION',
  5: 'PIPE_ROLE_CHANGE',
  6: 'RING_CONNECT_INFO',
  7: 'BLE_CONNECT_PARAM',
  8: 'DISCONNECT_INFO',
  9: 'UNPAIR_INFO',
  10: 'COMMAND_EXCEPTION',
  11: 'SET_DEVICE_INFO',
  12: 'GET_DEVICE_INFO',
  13: 'RESTORE_TO_FACTORY_SETTINGS',
  14: 'BASE_CONNECT_HEART_BEAT',
  15: 'QUICK_RESTART',
  128: 'TIME_SYNC',
  129: 'AUD_CONTROL',
  255: 'COMMAND_ERROR',
};

const Map<int, int> fieldForCmd = {
  4: 3, 5: 4, 6: 5, 7: 6, 8: 7, 9: 8, 10: 9, 11: 10, 12: 11, 13: 12, 14: 13, 15: 14, 128: 128, 129: 129, //
};
const Map<int, int> _resultField = {
  4: 3, 5: 2, 6: 5, 7: 5, 8: 3, 9: 3, 10: 2, 11: 2, 12: 2, 13: 1, 14: 1, 15: 1, 128: 3, 129: 3, //
};

const int roleBoth = 0, roleRight = 1, roleLeft = 2;
const Map<int, String> roleNames = {0: 'BOTH', 1: 'RIGHT', 2: 'LEFT'};

const int devRing = 0, devGlasses = 1, devRingGlasses = 2, devPhoneIos = 3, devPhoneAndroid = 4;

const Map<int, String> infoNames = {
  0: 'ALL_INFO',
  1: 'DEVICE_BRIGHTNESS',
  2: 'DEVICE_ANTI_SHAKE_ENABLE',
  3: 'DEVICE_DISPLAY_MODE',
  4: 'DEVICE_WORK_MODE',
  5: 'DEVICE_WAKEUP_ANGLE',
  6: 'DEVICE_GLASSES_SN',
  7: 'DEVICE_DEVICE_SN',
  8: 'DEVICE_BLE_MAC',
};

const Map<int, String> errorNames = {
  0: 'SUCCESS', 1: 'CRC', 2: 'PKT_LOST', 3: 'TIMEOUT', 4: 'NO_RESOURCES', 5: 'PB_ERROR', 6: 'NULL', 7: 'FAIL',
  8: 'NOT_SUPPORT', 9: 'SUPPORT', 10: 'HEAD_ID', 11: 'INVALID_LENGTH', 12: 'INVALID_SDID', 13: 'DUPLICATE_PACKET',
  90: 'RING_CONNECT_TIMEOUT', //
};

const Duration keepaliveInterval = Duration(seconds: 60);
const Duration keepaliveLeftLead = Duration(seconds: 2);
const int tzUnitMinutes = 15;
const int tzMin = -128, tzMax = 127;

const int obCmdConfig = 1, obCmdHeartbeat = 2, obCmdEvent = 3;
const Map<int, String> obCmdNames = {1: 'CONFIG', 2: 'HEARTBEAT', 3: 'EVENT'};
const int obStartUp = 1, obTouch = 2, obHeadUp = 3, obFinish = 4;
const Map<int, String> obProcessNames = {1: 'START_UP', 2: 'TOUCH', 3: 'HEAD_UP', 4: 'FINISH'};
const int obEventWearStatus = 1;
const int caseCmdInfo = 1;

/// Frame flag the official app uses: 0x00 for 0x80 auth/keep-alive, 0x20 otherwise.
int flagFor(int sidValue, List<int> pb) {
  if (sidValue == sid) {
    final c = readVarintField(pb, 1, -1);
    if (c == cmdAuth || c == cmdKeepalive) return flagPlain;
  }
  return flagRequest;
}

Uint8List buildPackage(int cmd, int magic, List<int> inner) =>
    cat([encodeVarintField(1, cmd), encodeVarintField(2, magic), encodeMessageField(fieldForCmd[cmd]!, inner)]);

Uint8List buildAuth(int magic, [int phoneType = devPhoneAndroid]) =>
    buildPackage(cmdAuth, magic, cat([encodeVarintField(1, 1), encodeVarintField(2, phoneType)]));

Uint8List buildRoleChange(int magic, [int role = roleRight]) {
  if (!roleNames.containsKey(role)) throw G2ValueError('role must be one of [0, 1, 2], got $role');
  return buildPackage(cmdRoleChange, magic, encodeVarintField(1, role));
}

/// UTC offset in seconds -> 15-minute units, truncated toward zero, clamped to -128..127.
int tzUnitsFromOffset(int offsetSeconds) {
  final q = (offsetSeconds / (tzUnitMinutes * 60)).truncate();
  return q < tzMin ? tzMin : (q > tzMax ? tzMax : q);
}

int localTzUnits([int? now]) {
  final t = now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return tzUnitsFromOffset(DateTime.fromMillisecondsSinceEpoch(t * 1000).timeZoneOffset.inSeconds);
}

/// 0x80 cmd 128 TimeSync{1 unix seconds, 2 timezone (int32, 15-min units)}. CAPTURED.
Uint8List buildTimeSync(int magic, {int? now, int? tzUnits}) {
  final secs = now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if (secs < 0 || secs > 0xFFFFFFFF) throw G2ValueError('unix seconds out of uint32 range: $secs');
  final tz = tzUnits ?? localTzUnits(secs);
  if (tz < tzMin || tz > tzMax) throw G2ValueError('tz_units must be in $tzMin..$tzMax, got $tz');
  final inner = cat([encodeVarintField(1, secs), encodeKey(2, 0), encodeVarint(tz)]);
  return buildPackage(cmdTimeSync, magic, inner);
}

/// 0x80 cmd 14 {13: {}}: every 60 s to BOTH lenses (left first), flag 0x00. CAPTURED.
Uint8List buildKeepalive(int magic) => buildPackage(cmdKeepalive, magic, Uint8List(0));

/// DISRUPTIVE: reboots the glasses.
Uint8List buildQuickRestart(int magic) => buildPackage(cmdQuickRestart, magic, Uint8List(0));

/// DESTRUCTIVE: wipes settings and bonds. Only behind explicit user confirmation.
Uint8List buildFactoryReset(int magic) => buildPackage(cmdFactoryReset, magic, Uint8List(0));

Uint8List buildGetDeviceInfo(int magic, [int item = 0]) {
  if (!infoNames.containsKey(item)) throw G2ValueError('item must be one of 0..8, got $item');
  return buildPackage(cmdGetDeviceInfo, magic, encodeMessageField(1, encodeVarintField(1, item)));
}

Uint8List buildOnboardingConfig(int magic, [int processId = obFinish]) {
  if (!obProcessNames.containsKey(processId)) throw G2ValueError('process_id must be one of [1, 2, 3, 4], got $processId');
  return cat([encodeVarintField(1, obCmdConfig), encodeVarintField(2, magic), encodeMessageField(3, encodeVarintField(1, processId))]);
}

Uint8List buildOnboardingFinish(int magic) => buildOnboardingConfig(magic, obFinish);

Uint8List buildWearStatusQuery(int magic) => cat([
      encodeVarintField(1, obCmdEvent),
      encodeVarintField(2, magic),
      encodeMessageField(5, encodeVarintField(1, obEventWearStatus)),
    ]);

Uint8List buildCaseInfoQuery(int magic) =>
    cat([encodeVarintField(1, caseCmdInfo), encodeVarintField(2, magic), encodeMessageField(3, Uint8List(0))]);

Uint8List _fixed(int cmd, int magic, List<int> tail) => cat([encodeVarintField(1, cmd), encodeVarintField(2, magic), tail]);

enum Lens { right, left, both }

/// One step of a send sequence.
class Step {
  Step(this.sid, this.payload, this.lens);
  final int sid;
  final Uint8List payload;
  final Lens lens;
}

/// The ordered post-auth housekeeping the official app sends (CAPTURED). [magicFn] returns
/// the next magic. full=true also inserts the other fixed-payload steps at their positions.
List<Step> connectSequence(int Function() magicFn, {int? now, int? tzUnits, bool full = false}) {
  final seq = <Step>[];
  void add(int s, Uint8List Function(int) build) => seq.add(Step(s, build(magicFn()), Lens.right));

  add(sid, buildRoleChange);
  add(sid, (m) => buildTimeSync(m, now: now, tzUnits: tzUnits));
  if (full) {
    add(0x07, (m) => _fixed(10, m, encodeMessageField(13, cat([encodeVarintField(1, 0), encodeVarintField(2, 80), encodeVarintField(4, 0)]))));
    add(0x0C, (m) => _fixed(2, m, encodeMessageField(4, cat([encodeVarintField(1, 1), encodeVarintField(2, 0)]))));
    add(0x0D, (m) => _fixed(0, m, Uint8List(0)));
  }
  add(st.sidSettings, (m) => st.buildReadSettings(m));
  add(st.sidSettings, (m) => st.buildUnits(m));
  add(sidOnboarding, buildOnboardingFinish);
  add(sidOnboarding, buildWearStatusQuery);
  if (full) {
    add(0x1F, (m) => _fixed(0, m, encodeMessageField(3, encodeVarintField(1, 1))));
  }
  add(sidCase, buildCaseInfoQuery);
  if (full) {
    add(0x04, (m) => _fixed(1, m, encodeMessageField(3, cat([encodeVarintField(1, 1), encodeVarintField(2, 0), encodeVarintField(3, 5), encodeVarintField(5, 0)]))));
  }
  add(st.sidSettings, (m) => st.buildGestures(m));
  return seq;
}

/// One keep-alive round: left first, then right, each with its own magic.
List<Step> keepaliveSteps(int Function() magicFn) => [
      Step(sid, buildKeepalive(magicFn()), Lens.left),
      Step(sid, buildKeepalive(magicFn()), Lens.right),
    ];

List<Map<String, Object?>> _decodeDeviceInfo(List<int> sub) {
  final items = <Map<String, Object?>>[];
  for (final f in iterFields(sub)) {
    if (f.number != 1 || f.wire != 2) continue;
    final v = f.asBytes;
    final itemId = readVarintField(v, 1, 0);
    final item = <String, Object?>{'item': itemId, 'name': infoNames[itemId] ?? itemId};
    final als = readBytesField(v, 2);
    if (als != null) {
      item['als_brightness'] = readVarintField(als, 1, 0);
      item['als_auto'] = readVarintField(als, 2, 0);
    }
    if (readVarintField(v, 3, -1) >= 0) item['anti_shake'] = readVarintField(v, 3, 0);
    for (final (fld, key) in [(4, 'display_mode'), (5, 'wake_mode')]) {
      final m = readBytesField(v, fld);
      if (m != null) item[key] = readVarintField(m, 1, 0);
    }
    final ang = readBytesField(v, 6);
    if (ang != null) {
      item['wakeup_angle'] = readVarintField(ang, 1, 0);
      item['wakeup_offset'] = readVarintField(ang, 2, 0);
    }
    for (final (fld, key) in [(7, 'glasses_sn'), (8, 'device_sn')]) {
      final m = readBytesField(v, fld);
      if (m != null) {
        final raw = readBytesField(m, 1) ?? Uint8List(0);
        item[key] = utf8.decode(raw, allowMalformed: true);
      }
    }
    final mac = readBytesField(v, 9);
    if (mac != null) {
      final raw = readBytesField(mac, 1) ?? Uint8List(0);
      item['ble_mac'] = raw.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');
    }
    items.add(item);
  }
  return items;
}

/// Decode a SID 0x80 message: {cmd, name, magic, result, label, ...}.
Map<String, Object?> decode(List<int> pb) {
  final cmd = readVarintField(pb, 1, -1);
  final magic = readVarintField(pb, 2, -1);
  final name = cmdNames[cmd] ?? 'cmd=$cmd';
  final out = <String, Object?>{'cmd': cmd, 'name': name, 'magic': magic, 'result': 0};
  final field = fieldForCmd[cmd];
  final sub = field != null ? readBytesField(pb, field) : null;
  if (sub != null) {
    final rf = _resultField[cmd];
    if (rf != null) out['result'] = readVarintField(sub, rf, 0);
    if (cmd == cmdAuth) {
      out['authenticated'] = readVarintField(sub, 1, 0) == 1;
    } else if (cmd == cmdTimeSync && sub.isNotEmpty) {
      out['timestamp'] = readVarintField(sub, 1, 0);
      out['timezone'] = decodeSigned(readVarintField(sub, 2, 0));
    } else if (cmd == cmdRoleChange && sub.isNotEmpty) {
      out['role'] = readVarintField(sub, 1, 0);
    } else if (cmd == cmdGetDeviceInfo || cmd == cmdSetDeviceInfo) {
      out['info'] = _decodeDeviceInfo(sub);
    } else if (cmd == cmdException) {
      out['failed_cmd'] = readVarintField(sub, 1, 0);
    }
  }
  var label = name;
  if (out['authenticated'] == true) label += ' authenticated';
  final r = out['result'] as int;
  if (r != 0) label += ' result=${errorNames[r] ?? r}';
  out['label'] = label;
  return out;
}

/// Decode a SID 0x10 message.
Map<String, Object?> decodeOnboarding(List<int> pb) {
  final cmd = readVarintField(pb, 1, -1);
  final out = <String, Object?>{
    'cmd': cmd,
    'name': obCmdNames[cmd] ?? 'cmd=$cmd',
    'magic': readVarintField(pb, 2, -1),
    'process_id': null,
    'event': null,
    'event_param': null,
    'worn': null,
    'error': 0,
  };
  var label = out['name'] as String;
  final cfg = readBytesField(pb, 3);
  if (cfg != null) {
    final pid = readVarintField(cfg, 1, 0);
    out['process_id'] = pid;
    out['error'] = readVarintField(cfg, 2, 0);
    label += ' ${obProcessNames[pid] ?? pid}';
  }
  final hb = readBytesField(pb, 4);
  if (hb != null) out['error'] = readVarintField(hb, 1, 0);
  final ev = readBytesField(pb, 5);
  if (ev != null) {
    out['event'] = readVarintField(ev, 1, 0);
    out['event_param'] = readVarintField(ev, 2, 0);
    out['error'] = readVarintField(ev, 3, 0);
    if (out['event'] == obEventWearStatus) {
      out['worn'] = out['event_param'] == 1;
      label += ' WEAR ${out['worn'] == true ? 'worn' : 'not worn'}';
    }
  }
  final e = out['error'] as int;
  if (e != 0) label += ' error=${errorNames[e] ?? e}';
  out['label'] = label;
  return out;
}

/// Decode a SID 0x81 reply/push: {magic, battery, charging, lid, in_case, error} or null.
Map<String, Object?>? decodeCase(List<int> pb) {
  final info = readBytesField(pb, 3);
  if (info == null) return null;
  int? opt(int f) {
    final v = readVarintField(info, f, -1);
    return v < 0 ? null : v;
  }

  return {
    'magic': readVarintField(pb, 2, -1),
    'battery': opt(1),
    'charging': opt(2),
    'lid': opt(3),
    'in_case': opt(4),
    'error': readVarintField(info, 5, 0),
  };
}
