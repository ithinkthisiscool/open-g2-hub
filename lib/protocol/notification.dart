/// Notification (SID 0x04): control, whitelist, iOS app register, and reply decoding.
/// Port of g2/apps/notification.py. The notification content itself goes over the file
/// service (see file_service.dart notificationJson).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'limits.dart' as lim;
import 'pb.dart';

export 'file_service.dart' show buildNotificationCtrl, buildWhitelistDisable, notificationJson;

const int sidNotification = 0x04;
const int cmdCtrl = 1;
const int cmdWhitelistCtrl = 3;
const Map<int, String> cmdNames = {cmdCtrl: 'CTRL', cmdWhitelistCtrl: 'WHITELIST_CTRL'};
const int fieldCtrl = 3, fieldIos = 4, fieldResp = 5, fieldWhitelistCtrl = 6, fieldWhitelistChk = 7;
const Map<int, String> wlCheckNames = {0: 'MATCH', 1: 'MISMATCH'};
const Map<int, String> errorNames = {0: 'SUCCESS', 1: 'FAIL', 8: 'NOT_SUPPORT'};

Uint8List encodeIos(String appId, String displayName) {
  final a = utf8.encode(lim.utf8Fit(appId, lim.notificationAppIdMaxBytes));
  final n = utf8.encode(lim.utf8Fit(displayName, lim.notificationDisplayNameMaxBytes));
  return cat([encodeBytesField(1, a), encodeBytesField(2, n)]);
}

Uint8List buildPackage(int commandId, int magic, int field, List<int> inner) =>
    cat([encodeVarintField(1, commandId), encodeVarintField(2, magic), encodeMessageField(field, inner)]);

Uint8List buildIos(int magic, int commandId, String appId, String displayName) =>
    buildPackage(commandId, magic, fieldIos, encodeIos(appId, displayName));

String _pyRepr(String s) {
  // Python repr() for simple strings: single quotes unless the text contains ' and not ".
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

Map<String, Object?> decode(List<int> pb) {
  final cmd = readVarintField(pb, 1, -1);
  final out = <String, Object?>{
    'cmd': cmd,
    'name': cmdNames[cmd] ?? 'cmd=$cmd',
    'magic': readVarintField(pb, 2, -1),
    'enable': null,
    'auto_display': null,
    'disp_time': null,
    'dnd': null,
    'app_id': null,
    'display_name': null,
    'resp_cmd': null,
    'whitelist_disable': null,
    'whitelist_crc': null,
    'check_status': null,
    'error': 0,
  };
  var label = out['name'] as String;
  int orErr(int v) => v != 0 ? v : out['error'] as int;

  final ctrl = readBytesField(pb, fieldCtrl);
  if (ctrl != null) {
    out['enable'] = readVarintField(ctrl, 1, 0);
    out['auto_display'] = readVarintField(ctrl, 2, 0);
    out['disp_time'] = readVarintField(ctrl, 3, 0);
    out['dnd'] = readVarintField(ctrl, 5, 0);
    out['error'] = readVarintField(ctrl, 4, 0);
    label += ' ctrl enable=${out['enable']} dispTime=${out['disp_time']}';
  }
  final ios = readBytesField(pb, fieldIos);
  if (ios != null) {
    out['app_id'] = readStringField(ios, 1, '');
    out['display_name'] = readStringField(ios, 2, '');
    out['error'] = orErr(readVarintField(ios, 3, 0));
    label += ' ios ${_pyRepr(out['app_id'] as String)}';
  }
  final resp = readBytesField(pb, fieldResp);
  if (resp != null) {
    out['resp_cmd'] = readVarintField(resp, 1, 0);
    out['error'] = orErr(readVarintField(resp, 2, 0));
    label += ' resp cmd=${out['resp_cmd']}';
  }
  final wlc = readBytesField(pb, fieldWhitelistCtrl);
  if (wlc != null) {
    out['whitelist_disable'] = readVarintField(wlc, 1, 0);
    out['error'] = orErr(readVarintField(wlc, 2, 0));
    label += ' whitelistDisable=${out['whitelist_disable']}';
  }
  final wlk = readBytesField(pb, fieldWhitelistChk);
  if (wlk != null) {
    out['whitelist_crc'] = readVarintField(wlk, 1, 0);
    out['check_status'] = readVarintField(wlk, 2, 0);
    out['error'] = orErr(readVarintField(wlk, 3, 0));
    final cs = out['check_status'] as int;
    label += ' whitelistChk ${wlCheckNames[cs] ?? cs}';
  }
  final err = out['error'] as int;
  if (err != 0) label += ' error=${errorNames[err] ?? err}';
  out['label'] = label;
  return out;
}
