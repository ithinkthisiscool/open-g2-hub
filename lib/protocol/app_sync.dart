/// App sync (SID 0x0d): which on-glasses app is in the foreground. Port of
/// g2/device/app_sync.py.
library;

import 'dart:typed_data';

import 'pb.dart';
import 'sids.dart' as sids;

const int sid = sids.sidAppSync;
const int cmdSubscribe = 0;
const Map<int, String> cmdNames = {cmdSubscribe: 'SUBSCRIBE'};
const int fieldState = 3;

/// SUBSCRIBE {1: 0, 2: magic}: sent once per connect after the dashboard init.
Uint8List buildSubscribe(int magic) => cat([encodeVarintField(1, cmdSubscribe), encodeVarintField(2, magic)]);

/// {cmd, name, magic, foreground, background, foreground_name, background_name, label}.
Map<String, Object?> decode(List<int> pb) {
  final cmd = readVarintField(pb, 1, -1);
  final out = <String, Object?>{
    'cmd': cmd,
    'name': cmdNames[cmd] ?? 'cmd=$cmd',
    'magic': readVarintField(pb, 2, -1),
    'foreground': null,
    'background': null,
    'foreground_name': null,
    'background_name': null,
  };
  var label = out['name'] as String;
  final state = readBytesField(pb, fieldState);
  if (state != null) {
    final bg = readVarintField(state, 1, 0);
    final fg = readVarintField(state, 2, 0);
    out['background'] = bg;
    out['foreground'] = fg;
    out['background_name'] = bg != 0 ? sids.sidName(bg) : 'none';
    out['foreground_name'] = fg != 0 ? sids.sidName(fg) : 'none';
    label += ' foreground=${out['foreground_name']} background=${out['background_name']}';
  }
  out['label'] = label;
  return out;
}
