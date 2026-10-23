/// Watchface layout (SID 0x1F "dashboard ext"): what sits next to the clock. Port of
/// g2/widgets/watchface.py. Everything is DECODED and UNTESTED live; a bad layout may leave the
/// dashboard blank until a valid one is uploaded (the UI asks the user to type UPLOAD).
library;

import 'dart:typed_data';

import 'crc.dart';
import 'limits.dart' as lim;
import 'pb.dart';

const int sid = 0x1F;
const int cmdRequestInfo = 0, cmdInfoResponse = 1, cmdRequestUpgrade = 2, cmdUpgradeResponse = 3;
const int cmdTransmitStart = 4, cmdFileData = 5, cmdFileDataAck = 6, cmdUpdateSuccess = 7;
const Map<int, String> cmdNames = {
  0: 'REQUEST_INFO', 1: 'INFO_RESPONSE', 2: 'REQUEST_UPGRADE', 3: 'UPGRADE_RESPONSE', 4: 'TRANSMIT_START', //
  5: 'FILE_DATA', 6: 'FILE_DATA_ACK', 7: 'UPDATE_SUCCESS',
};
int fieldForCmd(int c) => c + 3;

const int posLeft = 0, posCenter = 1, posRight = 2;
const int seqNews = 0, seqStock = 1, seqSchedule = 2, seqHealth = 3, seqQuicklist = 4, seqUserDef = 5;
const int compNone = 0, compTemperature = 1, compSunset = 2, compNextRain = 3, compNotification = 4;
const int compHeartRate = 5, compSteps = 6, compCalories = 7, compBloodOxygen = 8, compSleep = 9;
const int compressRaw = 0;
const int maxFragment = 2047;
const int maxFileSize = 30000;

/// Component names as the hub's watchface route uses them.
const Map<String, int> components = {
  'none': compNone, 'temperature': compTemperature, 'sunset': compSunset, 'next_rain': compNextRain, //
  'notification': compNotification, 'heart_rate': compHeartRate, 'steps': compSteps,
  'calories': compCalories, 'blood_oxygen': compBloodOxygen, 'sleep': compSleep,
};
const Map<String, int> positions = {'left': posLeft, 'center': posCenter, 'right': posRight};

Uint8List buildPackage(int cmd, int magic, List<int> inner) =>
    cat([encodeVarintField(1, cmd), encodeVarintField(2, magic), encodeMessageField(fieldForCmd(cmd), inner)]);

Uint8List buildInfoRequest(int magic) => buildPackage(cmdRequestInfo, magic, encodeVarintField(1, 1));
Uint8List buildUpgradeRequest(int magic, [int value = 1]) => buildPackage(cmdRequestUpgrade, magic, encodeVarintField(1, value));

Uint8List buildFileData(int magic, int sessionId, int totalSize, int fragmentIndex, List<int> data,
        {int compressMode = compressRaw}) =>
    buildPackage(
        cmdFileData,
        magic,
        cat([
          encodeVarintField(1, sessionId),
          encodeVarintField(2, totalSize),
          encodeVarintField(3, compressMode),
          encodeVarintField(4, fragmentIndex),
          encodeVarintField(5, data.length),
          encodeBytesField(6, data),
        ]));

/// Cut a layout file into cmd 5 payloads; [magic] gives the magic for each fragment.
List<Uint8List> buildFileFragments(int Function() magic, List<int> fileBytes,
    {int sessionId = 1, int fragmentSize = maxFragment, int compressMode = compressRaw}) {
  if (fileBytes.length > maxFileSize) {
    throw G2ValueError('layout file is ${fileBytes.length} bytes; limit $maxFileSize');
  }
  final chunks = <List<int>>[];
  for (var i = 0; i < fileBytes.length; i += fragmentSize) {
    chunks.add(fileBytes.sublist(i, i + fragmentSize > fileBytes.length ? fileBytes.length : i + fragmentSize));
  }
  if (chunks.isEmpty) chunks.add(const []);
  return [
    for (var i = 0; i < chunks.length; i++)
      buildFileData(magic(), sessionId, fileBytes.length, i, chunks[i], compressMode: compressMode)
  ];
}

/// Glasses-side messages (for offline fakes only).
Uint8List buildTransmitStart(int magic, [int value = 1]) => buildPackage(cmdTransmitStart, magic, encodeVarintField(1, value));
Uint8List buildUpdateSuccess(int magic, [int value = 1]) => buildPackage(cmdUpdateSuccess, magic, encodeVarintField(1, value));

Uint8List encodeLayout1([int clockType = 0, int left = compNone, int right = compNone]) =>
    cat([encodeVarintField(1, clockType), encodeVarintField(2, left), encodeVarintField(3, right)]);

Uint8List encodeLayout3([int alignIndex = 0, int dateEn = 1, int temperatureEn = 1]) =>
    cat([encodeVarintField(1, alignIndex), encodeVarintField(2, dateEn), encodeVarintField(3, temperatureEn)]);

/// DashboardExtLayoutConfigureFile bytes (field 5 does not exist in the schema).
Uint8List buildLayoutFile(String version, String hashCode_, int layoutNumber, List<int> layoutBytes,
    {int pos = posCenter, List<int> widgetSeq = const [seqNews, seqSchedule, seqQuicklist]}) {
  lim.checkCount('watchface widgetSeq', widgetSeq.length, lim.watchfaceWidgetSeqMax);
  final v = lim.utf8Fit(version, lim.watchfaceVersionMaxBytes);
  final h = lim.utf8Fit(hashCode_, lim.watchfaceHashMaxBytes);
  final p = Pb().string(1, v).string(2, h).varint(3, pos).varint(4, widgetSeq.length);
  if (widgetSeq.isNotEmpty) p.bytes(6, cat([for (final s in widgetSeq) encodeVarint(s)]));
  p.message(7, encodeMessageField(layoutNumber, layoutBytes));
  return p.toBytes();
}

String _crcHex(List<int> b) => crc16Bytes(b).map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// A layout showing the temperature by the clock (style 1 or 3). hash = crc16 hex of the body.
Uint8List buildTemperatureLayout(
    {String version = '1',
    String? hashCode_,
    int style = 1,
    int right = compSunset,
    int pos = posCenter,
    List<int> widgetSeq = const [seqNews, seqSchedule, seqQuicklist]}) {
  final int number;
  final Uint8List layout;
  if (style == 1) {
    number = 1;
    layout = encodeLayout1(0, compTemperature, right);
  } else if (style == 3) {
    number = 3;
    layout = encodeLayout3(0, 1, 1);
  } else {
    throw G2ValueError('style must be 1 or 3');
  }
  final h = hashCode_ ?? _crcHex(buildLayoutFile(version, '', number, layout, pos: pos, widgetSeq: widgetSeq));
  return buildLayoutFile(version, h, number, layout, pos: pos, widgetSeq: widgetSeq);
}

/// The hub's route build_layout: style 1 (left/right extras) or 3 (date/temperature), with
/// version = [version] (the hub uses a unix time stamp) and hash = crc16 hex of the body.
Uint8List buildHubLayout(String version,
    {int style = 1, String left = 'temperature', String right = 'sunset', String pos = 'center', bool date = true, bool temp = true}) {
  final p = positions[pos]!;
  final int number;
  final Uint8List layout;
  if (style == 3) {
    number = 3;
    layout = encodeLayout3(0, date ? 1 : 0, temp ? 1 : 0);
  } else {
    number = 1;
    layout = encodeLayout1(0, components[left]!, components[right]!);
  }
  final body = buildLayoutFile(version, '', number, layout, pos: p);
  return buildLayoutFile(version, _crcHex(body), number, layout, pos: p);
}

/// Decode any DashboardExtPackage.
Map<String, Object?> decode(List<int> pb) {
  final cmd = readVarintField(pb, 1, 0);
  final out = <String, Object?>{'cmd': cmd, 'name': cmdNames[cmd] ?? 'cmd=$cmd', 'magic': readVarintField(pb, 2, -1)};
  final sub = cmdNames.containsKey(cmd) ? readBytesField(pb, fieldForCmd(cmd)) : null;
  if (sub == null) return out;
  if (cmd == cmdInfoResponse) {
    out['exists'] = readVarintField(sub, 1, 0);
    out['version'] = readStringField(sub, 2);
    out['hash'] = readStringField(sub, 3);
  } else if (cmd == cmdUpgradeResponse) {
    out['status'] = readVarintField(sub, 1, 0);
  } else if (cmd == cmdFileData || cmd == cmdFileDataAck) {
    out['session_id'] = readVarintField(sub, 1, 0);
    out['total_size'] = readVarintField(sub, 2, 0);
    out['compress_mode'] = readVarintField(sub, 3, 0);
    out['fragment_index'] = readVarintField(sub, 4, 0);
    out['packet_size'] = readVarintField(sub, 5, 0);
    if (cmd == cmdFileData) {
      out['data'] = readBytesField(sub, 6) ?? Uint8List(0);
    } else {
      out['status'] = readVarintField(sub, 6, 0);
    }
  } else {
    out['value'] = readVarintField(sub, 1, 0);
  }
  return out;
}
