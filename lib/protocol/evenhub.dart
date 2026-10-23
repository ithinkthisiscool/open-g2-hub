/// EvenHub (SID 0xE0): session heartbeat, prelude, text/list pages, mic/IMU control, device
/// events; plus the SID 0x09 settings query used for battery read-back.
/// Port of g2/widgets/evenhub.py.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'framing.dart';
import 'limits.dart' as lim;
import 'pb.dart';

const int sidAppLaunch = 0x01;
const int sidEvenHubCh = 0xE0;
const int sidUiSetting = 0x09;
const int preludeAckMagic = 156;
const int defaultWidgetId = 10000;

const int cmdUpdateImage = 3, fieldUpdateImage = 5;
const int cmdImageAck = 4, fieldImageAck = 6;
const int cmdRebuildPage = 7, fieldRebuildPage = 7;
const int cmdRebuildAck = 8, fieldRebuildAck = 8;
const int cmdMenuStartup = 17, fieldMenuStartup = 20;
const int cmdMenuItemClick = 21, fieldMenuItemClick = 24;
const int cmdMenuSubitemSwitch = 22, fieldMenuSubitemSwitch = 25;

const int eventClick = 0;
const int eventDoubleClick = 3;
const int eventLongPress = 9;
const int eventLongPressRelease = 10;
const Map<int, String> eventNames = {
  0: 'CLICK',
  1: 'SCROLL_TOP',
  2: 'SCROLL_BOTTOM',
  3: 'DOUBLE_CLICK',
  4: 'FOREGROUND_ENTER',
  5: 'FOREGROUND_EXIT',
  6: 'ABNORMAL_EXIT',
  7: 'SYSTEM_EXIT',
  8: 'IMU_DATA_REPORT',
  9: 'LONG_PRESS',
  10: 'LONG_PRESS_RELEASE',
};

/// `{1: cmd, 2: magic, <field>: inner}`.
Uint8List wrapEvenHub(int cmd, int magic, int innerField, List<int> inner) =>
    cat([encodeVarintField(1, cmd), encodeVarintField(2, magic), encodeMessageField(innerField, inner)]);

Uint8List encodeTextObject(String name, int containerId, int x, int y, int width, int height,
    String text, bool captureEvents,
    {int borderWidth = 0, int borderColor = 0, int borderRadius = 0, int padding = 0}) {
  final p = Pb().varint(1, x).varint(2, y).varint(3, width).varint(4, height);
  if (borderWidth != 0) p.varint(5, borderWidth);
  if (borderColor != 0) p.varint(6, borderColor);
  if (borderRadius != 0) p.varint(7, borderRadius);
  if (padding != 0) p.varint(8, padding);
  p.varint(9, containerId).string(10, lim.utf8Fit(name, lim.evenhubNameMaxBytes));
  if (captureEvents) p.varint(11, 1);
  p.string(12, lim.utf8Fit(text, lim.evenhubTextMaxBytes));
  return p.toBytes();
}

/// cmd 0 CreateStartUpPage: one full-screen text container "dashboard" (id 1). LIVE.
Uint8List buildCreateInputPage(int magic, [String text = 'dashboard']) {
  final inner = Pb()
      .varint(1, 1)
      .message(3, encodeTextObject('dashboard', 1, 0, 0, 576, 288, text, true))
      .varint(5, 10000);
  return wrapEvenHub(0, magic, 3, inner.toBytes());
}

/// cmd 5 text upgrade: replace the text of an existing text container. LIVE.
Uint8List buildTextUpgrade(int magic, int containerId, String containerName, String text) {
  final name = lim.utf8Fit(containerName, lim.evenhubNameMaxBytes);
  final t = lim.utf8Fit(text, lim.evenhubTextUpgradeMaxBytes);
  final inner = Pb()
      .varint(1, containerId)
      .string(2, name)
      .varint(3, 0)
      .varint(4, utf8.encode(t).length)
      .string(5, t);
  return wrapEvenHub(5, magic, 9, inner.toBytes());
}

/// SID 0x09 read request whose ack carries battery / charging / firmware. LIVE.
Uint8List buildSettingsQuery(int magic) =>
    cat([encodeVarintField(1, 2), encodeVarintField(2, magic), encodeMessageField(4, encodeVarintField(1, 1))]);

Map<String, Object?>? parseSettingsBattery(List<int> pb) {
  final request = readBytesField(pb, 4);
  if (request == null) return null;
  final battery = readVarintField(request, 12, -1);
  if (battery < 0) return null;
  return {
    'battery': battery,
    'charging': readVarintField(request, 13, -1),
    'silent_mode': readVarintField(request, 14, -1),
  };
}

Map<String, Object?>? parseSettingsFirmware(List<int> pb) {
  final request = readBytesField(pb, 4);
  if (request == null) return null;
  final left = readStringField(request, 5);
  final right = readStringField(request, 6);
  if (left.isEmpty && right.isEmpty) return null;
  return {'left_version': left, 'right_version': right};
}

Uint8List encodeListItemContainer(List<String> items) {
  lim.checkCount('EvenHub list items', items.length, lim.evenhubListMaxItems);
  final p = Pb().varint(1, items.length).varint(3, 1);
  for (final item in items) {
    p.string(4, lim.utf8Fit(item, lim.evenhubListItemMaxBytes));
  }
  return p.toBytes();
}

Uint8List encodeListObject(String name, int containerId, int x, int y, int width, int height,
    List<String> items, bool captureEvents,
    {int borderWidth = 0, int borderColor = 0, int borderRadius = 0, int padding = 0}) {
  final p = Pb().varint(1, x).varint(2, y).varint(3, width).varint(4, height);
  if (borderWidth != 0) p.varint(5, borderWidth);
  if (borderColor != 0) p.varint(6, borderColor);
  if (borderRadius != 0) p.varint(7, borderRadius);
  if (padding != 0) p.varint(8, padding);
  p.varint(9, containerId).string(10, lim.utf8Fit(name, lim.evenhubNameMaxBytes));
  p.message(11, encodeListItemContainer(items));
  if (captureEvents) p.varint(12, 1);
  return p.toBytes();
}

Uint8List buildCreatePromptPage(int magic, String textName, int textContainerId, String warningText,
    String listName, int listContainerId, List<String> items) {
  final inner = Pb()
      .varint(1, 2)
      .message(2, encodeListObject(listName, listContainerId, 0, 150, 280, 120, items, true))
      .message(3, encodeTextObject(textName, textContainerId, 0, 0, 280, 130, warningText, false))
      .varint(5, 10000);
  return wrapEvenHub(0, magic, 3, inner.toBytes());
}

/// Session prelude {1: 2, 2: 156, 4: {3: {2: {2: {1: 0, 2: 0}}}}} sent on SID 0x01 after auth.
Uint8List buildPreludePayload() {
  final f4 = encodeMessageField(
      3, encodeMessageField(2, encodeMessageField(2, cat([encodeVarintField(1, 0), encodeVarintField(2, 0)]))));
  return cat([encodeVarintField(1, 2), encodeVarintField(2, preludeAckMagic), encodeMessageField(4, f4)]);
}

final Uint8List preludePayload = buildPreludePayload();

/// The ready-made prelude frame (SID 0x01, flag 0x20, fixed seq 0x92).
final Uint8List preludeFrame = framePb(preludePayload, sidAppLaunch, flagRequest, 0x92)[0];

/// EvenHub heartbeat wrapEvenHub(12, magic, 14, {1: 0}); every ~4 s while SID 0x01 pushes
/// must be accepted. LIVE.
Uint8List buildHeartbeat(int magic) => wrapEvenHub(12, magic, 14, encodeVarintField(1, 0));

Uint8List buildAudioControl(int magic, bool enable) =>
    wrapEvenHub(15, magic, 18, encodeVarintField(1, enable ? 1 : 0));

Uint8List buildImuControl(int magic, bool enable, [int reportFreq = 500]) {
  final p = Pb().varint(1, enable ? 1 : 0);
  if (enable && reportFreq > 0) p.varint(2, reportFreq);
  return wrapEvenHub(19, magic, 22, p.toBytes());
}

Map<String, Object?> _eventFields(int eventType) => {
      'event_type': eventType,
      'event_name': eventNames[eventType] ?? 'event=$eventType',
      'long_press': eventType == eventLongPress || eventType == eventLongPressRelease,
    };

/// Decode an async EvenHub notification (clicks, IMU, menu events) or null.
Map<String, Object?>? decodeDeviceEvent(List<int> pb) {
  final deviceEvent = readBytesField(pb, 13);
  if (deviceEvent == null) {
    final startup = readBytesField(pb, fieldMenuStartup);
    if (startup != null) return {'type': 'menu-startup', 'widget_id': readVarintField(startup, 1, 0)};
    final click = readBytesField(pb, fieldMenuItemClick);
    if (click != null) return {'type': 'menu-item-click', 'item_id': readVarintField(click, 1, 0)};
    final sw = readBytesField(pb, fieldMenuSubitemSwitch);
    if (sw != null) {
      return {
        'type': 'menu-subitem-switch',
        'parent_item_id': readVarintField(sw, 1, 0),
        'sub_item_id': readVarintField(sw, 2, 0),
        'sub_item_index': readVarintField(sw, 3, 0),
      };
    }
    return null;
  }
  final listEvent = readBytesField(deviceEvent, 1);
  if (listEvent != null) {
    return {
      'type': 'list-click',
      'container_id': readVarintField(listEvent, 1, 0),
      'container_name': readStringField(listEvent, 2),
      'item_name': readStringField(listEvent, 3),
      'item_index': readVarintField(listEvent, 4, 0),
      ..._eventFields(readVarintField(listEvent, 5, 0)),
    };
  }
  final textEvent = readBytesField(deviceEvent, 2);
  if (textEvent != null) {
    return {
      'type': 'text-click',
      'container_id': readVarintField(textEvent, 1, 0),
      'container_name': readStringField(textEvent, 2),
      ..._eventFields(readVarintField(textEvent, 3, 0)),
    };
  }
  final sys = readBytesField(deviceEvent, 3);
  if (sys != null) {
    final r = <String, Object?>{
      'type': 'sys-event',
      ..._eventFields(readVarintField(sys, 1, 0)),
      'event_source': readVarintField(sys, 2, 0),
      'exit_reason': readVarintField(sys, 4, 0),
      'widget_id': readVarintField(sys, 5, 0),
      'session_id': readVarintField(sys, 6, 0),
    };
    final imu = readBytesField(sys, 3);
    if (imu != null) {
      r['imu'] = {'x': readFloatField(imu, 1), 'y': readFloatField(imu, 2), 'z': readFloatField(imu, 3)};
    }
    return r;
  }
  return null;
}

/// Result of a cmd 8 rebuild ack or cmd 4 image ack, else null.
Map<String, Object?>? decodePageAck(List<int> pb) {
  final cmd = readVarintField(pb, 1, 0);
  if (cmd == cmdRebuildAck) {
    final sub = readBytesField(pb, fieldRebuildAck);
    if (sub != null) {
      final code = readVarintField(sub, 1, 0);
      return {'cmd': cmd, 'result': code, 'ok': code == 6};
    }
  }
  if (cmd == cmdImageAck) {
    final sub = readBytesField(pb, fieldImageAck);
    if (sub != null) {
      final code = readVarintField(sub, 8, 0);
      return {
        'cmd': cmd,
        'result': code,
        'ok': code == 4,
        'map_session_id': readVarintField(sub, 3, 0),
        'fragment_index': readVarintField(sub, 6, 0),
      };
    }
  }
  return null;
}

// ── multi-container pages and image containers (UNTESTED LIVE in the Python library too) ──

/// EXPERIMENTAL cmd 0 page with one optional list + several text containers.
Uint8List buildCreateDashboardPage(int magic, List<int>? listObjectBytes, List<List<int>> textObjectsBytes) {
  final total = textObjectsBytes.length + (listObjectBytes != null && listObjectBytes.isNotEmpty ? 1 : 0);
  final p = Pb().varint(1, total);
  if (listObjectBytes != null && listObjectBytes.isNotEmpty) p.message(2, listObjectBytes);
  for (final t in textObjectsBytes) {
    p.message(3, t);
  }
  p.varint(5, 10000);
  return wrapEvenHub(0, magic, 3, p.toBytes());
}

/// cmd 7 REBUILD_PAGE, envelope field 7 {1 total, 2 list, 3 text[], 4 image[]}.
Uint8List buildRebuildPage(int magic, List<int>? listObjectBytes, List<List<int>> textObjectsBytes,
    [List<List<int>>? imageObjectsBytes]) {
  final images = imageObjectsBytes ?? const <List<int>>[];
  final hasList = listObjectBytes != null && listObjectBytes.isNotEmpty;
  final p = Pb().varint(1, textObjectsBytes.length + images.length + (hasList ? 1 : 0));
  if (hasList) p.message(2, listObjectBytes);
  for (final t in textObjectsBytes) {
    p.message(3, t);
  }
  for (final i in images) {
    p.message(4, i);
  }
  return wrapEvenHub(cmdRebuildPage, magic, fieldRebuildPage, p.toBytes());
}

/// ImageContainerProperty {1 x, 2 y, 3 w, 4 h, 5 id, 6 name, 7 zOrder (only when given)}.
Uint8List encodeImageObject(String name, int containerId, int x, int y, int width, int height, {int? zOrder}) {
  final p = Pb().varint(1, x).varint(2, y).varint(3, width).varint(4, height).varint(5, containerId);
  p.string(6, lim.utf8Fit(name, lim.evenhubNameMaxBytes));
  if (zOrder != null) p.varint(7, zOrder);
  return p.toBytes();
}

/// cmd 0 page with a single image container (1 total, 4 image, 5 widgetId, 7 sessionId?).
Uint8List buildCreateImagePage(int magic, String name, int containerId, int x, int y, int width, int height,
    {int widgetId = defaultWidgetId, int? sessionId}) {
  final p = Pb().varint(1, 1).message(4, encodeImageObject(name, containerId, x, y, width, height)).varint(5, widgetId);
  if (sessionId != null) p.varint(7, sessionId);
  return wrapEvenHub(0, magic, 3, p.toBytes());
}

/// 0-15 grey values, 2 pixels per byte, high nibble = left pixel; odd widths pad each row.
Uint8List pack4bpp(List<int> pixels, int width, int height) {
  final stride = (width + 1) ~/ 2;
  final out = Uint8List(stride * height);
  for (var row = 0; row < height; row++) {
    for (var col = 0; col < width; col++) {
      final v = pixels[row * width + col] & 0x0F;
      final i = row * stride + col ~/ 2;
      out[i] |= col.isEven ? v << 4 : v;
    }
  }
  return out;
}

/// [packed] (pack4bpp output) wrapped in the 4-bit BMP file the firmware's image container
/// decodes (common_image_set_data 0x4f35ca: 'BM', 4 bpp, size == container, palette at 54,
/// rows padded to 4 bytes, bottom-up). 16-level grey palette. Port of evenhub.encode_bmp_4bpp.
Uint8List encodeBmp4bpp(List<int> packed, int width, int height) {
  final srcStride = (width + 1) ~/ 2;
  if (packed.length != srcStride * height) {
    throw G2ValueError('packed image is ${packed.length} bytes; ${width}x$height at 4 bpp needs ${srcStride * height}');
  }
  final stride = (srcStride + 3) ~/ 4 * 4;
  const off = 14 + 40 + 64;
  final size = off + stride * height;
  final out = Uint8List(size);
  final bd = ByteData.sublistView(out);
  out[0] = 0x42;
  out[1] = 0x4D;
  bd.setUint32(2, size, Endian.little);
  bd.setUint32(10, off, Endian.little);
  bd.setUint32(14, 40, Endian.little);
  bd.setInt32(18, width, Endian.little);
  bd.setInt32(22, height, Endian.little);
  bd.setUint16(26, 1, Endian.little);
  bd.setUint16(28, 4, Endian.little);
  bd.setUint32(34, stride * height, Endian.little);
  bd.setInt32(38, 2835, Endian.little);
  bd.setInt32(42, 2835, Endian.little);
  bd.setUint32(46, 16, Endian.little);
  bd.setUint32(50, 16, Endian.little);
  for (var i = 0; i < 16; i++) {
    out[54 + i * 4] = out[55 + i * 4] = out[56 + i * 4] = 17 * i;
  }
  for (var r = 0; r < height; r++) {
    out.setRange(off + (height - 1 - r) * stride, off + (height - 1 - r) * stride + srcStride,
        packed.sublist(r * srcStride, (r + 1) * srcStride));
  }
  return out;
}

/// cmd 3 UPDATE_IMAGE_RAW_DATA, envelope field 5. Wait for the cmd 4 ack (code 4 = OK).
Uint8List buildImageRawData(int magic, int containerId, String name, int totalSize, int fragmentIndex,
    List<int> fragmentData, {int mapSessionId = 1, int compressMode = 0}) {
  final p = Pb()
      .varint(1, containerId)
      .string(2, lim.utf8Fit(name, lim.evenhubNameMaxBytes))
      .varint(3, mapSessionId)
      .varint(4, totalSize)
      .varint(5, compressMode)
      .varint(6, fragmentIndex)
      .varint(7, fragmentData.length)
      .bytes(8, fragmentData);
  return wrapEvenHub(cmdUpdateImage, magic, fieldUpdateImage, p.toBytes());
}
