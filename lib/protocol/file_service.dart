/// EvenFile service (SIDs 0xC4/0xC5, characteristic 0x7401/0x7402) and the notification JSON
/// file. Port of g2/transport/file_service.py (frame builders + notification_json + the two
/// SID 0x04 control builders). UNTESTED LIVE in the Python library as well.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'crc.dart';
import 'limits.dart' as lim;
import 'pb.dart';

const int charFileWriteId = 0x7401;
const int charFileNotifyId = 0x7402;
const int sidFileCmd = 0xC4;
const int sidFileData = 0xC5;
const int sidNotificationCh = 0x04;
const int flagFile = 0x00;

const int cidStart = 0, cidData = 1, cidResultCheck = 2;
const Map<int, String> rspNames = {0: 'SUCCESS', 2: 'DATA_CRC_ERR', 4: 'TIMEOUT', 5: 'NO_RESOURCES', 6: 'RESULT_CHECK_FAIL'};
const Set<int> rspRetry = {2, 4, 5};
const int fileTypeWhitelist = 0, fileTypeNotification = 1;
final Uint8List filePath = Uint8List.fromList(utf8.encode('user/notify_whitelist.json'));
const int blockSize = 4096;
const int packetData = 232;

Uint8List _header(int magic, int length, int total, int num, int sid) =>
    Uint8List.fromList([0xAA, 0x21, magic & 0xFF, length & 0xFF, total & 0xFF, num & 0xFF, sid & 0xFF, flagFile]);

/// header + payload + CRC16(payload), for START / DATA prefix / RESULT_CHECK.
Uint8List singleFrame(int magic, int sid, List<int> payload) {
  final body = cat([payload, crc16Bytes(payload)]);
  return cat([_header(magic, body.length, 1, 1, sid), body]);
}

/// START: [00] + u32 fileType, u32 length, u32 crc32Efs, 80-byte zero-padded path (LE).
Uint8List buildStart(int magic, int fileType, List<int> data) {
  final meta = ByteData(12)
    ..setUint32(0, fileType, Endian.little)
    ..setUint32(4, data.length, Endian.little)
    ..setUint32(8, crc32Efs(data), Endian.little);
  final path = Uint8List(80)..setRange(0, filePath.length > 80 ? 80 : filePath.length, filePath);
  return singleFrame(magic, sidFileCmd, cat([[cidStart], meta.buffer.asUint8List(), path]));
}

Uint8List buildDataPrefix(int magic) => singleFrame(magic, sidFileCmd, [cidData]);

/// ceil(len/232) packets plus one CRC-only packet when len % 232 is 0 or 231.
List<Uint8List> buildDataPackets(int magic, List<int> block) {
  final crc = crc16Bytes(block);
  final chunks = <List<int>>[];
  for (var i = 0; i < block.length; i += packetData) {
    chunks.add(block.sublist(i, i + packetData > block.length ? block.length : i + packetData));
  }
  if (chunks.isEmpty) chunks.add(const []);
  final r = block.length % packetData;
  if ((r == 0 || r == packetData - 1) && block.isNotEmpty) chunks.add(const []);
  final frames = <Uint8List>[];
  for (var n = 1; n <= chunks.length; n++) {
    final body = cat([chunks[n - 1], if (n == chunks.length) crc]);
    frames.add(cat([_header(magic, body.length, chunks.length, n, sidFileData), body]));
  }
  return frames;
}

Uint8List buildResultCheck(int magic) => singleFrame(magic, sidFileCmd, [cidResultCheck]);

/// Python json.dumps(ensure_ascii=False) string escaping.
String _pyJsonString(String s) {
  final b = StringBuffer('"');
  for (final c in s.runes) {
    switch (c) {
      case 0x22:
        b.write(r'\"');
      case 0x5C:
        b.write(r'\\');
      case 0x0A:
        b.write(r'\n');
      case 0x0D:
        b.write(r'\r');
      case 0x09:
        b.write(r'\t');
      case 0x08:
        b.write(r'\b');
      case 0x0C:
        b.write(r'\f');
      default:
        if (c < 0x20) {
          b.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
        } else {
          b.writeCharCode(c);
        }
    }
  }
  b.write('"');
  return b.toString();
}

String _two(int v) => v.toString().padLeft(2, '0');

/// Notification file body: compact UTF-8 JSON {"android_notification": {...}} in the app's key
/// order. [now] unix seconds; [utcOffsetSeconds] is the local offset used for `date`
/// (defaults to this device's offset at [now]).
Uint8List notificationJson(String title, String message,
    {String subtitle = '',
    String displayName = 'Even Realities',
    String appIdentifier = 'com.even.sg',
    int? msgId,
    int? now,
    int? utcOffsetSeconds}) {
  final t = now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  // Firmware JSON parser byte caps (strncpy, 0x498a7a): fit on a character boundary.
  title = lim.utf8Fit(title, lim.notificationJsonTitleMaxBytes);
  subtitle = lim.utf8Fit(subtitle, lim.notificationJsonSubtitleMaxBytes);
  message = lim.utf8Fit(message, lim.notificationJsonMessageMaxBytes);
  displayName = lim.utf8Fit(displayName, lim.notificationJsonDisplayNameMaxBytes);
  appIdentifier = lim.utf8Fit(appIdentifier, lim.notificationJsonAppIdMaxBytes);
  final offset = utcOffsetSeconds ??
      DateTime.fromMillisecondsSinceEpoch(t * 1000).timeZoneOffset.inSeconds;
  final l = DateTime.fromMillisecondsSinceEpoch((t + offset) * 1000, isUtc: true);
  final date = '${l.year.toString().padLeft(4, '0')}${_two(l.month)}${_two(l.day)}T${_two(l.hour)}${_two(l.minute)}${_two(l.second)}';
  final id = msgId ?? (t & 0x7FFFFFFF);
  final body = '{"android_notification":{"msg_id":$id,"action":0,'
      '"app_identifier":${_pyJsonString(appIdentifier)},"title":${_pyJsonString(title)},'
      '"subtitle":${_pyJsonString(subtitle)},"message":${_pyJsonString(message)},"time_s":$t,'
      '"date":"$date","display_name":${_pyJsonString(displayName)}}}';
  return Uint8List.fromList(utf8.encode(body));
}

/// SID 0x04 CTRL {1: 1, 2: magic, 3: {1 enable, 2 autoDisplay, 3 dispTime, [5 dnd]}}.
Uint8List buildNotificationCtrl(int magic,
    {bool enable = true, bool autoDisplay = true, int dispTime = 5, bool dnd = false}) {
  final ctrl = Pb().varint(1, enable ? 1 : 0).varint(2, autoDisplay ? 1 : 0).varint(3, dispTime);
  if (dnd) ctrl.varint(5, 1);
  return cat([encodeVarintField(1, 1), encodeVarintField(2, magic), encodeMessageField(3, ctrl.toBytes())]);
}

/// SID 0x04 cmd 3 {6: {1 whitelistDisable}}: bypass the glasses-side app whitelist.
Uint8List buildWhitelistDisable(int magic, {bool disable = true}) => cat([
      encodeVarintField(1, 3),
      encodeVarintField(2, magic),
      encodeMessageField(6, encodeVarintField(1, disable ? 1 : 0)),
    ]);

/// Replies are [cid, rsp]; null when too short.
(int, int)? parseFileReply(List<int> pb) => pb.length < 2 ? null : (pb[0], pb[1]);
