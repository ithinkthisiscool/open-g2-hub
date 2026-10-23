/// EvenHub app runtime, protocol half: SDK page JSON → SID 0xE0 protobuf, acks, page rules,
/// glasses events → SDK events, and the glasses menu with installed apps (SID 0x03).
/// Port of g2-hub/hub/evenhub_runtime.py sections 4-7 (byte-exact, see tool/vectors_hub.py).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'evenhub.dart' as eh;
import 'limits.dart' as lim;
import 'menu.dart' as menu;
import 'pb.dart';

const int cmdCreate = 0, cmdCreateAck = 1, cmdEvent = 2, cmdImage = 3, cmdImageAck = 4, cmdText = 5;
const int cmdTextAck = 6, cmdRebuild = 7, cmdRebuildAck = 8, cmdShutdown = 9, cmdShutdownAck = 10;
const int cmdAudio = 15, cmdAudioAck = 16, cmdMenuStartup = 17, cmdMenuStartupFailed = 18, cmdImu = 19;
const int cmdImuAck = 20;
const Map<int, int> field = {
  0: 3, 1: 4, 3: 5, 4: 6, 7: 7, 8: 8, 5: 9, 6: 10, 9: 11, 10: 12, 15: 18, 16: 19, 18: 21, 19: 22, 20: 23, //
};
const Map<int, int> okCode = {1: 0, 4: 4, 8: 6, 6: 8, 10: 10, 16: 13};
const int maxContainers = 12, maxText = 8, maxMenuItems = 10, menuItemNameBytes = 32;
const int screenW = 576, screenH = 288;
const int imageFragmentBytes = 200;
const int imgOk = 0, imgException = 1, imgSizeInvalid = 2, imgSendFailed = 3;

int _int(Object? v) {
  if (v is bool) return v ? 1 : 0;
  if (v is num) return v.toInt();
  if (v is String) return int.parse(v.trim());
  throw ArgumentError('not a number: $v');
}

Uint8List _v(int f, Object? value) => encodeVarintField(f, _int(value));
Uint8List _opt(Map d, String key, int f) => d[key] != null ? _v(f, d[key]) : Uint8List(0);
bool _truthy(Object? v) => v != null && v != false && v != 0 && v != '' && !(v is List && v.isEmpty) && !(v is Map && v.isEmpty);

Uint8List _geometry(Map d) => cat([
      _v(1, d['xPosition'] ?? 0), _v(2, d['yPosition'] ?? 0), _v(3, d['width'] ?? 0), _v(4, d['height'] ?? 0), //
      _opt(d, 'borderWidth', 5), _opt(d, 'borderColor', 6), _opt(d, 'borderRadius', 7), _opt(d, 'paddingLength', 8),
    ]);

String _name(Map d, [String key = 'containerName']) {
  final v = d[key];
  return lim.utf8Fit(_truthy(v) ? v.toString() : '', lim.evenhubNameMaxBytes);
}

String _str(Object? v) => _truthy(v) ? v.toString() : '';

Uint8List encodeTextContainer(Map d) => cat([
      _geometry(d), _v(9, d['containerID'] ?? 0), encodeStringField(10, _name(d)), //
      if (_truthy(d['isEventCapture'])) _v(11, 1),
      encodeStringField(12, lim.utf8Fit(_str(d['content']), lim.evenhubTextMaxBytes)),
      _opt(d, 'zOrderIndex', 13), _opt(d, 'textColor', 14),
    ]);

Uint8List encodeListContainer(Map d) {
  final items = (_truthy(d['itemContainer']) ? d['itemContainer'] as Map : const {});
  final names = [for (final n in (_truthy(items['itemName']) ? items['itemName'] as List : const [])) n.toString()];
  final inner = Pb().add(_v(1, items['itemCount'] ?? names.length));
  if (items['itemWidth'] != null) inner.add(_v(2, items['itemWidth']));
  inner.add(_v(3, items['isItemSelectBorderEn'] ?? 1));
  for (final n in names) {
    inner.string(4, lim.utf8Fit(n, lim.evenhubListItemMaxBytes));
  }
  return cat([
    _geometry(d), _v(9, d['containerID'] ?? 0), encodeStringField(10, _name(d)), //
    encodeMessageField(11, inner.toBytes()),
    if (_truthy(d['isEventCapture'])) _v(12, 1),
    _opt(d, 'zOrderIndex', 13),
  ]);
}

Uint8List encodeImageContainer(Map d) => cat([
      _v(1, d['xPosition'] ?? 0), _v(2, d['yPosition'] ?? 0), _v(3, d['width'] ?? 0), _v(4, d['height'] ?? 0), //
      _v(5, d['containerID'] ?? 0), encodeStringField(6, _name(d)), _opt(d, 'zOrderIndex', 7),
    ]);

Uint8List encodeMenuContainer(Map? d) {
  final items = d == null || !_truthy(d['menuItems']) ? const [] : d['menuItems'] as List;
  return cat([
    for (final item in items.cast<Map>())
      encodeMessageField(1, cat([encodeStringField(1, (item['itemName'] ?? '').toString()), _v(2, item['itemID'] ?? 0)]))
  ]);
}

List<Map> _list(Map d, String k) => _truthy(d[k]) ? (d[k] as List).cast<Map>() : const [];

Uint8List _pageBody(Map d) {
  final lists = _list(d, 'listObject'), texts = _list(d, 'textObject'), images = _list(d, 'imageObject');
  final total = _truthy(d['containerTotalNum']) ? d['containerTotalNum'] : lists.length + texts.length + images.length;
  return cat([
    _v(1, total),
    for (final x in lists) encodeMessageField(2, encodeListContainer(x)),
    for (final x in texts) encodeMessageField(3, encodeTextContainer(x)),
    for (final x in images) encodeMessageField(4, encodeImageContainer(x)),
  ]);
}

bool _hasMenu(Map d) => _truthy(d['menuObject']) && _truthy((d['menuObject'] as Map)['menuItems']);

/// cmd 0 CreateStartUpPageContainer {1 total, 2 list[], 3 text[], 4 image[], 5 widgetId, 6 menu, 7 sessionId}.
Uint8List buildCreatePage(int magic, Map d, {int widgetId = eh.defaultWidgetId, int? sessionId}) {
  final body = cat([
    _pageBody(d), _v(5, widgetId), //
    if (_hasMenu(d)) encodeMessageField(6, encodeMenuContainer(d['menuObject'] as Map)),
    if (sessionId != null) _v(7, sessionId),
  ]);
  return eh.wrapEvenHub(cmdCreate, magic, field[cmdCreate]!, body);
}

/// cmd 7 RebuildPageContainer {1 total, 2 list[], 3 text[], 4 image[], 5 menu}.
Uint8List buildRebuildPage(int magic, Map d) => eh.wrapEvenHub(cmdRebuild, magic, field[cmdRebuild]!,
    cat([_pageBody(d), if (_hasMenu(d)) encodeMessageField(5, encodeMenuContainer(d['menuObject'] as Map))]));

/// cmd 5 TextContainerUpgrade {1 id, 2 name, 3 offset, 4 length, 5 content, 6 color}.
Uint8List buildTextUpgrade(int magic, Map d) {
  final content = lim.utf8Fit(_str(d['content']), lim.evenhubTextUpgradeMaxBytes);
  final length = d['contentLength'] ?? utf8.encode(content).length;
  return eh.wrapEvenHub(
      cmdText,
      magic,
      field[cmdText]!,
      cat([
        _v(1, d['containerID'] ?? 0), encodeStringField(2, _name(d)), _v(3, _truthy(d['contentOffset']) ? d['contentOffset'] : 0), //
        _v(4, length), encodeStringField(5, content), _opt(d, 'textColor', 6),
      ]));
}

/// cmd 9 ShutDownContaniner {1 exitMode}: 0 exit now, 1 ask the user first.
Uint8List buildShutdown(int magic, [int exitMode = 0]) => eh.wrapEvenHub(cmdShutdown, magic, field[cmdShutdown]!, _v(1, exitMode));

/// cmd 18: reply to a cmd 17 launch we cannot serve.
Uint8List buildMenuStartupFailed(int magic, [int errorCode = 1, String errorString = 'app not found']) => eh.wrapEvenHub(
    cmdMenuStartupFailed, magic, field[cmdMenuStartupFailed]!, cat([_v(1, errorCode), encodeStringField(2, errorString)]));

/// Result code of an ack, or null when [pb] is not that ack (absent body/field reads 0).
int? ackCode(List<int>? pb, int ackCmd) {
  if (pb == null || readVarintField(pb, 1, 0) != ackCmd) return null;
  final sub = readBytesField(pb, field[ackCmd]!);
  if (sub == null) return 0;
  return readVarintField(sub, ackCmd == cmdImageAck ? 8 : 1, 0);
}

/// SDK page rules; empty = OK.
List<String> validatePage(Map d) {
  final problems = <String>[];
  final lists = _list(d, 'listObject'), texts = _list(d, 'textObject'), images = _list(d, 'imageObject');
  final containers = [...lists, ...texts, ...images];
  if (containers.isEmpty || containers.length > maxContainers) {
    problems.add('${containers.length} containers (1-$maxContainers allowed)');
  }
  if (texts.length > maxText) problems.add('${texts.length} text containers (max $maxText)');
  final captures = [...lists, ...texts].where((c) => _truthy(c['isEventCapture'])).length;
  if (captures != 1) problems.add('$captures containers with isEventCapture (exactly 1 expected)');
  final ids = [for (final c in containers) c['containerID']];
  if (ids.toSet().length != ids.length) problems.add('duplicate containerID');
  final z = [for (final c in containers) c['zOrderIndex']];
  if (z.any((v) => v != null)) {
    if (z.any((v) => v == null)) {
      problems.add('zOrderIndex set on some containers but not all');
    } else if (z.toSet().length != z.length) {
      problems.add('duplicate zOrderIndex');
    }
  }
  for (final c in lists) {
    final ic = _truthy(c['itemContainer']) ? c['itemContainer'] as Map : const {};
    final n = _truthy(ic['itemName']) ? (ic['itemName'] as List).length : 0;
    if (n > lim.evenhubListMaxItems) problems.add('list container has $n items (firmware max ${lim.evenhubListMaxItems})');
  }
  for (final c in texts) {
    final color = c['textColor'];
    if (color != null) {
      final ci = _int(color);
      if (ci < 0 || ci > 4) problems.add('textColor $color outside 0-4');
    }
  }
  final mo = _truthy(d['menuObject']) ? d['menuObject'] as Map : const {};
  final menuItems = _truthy(mo['menuItems']) ? (mo['menuItems'] as List).cast<Map>() : const <Map>[];
  if (menuItems.length > maxMenuItems) problems.add('${menuItems.length} menu items (max $maxMenuItems)');
  final mids = [for (final m in menuItems) m['itemID']];
  if (mids.any((i) => !_truthy(i)) || mids.toSet().length != mids.length) {
    problems.add('menu itemID must be non-zero and unique');
  }
  if (menuItems.any((m) => utf8.encode((m['itemName'] ?? '').toString()).length > menuItemNameBytes)) {
    problems.add('menu itemName over $menuItemNameBytes UTF-8 bytes');
  }
  return problems;
}

const exitEvents = {5, 6, 7};

/// decodeDeviceEvent() map → the `data` of an evenHubEvent push, or null.
Map<String, Object?>? sdkEvent(Map<String, Object?> event) {
  switch (event['type']) {
    case 'list-click':
      return {
        'type': 'listEvent',
        'jsonData': {
          'containerID': event['container_id'],
          'containerName': event['container_name'],
          'currentSelectItemName': event['item_name'],
          'currentSelectItemIndex': event['item_index'],
          'eventType': event['event_type'],
        }
      };
    case 'text-click':
      return {
        'type': 'textEvent',
        'jsonData': {'containerID': event['container_id'], 'containerName': event['container_name'], 'eventType': event['event_type']}
      };
    case 'sys-event':
      final data = <String, Object?>{'eventType': event['event_type'], 'eventSource': event['event_source'] ?? 0};
      if (event.containsKey('imu')) data['imuData'] = Map<String, Object?>.from(event['imu'] as Map);
      if (_truthy(event['exit_reason'])) data['systemExitReasonCode'] = event['exit_reason'];
      return {'type': 'sysEvent', 'jsonData': data};
    case 'menu-item-click':
      return {
        'type': 'menuItemClickEvent',
        'jsonData': {'itemID': event['item_id']}
      };
  }
  return null;
}

// ── glasses menu with installed apps ──────────────────────────────────────────────────────
const List<int> defaultBuiltins = [1, 4, 5, 6, 7];
const int pluginIconNum = 1;
const int menuNameMax = 31;
final RegExp _ctrl = RegExp(r'[\x00-\x1f\x7f]');

/// The name the official app shows: ≤31 characters, 'custom' if empty.
String menuName(Object? name) {
  final n = (name is String ? name : '').replaceAll(_ctrl, '').trim();
  if (n.isEmpty) return 'custom';
  final r = n.runes.toList();
  return r.length > menuNameMax ? String.fromCharCodes(r.take(menuNameMax)) : n;
}

/// [(itemType, icon, name, appId)]: built-ins first, then apps (name, appId).
List<menu.MenuItemSpec> menuItems(List<int> builtinIds, List<(String, int)> apps) => [
      for (final i in builtinIds) (menu.itemTypeBuiltin, 0, '', i),
      for (final (name, id) in apps) (menu.itemTypePlugin, pluginIconNum, menuName(name), id),
    ];

/// Whole-menu replacement with built-ins ({1:0, 4:id}) and plugins ({1:1,2:1,3:name,4:id}).
Uint8List buildMenuPush(int magic, List<int> builtinIds, List<(String, int)> apps) {
  final items = menuItems(builtinIds, apps);
  if (items.length < menu.menuMinItems || items.length > menu.menuMaxItems) {
    throw G2ValueError('menu needs ${menu.menuMinItems}-${menu.menuMaxItems} items, got ${items.length}');
  }
  final ids = [for (final it in items) it.$4];
  if (ids.toSet().length != ids.length) throw G2ValueError('duplicate itemAppId in menu: $ids');
  final send = Pb().varint(1, items.length);
  for (final (type, icon, name, id) in items) {
    send.message(2, type == menu.itemTypeBuiltin ? menu.encodeBuiltinMenuItem(id) : menu.encodeMenuItem(type, icon, name, id));
  }
  return cat([encodeVarintField(1, menu.cmdAppSendMenuInfo), encodeVarintField(2, magic), encodeMessageField(3, send.toBytes())]);
}

// ── images (EXPERIMENTAL: compress mode and pixel packing are inferred) ──────────────────
const int chartW = 288, chartH = 144;
const int chartX = (screenW - chartW) ~/ 2, chartY = (screenH - chartH) ~/ 2;
const int chartContainerId = 1;
const String chartContainerName = 'stockchart';

/// hub/stock_chart.build_chart_messages: a cmd 0 image page centred on the screen, then the
/// packed 4-bit image in 200-byte cmd 3 fragments (map session 1, raw).
List<Uint8List> imagePushMessages(int Function() magic, Uint8List packed, int width, int height) {
  final out = <Uint8List>[
    eh.buildCreateImagePage(magic(), chartContainerName, chartContainerId, chartX, chartY, width, height),
  ];
  // The firmware decodes a 4-bit BMP file, not raw packed pixels (common_image_set_data).
  final data = eh.encodeBmp4bpp(packed, width, height);
  for (var i = 0, n = 0; i < data.length; i += imageFragmentBytes, n++) {
    final end = i + imageFragmentBytes > data.length ? data.length : i + imageFragmentBytes;
    out.add(eh.buildImageRawData(magic(), chartContainerId, chartContainerName, data.length, n, data.sublist(i, end)));
  }
  return out;
}

/// image_to_gray4 for raw input: already-packed 4-bit (even width) or 8-bit grey; null for
/// encoded images (PNG/JPEG...), which the caller decodes first.
Uint8List? imageToGray4Raw(List<int> data, int width, int height) {
  final area = width * height;
  if (data.length == (area + 1) ~/ 2 && width.isEven) return Uint8List.fromList(data);
  if (data.length == area) return eh.pack4bpp([for (final b in data) b >> 4], width, height);
  return null;
}
