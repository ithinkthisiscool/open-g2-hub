/// Quicklist / tasks (SID 0x0c). Port of g2/apps/quicklist.py. The phone owns the list; the
/// glasses only tick tasks done/undone (reported by stable uid) and ask for pages.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'dashboard.dart' show decodeUtf8PrefixIgnore;
import 'pb.dart';

const int sidQuicklistCh = 0x0c;

const int cmdNone = 0, cmdItem = 1, cmdMultItems = 2, cmdEvent = 3;
const int dataTypeUnknown = 0, dataTypeFullUpdate = 1, dataTypeAdd = 2, dataTypeModify = 3, dataTypeDelete = 4;
const int tsTypeDatetime = 0, tsTypeDate = 1, tsTypeTime = 2;
const int titleMaxBytes = 200;
const int maxItemsPerPacket = 20;
const int eventUpdateDataUp = 1, eventUpdateDataDown = 2;

/// Quicklist item tuple (uid, index, is_completed, timestamp_s, title, ts_type).
typedef QuickItem = (int, int, bool, int, String, int);

/// UTF-8 title cut on a code point boundary at <=200 bytes, plus NUL.
Uint8List encodeTitle(String title) {
  final b = utf8.encode(title);
  final cut = b.length > titleMaxBytes ? b.sublist(0, titleMaxBytes) : b;
  return cat([utf8.encode(decodeUtf8PrefixIgnore(cut)), [0]]);
}

Uint8List encodeQuicklistItem(int uid, int index, bool isCompleted, int timestamp, String title,
    [int tsType = tsTypeTime]) {
  final p = Pb().varint(1, uid).varint(2, index).varint(3, isCompleted ? 1 : 0).varint(4, timestamp);
  if (title.isNotEmpty) p.bytes(5, encodeTitle(title));
  p.varint(7, tsType);
  return p.toBytes();
}

Uint8List encodeQuicklistMultItems(List<QuickItem> items, {int dataType = dataTypeFullUpdate, int? totalCount}) {
  final p = Pb().varint(1, dataType).varint(2, totalCount ?? items.length);
  for (final it in items) {
    p.message(3, encodeQuicklistItem(it.$1, it.$2, it.$3, it.$4, it.$5, it.$6));
  }
  return p.toBytes();
}

/// LIVE-CONFIRMED full replacement. Pass at most 20 items (not cut here, like Python).
Uint8List buildQuicklistFullUpdate(List<QuickItem> items, [int magic = 0]) => cat([
      encodeVarintField(1, cmdMultItems),
      encodeVarintField(2, magic),
      encodeMessageField(4, encodeQuicklistMultItems(items, dataType: dataTypeFullUpdate)),
    ]);

/// Answer to a paging EVENT: MULT_ITEMS ADD with <=20 items (cut here).
Uint8List buildQuicklistAddPage(List<QuickItem> items, [int magic = 0]) {
  final page = items.length > maxItemsPerPacket ? items.sublist(0, maxItemsPerPacket) : items;
  return cat([
    encodeVarintField(1, cmdMultItems),
    encodeVarintField(2, magic),
    encodeMessageField(4, encodeQuicklistMultItems(page, dataType: dataTypeAdd)),
  ]);
}

Uint8List buildQuicklistKeepalive([int magic = 0]) => cat([
      encodeVarintField(1, cmdMultItems),
      encodeVarintField(2, magic),
      encodeMessageField(4, encodeQuicklistMultItems(const [], dataType: dataTypeFullUpdate, totalCount: 0)),
    ]);

Map<String, Object?> decodeItem(List<int> raw) {
  final t = readBytesField(raw, 5);
  String? title;
  if (t != null) {
    var end = t.length;
    while (end > 0 && t[end - 1] == 0) {
      end--;
    }
    title = utf8.decode(t.sublist(0, end), allowMalformed: true);
  }
  return {
    'uid': readVarintField(raw, 1, 0),
    'index': readVarintField(raw, 2, 0),
    'completed': readVarintField(raw, 3, 0) != 0,
    'title': title,
  };
}

/// Completion changes made on the glasses (ITEM f3 / MULT_ITEMS f4).
List<Map<String, Object?>> decodeStatusUpdates(List<int> pb) {
  final cmd = readVarintField(pb, 1, -1);
  if (cmd == cmdItem) {
    final raw = readBytesField(pb, 3);
    return raw != null ? [decodeItem(raw)] : [];
  }
  if (cmd == cmdMultItems) {
    final mult = readBytesField(pb, 4);
    if (mult != null) {
      return [
        for (final f in iterFields(mult))
          if (f.number == 3 && f.wire == 2) decodeItem(f.asBytes)
      ];
    }
  }
  return [];
}

/// EVENT (field 5) -> (event, pivotUid), or null.
(int, int)? decodeEvent(List<int> pb) {
  if (readVarintField(pb, 1, -1) != cmdEvent) return null;
  final ev = readBytesField(pb, 5);
  if (ev == null) return null;
  return (readVarintField(ev, 1, 0), readVarintField(ev, 2, 0));
}

/// Up to 20 tasks before (UP) or after (DOWN) the pivot uid; [] for an unknown pivot.
List<T> pageAround<T>(List<T> tasks, int Function(T) uidOf, int event, int pivotUid) {
  final idx = tasks.indexWhere((t) => uidOf(t) == pivotUid);
  if (idx < 0) return [];
  if (event == eventUpdateDataUp) {
    final a = idx - maxItemsPerPacket < 0 ? 0 : idx - maxItemsPerPacket;
    return tasks.sublist(a, idx);
  }
  final a = idx + 1;
  final b = a + maxItemsPerPacket > tasks.length ? tasks.length : a + maxItemsPerPacket;
  return a >= tasks.length ? [] : tasks.sublist(a, b);
}
