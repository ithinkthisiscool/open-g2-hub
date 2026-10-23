/// Translate (SID 0x05): two-language subtitles. Port of g2/apps/translate.py (DECODED from
/// the official app; untested live). Phase 1 uses it to show text the user typed.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'limits.dart' as lim;
import 'pb.dart';
import 'pytext.dart';

const int sid = 0x05;
const int cmdCtrl = 1, cmdResult = 2, cmdNotify = 161, cmdCommResp = 162, cmdModeSwitch = 163;
const int cmdLangSwitchReq = 164, cmdLangSwitchRsp = 165, cmdHeartbeat = 255;
const Map<int, String> cmdNames = {
  1: 'CTRL', 2: 'RESULT', 161: 'NOTIFY', 162: 'COMM_RESP', 163: 'MODE_SWITCH', 164: 'LANG_SWITCH_REQ',
  165: 'LANG_SWITCH_RSP', 255: 'HEARTBEAT', //
};
const Map<int, int> fieldForCmd = {1: 3, 2: 4, 161: 5, 163: 6, 162: 7, 255: 8, 164: 9, 165: 10};

const int tcmdNone = 0, tcmdOpen = 1, tcmdClose = 2, tcmdPause = 3, tcmdResume = 4;
const Map<int, String> tcmdNames = {0: 'NONE', 1: 'OPEN', 2: 'CLOSE', 3: 'PAUSE', 4: 'RESUME'};
const int errOk = 0, errMagicDuplicate = 66;
const Map<int, String> errorNames = {0: 'OK', 1: 'FAIL', 2: 'NETWORK', 3: 'NOT_SUPPORT', 4: 'FALLBACK_FAIL', 66: 'MAGIC_DUPLICATE'};
const Duration heartbeatInterval = Duration(seconds: 4);

Uint8List buildPackage(int cmd, int magic, List<int> inner) =>
    cat([encodeVarintField(1, cmd), encodeVarintField(2, magic), encodeMessageField(fieldForCmd[cmd]!, inner)]);

String _code(String lang) => pyStrip(lang).toUpperCase();

/// CTRL OPEN {1 OPEN, 2 "SRC>DST", 5 langList, 6 srcKey, 7 dstKey}.
Uint8List buildOpen(int magic, String srcLang, String dstLang,
    {String? srcKey, String? dstKey, List<(String, String)>? langList}) {
  final src = _code(srcLang), dst = _code(dstLang);
  final p = Pb().varint(1, tcmdOpen).string(2, '$src>$dst');
  for (final (key, text) in langList ?? const <(String, String)>[]) {
    p.message(5, cat([encodeStringField(1, lim.utf8Fit(key, lim.translateKeyMaxBytes)), encodeStringField(2, text)]));
  }
  p.string(6, lim.utf8Fit((srcKey != null && srcKey.isNotEmpty) ? _code(srcKey) : src, lim.translateKeyMaxBytes));
  p.string(7, lim.utf8Fit((dstKey != null && dstKey.isNotEmpty) ? _code(dstKey) : dst, lim.translateKeyMaxBytes));
  return buildPackage(cmdCtrl, magic, p.toBytes());
}

Uint8List buildCtrl(int magic, int tcmd) => buildPackage(cmdCtrl, magic, encodeVarintField(1, tcmd));
Uint8List buildPause(int magic) => buildCtrl(magic, tcmdPause);
Uint8List buildResume(int magic) => buildCtrl(magic, tcmdResume);
Uint8List buildClose(int magic) => buildCtrl(magic, tcmdClose);

/// RESULT {1 srcText, 2 dstText, 4 endFlag, 5 speaker}. Texts trimmed (a lone " " translation
/// is kept) and cut to the 1024-byte firmware cap.
Uint8List buildText(int magic, String srcText, String dstText, {bool finalLine = true, Object? speaker}) {
  var dst = dstText == ' ' ? dstText : pyStrip(dstText);
  final src = lim.utf8Fit(pyStrip(srcText), lim.translateTextMaxBytes);
  dst = lim.utf8Fit(dst, lim.translateTextMaxBytes);
  final p = Pb().string(1, src).string(2, dst);
  if (finalLine) p.varint(4, 1);
  if (speaker != null && !(speaker is String && speaker.isEmpty) && !(speaker is List<int> && speaker.isEmpty)) {
    p.bytes(5, speaker is List<int> ? speaker : utf8.encode(speaker as String));
  }
  return buildPackage(cmdResult, magic, p.toBytes());
}

Uint8List buildHeartbeat(int magic) => buildPackage(cmdHeartbeat, magic, Uint8List(0));

Uint8List buildLangSwitchResponse(int magic, [int error = errOk]) =>
    buildPackage(cmdLangSwitchRsp, magic, error != 0 ? encodeVarintField(1, error) : Uint8List(0));

Map<String, Object?> decode(List<int> pb) {
  final cmd = readVarintField(pb, 1, -1);
  final magic = readVarintField(pb, 2, -1);
  final name = cmdNames[cmd] ?? 'cmd=$cmd';
  final field = fieldForCmd[cmd];
  final sub = field != null ? readBytesField(pb, field) : null;
  int? value, error;
  String? langKey;
  var label = name;
  if (sub != null) {
    if (cmd == cmdNotify) {
      value = readVarintField(sub, 1, 0);
      error = readVarintField(sub, 2, 0);
      label += ' ${tcmdNames[value] ?? value}';
    } else if (cmd == cmdModeSwitch) {
      value = readVarintField(sub, 1, 0);
      label += ' mode=$value';
    } else if (cmd == cmdLangSwitchReq) {
      langKey = readStringField(sub, 1, '');
      label += ' $langKey';
    } else if (cmd == cmdCommResp || cmd == cmdLangSwitchRsp) {
      error = readVarintField(sub, 1, 0);
      if (cmd == cmdCommResp) label += ' ${errorNames[error] ?? error}';
    } else if (cmd == cmdCtrl) {
      value = readVarintField(sub, 1, 0);
      error = readVarintField(sub, 4, 0);
      label += ' ${tcmdNames[value] ?? value}';
    }
    if (error != null && error != 0 && cmd != cmdCommResp) label += ' errorCode=${errorNames[error] ?? error}';
  }
  return {'cmd': cmd, 'name': name, 'magic': magic, 'value': value, 'lang_key': langKey, 'error': error, 'label': label};
}
