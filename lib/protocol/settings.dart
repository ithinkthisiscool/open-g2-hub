/// Glasses settings (SID 0x09) and module configure (SID 0x20: screen-off time, language).
/// Port of g2/device/settings.py. Every builder validates its input and throws
/// [G2ValueError] exactly where Python raises ValueError.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'pb.dart';

const int sidSettings = 0x09;
const int sidModule = 0x20;

const int cmdSet = 1, cmdRead = 2, cmdDeviceEvent = 3, cmdDeviceAck = 4, cmdAppAck = 5;
const Map<int, String> cmdNames = {1: 'SET', 2: 'READ', 3: 'DEVICE_EVENT', 4: 'DEVICE_ACK', 5: 'APP_ACK'};

const int readBrightness = 0, readBasic = 1;

const int fBrightness = 1, fY = 2, fX = 3, fHeadUp = 4, fWear = 5, fSilent = 6;
const int fAppPage = 7, fAdvanced = 8, fUnits = 9, fGestures = 10, fHand = 11, fControl = 12;
const Map<int, String> setNames = {
  1: 'brightness',
  2: 'display_height',
  3: 'display_distance',
  4: 'head_up',
  5: 'wear_detection',
  6: 'silent_mode',
  7: 'app_page',
  8: 'kill_all_features',
  9: 'units',
  10: 'gestures',
  11: 'dominant_hand',
  12: 'turn_on_device',
};

const int brightnessMin = 1, brightnessMax = 50;
const int headUpAngleMin = 0, headUpAngleMax = 60;
const int displayLevelMax = 20;
const int enumMax = 15;

/// (screenOn, operationType, apptype) list the official app sends on every connect.
const List<List<int>> gesturesAppDefault = [
  [0, 0, 0],
  [0, 1, 0],
  [0, 2, 0],
];

const Map<int, String> readbackFields = {
  1: 'setting_type',
  2: 'brightness_level',
  3: 'display_height',
  4: 'display_distance',
  5: 'left_version',
  6: 'right_version',
  7: 'head_up',
  8: 'head_up_angle',
  9: 'head_up_calibration',
  10: 'wear_detection',
  11: 'running_status',
  12: 'battery',
  13: 'charging',
  14: 'silent_mode',
  15: 'left_calibration',
  16: 'right_calibration',
  17: 'head_up_recalibration_ok',
  18: 'brightness_auto',
  19: 'unread_count',
};
const Set<int> _stringFields = {5, 6};

const int modCmdLanguage = 0, modCmdReadTimeout = 1, modCmdSetTimeout = 2;
const Map<int, String> modCmdNames = {0: 'SYSTEM_GENERAL_SETTING', 1: 'INQUIRE_AUTO_CLOSE', 2: 'SET_AUTO_CLOSE'};

const int timeoutNever = 65365;
const List<int> timeoutChoices = [3, 5, 10, 15, 30, timeoutNever];

const Map<int, String> languages = {
  0: 'English',
  1: 'German',
  2: 'French',
  3: 'Spanish',
  4: 'Italian',
  5: 'Japanese',
  6: 'Chinese (Traditional)',
  7: 'Chinese (Simplified)',
  8: 'Korean',
};

/// Accept bool or 0/1 (Python _flag).
int flag(Object? value, String what) {
  if (value is bool) return value ? 1 : 0;
  if (value == 0 || value == 1) return value as int;
  throw G2ValueError('$what must be True/False or 0/1, got $value');
}

/// Python _int_in: an int (not a bool) within lo..hi.
int intIn(Object? value, int lo, int hi, String what) {
  if (value is! int || value < lo || value > hi) {
    throw G2ValueError('$what must be an integer $lo..$hi, got $value');
  }
  return value;
}

Uint8List buildSet(int magic, int field, List<int> inner) => cat([
      encodeVarintField(1, cmdSet),
      encodeVarintField(2, magic),
      encodeMessageField(3, encodeMessageField(field, inner)),
    ]);

Uint8List _module(int cmd, int magic, int field, List<int> inner) =>
    cat([encodeVarintField(1, cmd), encodeVarintField(2, magic), encodeMessageField(field, inner)]);

Uint8List buildReadSettings(int magic, [Object? settingType = readBasic]) {
  final t = intIn(settingType, 0, 1, 'setting_type');
  return cat([encodeVarintField(1, cmdRead), encodeVarintField(2, magic), encodeMessageField(4, encodeVarintField(1, t))]);
}

/// Brightness level 1..50 (the app slider range).
Uint8List buildBrightness(int magic, Object? level) =>
    buildSet(magic, fBrightness, encodeVarintField(2, intIn(level, brightnessMin, brightnessMax, 'brightness level')));

Uint8List buildAutoBrightness(int magic, Object? on) => buildSet(magic, fBrightness, encodeVarintField(1, flag(on, 'on')));

Uint8List buildBrightnessCalibration(int magic, Object? left, Object? right) {
  final l = intIn(left, 0, 255, 'left');
  final r = intIn(right, 0, 255, 'right');
  return buildSet(magic, fBrightness, cat([encodeVarintField(3, l), encodeVarintField(4, r)]));
}

Uint8List buildSilentMode(int magic, Object? on) => buildSet(magic, fSilent, encodeVarintField(1, flag(on, 'on')));

Uint8List buildWearDetection(int magic, Object? on) => buildSet(magic, fWear, encodeVarintField(1, flag(on, 'on')));

Uint8List buildHeadUp(int magic, Object? enabled, [Object? angle]) {
  final p = Pb().varint(1, flag(enabled, 'enabled'));
  if (angle != null) p.varint(2, intIn(angle, headUpAngleMin, headUpAngleMax, 'head-up angle'));
  return buildSet(magic, fHeadUp, p.toBytes());
}

Uint8List buildDisplayHeight(int magic, Object? level) =>
    buildSet(magic, fY, encodeVarintField(1, intIn(level, 0, displayLevelMax, 'display height')));

Uint8List buildDisplayDistance(int magic, Object? level) =>
    buildSet(magic, fX, encodeVarintField(1, intIn(level, 0, displayLevelMax, 'display distance')));

List<Uint8List> buildDisplayPosition(int magic, {Object? height, Object? distance}) {
  if (height == null && distance == null) throw G2ValueError('give height and/or distance');
  return [
    if (height != null) buildDisplayHeight(magic, height),
    if (distance != null) buildDisplayDistance(magic, distance),
  ];
}

Uint8List buildUnits(int magic,
    {Object? unitFormat = 0, Object? distanceUnit = 0, Object? timeFormat = 1, Object? dateFormat = 0, Object? temperatureUnit = 1}) {
  final vals = [unitFormat, distanceUnit, timeFormat, dateFormat, temperatureUnit];
  const names = ['unit_format', 'distance_unit', 'time_format', 'date_format', 'temperature_unit'];
  final p = Pb();
  for (var i = 0; i < 5; i++) {
    p.varint(i + 1, intIn(vals[i], 0, enumMax, names[i]));
  }
  return buildSet(magic, fUnits, p.toBytes());
}

Uint8List buildGestures(int magic, [List<List<Object?>> entries = gesturesAppDefault]) {
  if (entries.isEmpty) throw G2ValueError('entries must not be empty');
  final p = Pb();
  for (final e in entries) {
    if (e.length != 3) {
      throw G2ValueError('each gesture entry is (screen_on, operation_type, app_type), got $e');
    }
    final item = cat([
      encodeVarintField(1, flag(e[0], 'screen_on')),
      encodeVarintField(2, intIn(e[1], 0, enumMax, 'operation_type')),
      encodeVarintField(3, intIn(e[2], 0, 1, 'app_type')),
    ]);
    p.message(1, item);
  }
  return buildSet(magic, fGestures, p.toBytes());
}

Uint8List buildDominantHand(int magic, Object? hand, [List<int>? ringMac]) {
  final p = Pb().varint(1, intIn(hand, 0, 1, 'hand'));
  if (ringMac != null) {
    if (ringMac.length != 6) throw G2ValueError('ring_mac must be 6 bytes');
    p.bytes(2, ringMac);
  }
  return buildSet(magic, fHand, p.toBytes());
}

int _timeoutValue(Object? seconds) {
  if (seconds == null || seconds == 'never') return timeoutNever;
  if (seconds is! int || !timeoutChoices.contains(seconds)) {
    throw G2ValueError("display timeout must be one of $timeoutChoices or 'never', got $seconds");
  }
  return seconds;
}

/// Screen-off time, SID 0x20 cmd 2 {4: {1 seconds}}; 'never'/null -> 65365.
Uint8List buildDisplayTimeout(int magic, Object? seconds) =>
    _module(modCmdSetTimeout, magic, 4, encodeVarintField(1, _timeoutValue(seconds)));

Uint8List buildReadDisplayTimeout(int magic) => _module(modCmdReadTimeout, magic, 4, Uint8List(0));

/// Glasses UI language, SID 0x20 cmd 0 {3: {1 index}}; index or language name.
Uint8List buildLanguage(int magic, Object? index) {
  Object? idx = index;
  if (idx is String) {
    final match = languages.entries.where((e) => e.value.toLowerCase() == (idx as String).toLowerCase()).toList();
    if (match.isEmpty) throw G2ValueError('unknown language $idx');
    idx = match.first.key;
  }
  final i = intIn(idx, 0, 8, 'language index');
  return _module(modCmdLanguage, magic, 3, encodeVarintField(1, i));
}

Map<String, Object?> decodeReadback(List<int> sub) {
  final out = <String, Object?>{};
  for (final f in iterFields(sub)) {
    final key = readbackFields[f.number] ?? 'field_${f.number}';
    if (_stringFields.contains(f.number) && f.wire == 2) {
      out[key] = utf8.decode(f.asBytes, allowMalformed: true);
    } else if (f.wire == 0) {
      out[key] = f.asInt;
    }
  }
  return out;
}

Map<String, Object?> withDefaults(Map<String, Object?> values) {
  final full = <String, Object?>{
    for (final e in readbackFields.entries)
      if (!_stringFields.contains(e.key) && e.key != 1) e.value: 0,
  };
  full.addAll(values);
  return full;
}

String _hexColon(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(':');

Map<String, Object?> _decodeSet(List<int> sub) {
  final out = <String, Object?>{};
  for (final f in iterFields(sub)) {
    if (f.wire != 2) continue;
    final v = f.asBytes;
    final name = setNames[f.number] ?? 'field_${f.number}';
    switch (f.number) {
      case fBrightness:
        out[name] = {
          'auto': readVarintField(v, 1, 0),
          'level': readVarintField(v, 2, 0),
          'left_calibration': readVarintField(v, 3, 0),
          'right_calibration': readVarintField(v, 4, 0),
        };
      case fHeadUp:
        out[name] = {
          'enabled': readVarintField(v, 1, 0),
          'angle': readVarintField(v, 2, 0),
          'calibration_switch': readVarintField(v, 3, 0),
          'calibration': readVarintField(v, 4, 0),
        };
      case fUnits:
        const keys = ['unit_format', 'distance_unit', 'time_format', 'date_format', 'temperature_unit'];
        out[name] = {for (var i = 0; i < 5; i++) keys[i]: readVarintField(v, i + 1, 0)};
      case fGestures:
        out[name] = [
          for (final g in iterFields(v))
            if (g.number == 1 && g.wire == 2)
              [readVarintField(g.asBytes, 1, 0), readVarintField(g.asBytes, 2, 0), readVarintField(g.asBytes, 3, 0)]
        ];
      case fHand:
        final mac = readBytesField(v, 2);
        out[name] = {'hand': readVarintField(v, 1, 0), 'ring_mac': (mac != null && mac.isNotEmpty) ? _hexColon(mac) : null};
      default:
        out[name] = readVarintField(v, 1, 0);
    }
  }
  return out;
}

/// Decode any SID 0x09 message: {cmd, name, magic, push, values, set, event, label}.
Map<String, Object?> decode(List<int> pb) {
  final cmd = readVarintField(pb, 1, -1);
  final out = <String, Object?>{
    'cmd': cmd,
    'name': cmdNames[cmd] ?? 'cmd=$cmd',
    'magic': readVarintField(pb, 2, -1),
    'push': false,
    'values': null,
    'set': null,
    'event': null,
  };
  var label = out['name'] as String;
  final req = readBytesField(pb, 4);
  if (req != null) {
    final v = decodeReadback(req);
    out['values'] = v;
    out['push'] = !v.containsKey('setting_type');
    label += (out['push'] == true ? ' push' : '') +
        ['battery', 'charging', 'brightness_level', 'head_up_angle'].where(v.containsKey).map((k) => ' $k=${v[k]}').join();
  }
  final sub = readBytesField(pb, 3);
  if (sub != null) {
    final s = _decodeSet(sub);
    out['set'] = s;
    // Python: label += ' ' + ','.join(set) if set else ''  (precedence: whole RHS is the ternary)
    label += s.isNotEmpty ? ' ${s.keys.join(',')}' : '';
  }
  final ev = readBytesField(pb, 5);
  if (ev != null) {
    out['event'] = {'recalibration_status': readVarintField(ev, 1, 0), 'silent_mode': readVarintField(ev, 2, 0)};
  }
  for (final fld in [6, 7]) {
    final ack = readBytesField(pb, fld);
    if (ack != null) out['event'] = {'package_id': readVarintField(ack, 1, 0), 'flag': readVarintField(ack, 2, 0)};
  }
  out['label'] = label;
  return out;
}

/// Decode a SID 0x20 reply: {cmd, name, magic, language, timeout, timeout_never}.
Map<String, Object?> decodeModule(List<int> pb) {
  final cmd = readVarintField(pb, 1, -1);
  final out = <String, Object?>{
    'cmd': cmd,
    'name': modCmdNames[cmd] ?? 'cmd=$cmd',
    'magic': readVarintField(pb, 2, -1),
    'language': null,
    'timeout': null,
    'timeout_never': null,
  };
  final sys = readBytesField(pb, 3);
  if (sys != null) out['language'] = readVarintField(sys, 1, 0);
  final dash = readBytesField(pb, 4);
  if (dash != null) {
    final t = readVarintField(dash, 1, -1);
    if (t >= 0) {
      out['timeout'] = t;
      out['timeout_never'] = t > 20;
    }
  }
  return out;
}
