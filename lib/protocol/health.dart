/// Health data (SID 0x0E): the dashboard health card snapshot. Port of g2/widgets/health.py
/// (DECODED; never sent to real glasses).
library;

import 'dart:typed_data';

import 'pb.dart';

const int sid = 0x0E;
const int cmdSingleData = 1, cmdMultData = 2, cmdSingleHighlight = 3, cmdMultHighlight = 4;
const Map<int, String> cmdNames = {1: 'SINGLE_DATA', 2: 'MULT_DATA', 3: 'SINGLE_HIGHLIGHT', 4: 'MULT_HIGHLIGHT'};
int fieldForCmd(int c) => c + 2;

const int typeAll = 1, typeSteps = 2, typeCalories = 3, typeSleep = 4, typeHeartRate = 5;
const int typeBloodOxygen = 6, typeTemperature = 7, typeHrv = 8, typeProductivity = 9;
const Map<int, String> typeNames = {
  1: 'ALL', 2: 'STEPS', 3: 'CALORIES', 4: 'SLEEP', 5: 'HEART_RATE', 6: 'BLOOD_OXYGEN', 7: 'TEMPERATURE', //
  8: 'HRV', 9: 'PRODUCTIVITY',
};
const int trendUnknown = 0, trendUp = 1, trendSteady = 2, trendDown = 3;
const int hlHasItems = 1, hlAllNormal = 2, hlNoData = 3;
const int maxItems = 8;

/// The app's magic for health packets: (microseconds // 1000) & 0xff.
int appMagic(int nowUs) => (nowUs ~/ 1000) & 0xFF;

/// One HealthSingleData; null / 0 fields are left out (value/avg are FLOAT).
Uint8List buildSingleData(int dataType, {num? value, num? goal, num? avgValue, num? duration, int? trend, int? errorCode}) {
  final p = Pb().varint(1, dataType);
  if (goal != null && goal != 0) p.varint(2, goal.toInt());
  if (value != null) p.float32(3, value.toDouble());
  if (avgValue != null) p.float32(4, avgValue.toDouble());
  if (duration != null && duration != 0) p.varint(5, duration.toInt());
  if (errorCode != null && errorCode != 0) p.varint(6, errorCode);
  if (trend != null && trend != 0) p.varint(7, trend);
  return p.toBytes();
}

Uint8List buildPackage(int cmd, int magic, List<int> inner) =>
    cat([encodeVarintField(1, cmd), encodeVarintField(2, magic), encodeMessageField(fieldForCmd(cmd), inner)]);

Uint8List buildMultData(int magic, List<List<int>> items, {int dataType = typeAll}) {
  final p = Pb().varint(1, dataType);
  for (final it in items.take(maxItems)) {
    p.message(2, it);
  }
  return buildPackage(cmdMultData, magic, p.toBytes());
}

/// The dashboard snapshot: STEPS, CALORIES, SLEEP, HEART_RATE, BLOOD_OXYGEN, PRODUCTIVITY;
/// a metric that is null is skipped.
Uint8List buildDashboardSnapshot(int magic,
    {num? steps,
    num? stepGoal,
    num? calories,
    num? calorieGoal,
    num? sleep,
    num? sleepMinutes,
    num? heartRate,
    num? heartRateAvg,
    num? spo2,
    num? spo2Avg,
    num? productivity,
    int? productivityTrend}) {
  final items = <Uint8List>[];
  if (steps != null) items.add(buildSingleData(typeSteps, value: steps, goal: stepGoal));
  if (calories != null) items.add(buildSingleData(typeCalories, value: calories, goal: calorieGoal));
  if (sleep != null || (sleepMinutes != null && sleepMinutes != 0)) {
    items.add(buildSingleData(typeSleep, value: (sleep == null || sleep == 0) ? 0 : sleep, duration: sleepMinutes));
  }
  if (heartRate != null) items.add(buildSingleData(typeHeartRate, value: heartRate, avgValue: heartRateAvg));
  if (spo2 != null) items.add(buildSingleData(typeBloodOxygen, value: spo2, avgValue: spo2Avg));
  if (productivity != null) items.add(buildSingleData(typeProductivity, value: productivity, trend: productivityTrend));
  return buildMultData(magic, items);
}

Map<String, Object?> decodeSingleData(List<int> sub) {
  final t = readVarintField(sub, 1, 0);
  return {
    'type': t,
    'name': typeNames[t] ?? 'type=$t',
    'goal': readVarintField(sub, 2, 0),
    'value': readFloatField(sub, 3, 0.0),
    'avg_value': readFloatField(sub, 4, 0.0),
    'duration': readVarintField(sub, 5, 0),
    'error': readVarintField(sub, 6, 0),
    'trend': readVarintField(sub, 7, 0),
  };
}

/// Decode any HealthDataPackage (MULT_DATA → items; highlights not needed by the app).
Map<String, Object?> decode(List<int> pb) {
  final cmd = readVarintField(pb, 1, 0);
  final out = <String, Object?>{'cmd': cmd, 'name': cmdNames[cmd] ?? 'cmd=$cmd', 'magic': readVarintField(pb, 2, -1)};
  final sub = cmdNames.containsKey(cmd) ? readBytesField(pb, fieldForCmd(cmd)) : null;
  if (sub == null) return out;
  if (cmd == cmdSingleData) {
    out['data'] = decodeSingleData(sub);
  } else if (cmd == cmdMultData) {
    out['data_type'] = readVarintField(sub, 1, 0);
    out['items'] = [for (final f in iterFields(sub)) if (f.number == 2 && f.wire == 2) decodeSingleData(f.asBytes)];
    out['error'] = readVarintField(sub, 3, 0);
  } else if (cmd == cmdSingleHighlight) {
    out['highlights'] = [
      [readVarintField(sub, 1, 0), readStringField(sub, 2)]
    ];
    out['error'] = readVarintField(sub, 3, 0);
  } else {
    out['highlights'] = [
      for (final f in iterFields(sub))
        if (f.number == 1 && f.wire == 2) [readVarintField(f.asBytes, 1, 0), readStringField(f.asBytes, 2)]
    ];
    out['error'] = readVarintField(sub, 2, 0);
    out['status'] = readVarintField(sub, 3, 0);
  }
  return out;
}
