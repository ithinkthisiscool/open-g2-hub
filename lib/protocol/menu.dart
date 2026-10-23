/// On-glass menu / app launcher (SID 0x03). Port of g2/apps/menu.py. The phone sends the
/// WHOLE list each time; built-in apps carry only their app id (itemType 0).
library;

import 'dart:typed_data';

import 'limits.dart' as lim;
import 'pb.dart';

const int sidMenuCh = 0x03;
const int cmdAppSendMenuInfo = 0;
const int cmdOsResponseMenuInfo = 1;

/// Built-in menu apps (LIVE-CONFIRMED ids), in the order the official app lists them.
const Map<int, String> builtinMenuApps = {
  1: 'Dashboard',
  4: 'Notifications',
  5: 'Translate',
  6: 'Teleprompt',
  7: 'Even AI',
  8: 'Navigate',
  11: 'Conversate',
  48: 'Terminal',
  266: 'Silent mode',
};
const int menuMinItems = 5, menuMaxItems = 10;
const int itemTypeBuiltin = 0, itemTypePlugin = 1;

Uint8List encodeBuiltinMenuItem(int appId) =>
    cat([encodeVarintField(1, itemTypeBuiltin), encodeVarintField(4, appId)]);

/// LIVE-CONFIRMED full menu replacement of built-in apps, in order. The builder (like the
/// Python one) does not enforce 5..10; [validateMenu] does, for the UI.
Uint8List buildBuiltinMenuPush(int magic, List<int> appIds) {
  final send = Pb().varint(1, appIds.length);
  for (final id in appIds) {
    send.message(2, encodeBuiltinMenuItem(id));
  }
  return cat([encodeVarintField(1, cmdAppSendMenuInfo), encodeVarintField(2, magic), encodeMessageField(3, send.toBytes())]);
}

/// Menu item tuple (item_type, icon_num, item_name, item_app_id) for plugin items.
typedef MenuItemSpec = (int, int, String, int);

Uint8List encodeMenuItem(int itemType, int iconNum, String itemName, int itemAppId) {
  final p = Pb().varint(1, itemType).varint(2, iconNum);
  // Firmware itemName is a 32-byte nanopb string: longer fails the whole menu decode.
  final name = itemName.isEmpty ? itemName : lim.utf8Fit(itemName, lim.menuItemNameMaxBytes);
  if (name.isNotEmpty) p.string(3, name);
  p.varint(4, itemAppId);
  return p.toBytes();
}

Uint8List encodeMenuInfoSend(List<MenuItemSpec> items) {
  final p = Pb().varint(1, items.length);
  for (final it in items) {
    p.message(2, encodeMenuItem(it.$1, it.$2, it.$3, it.$4));
  }
  return p.toBytes();
}

Uint8List buildMenuPush(int magic, List<MenuItemSpec> items) => cat([
      encodeVarintField(1, cmdAppSendMenuInfo),
      encodeVarintField(2, magic),
      encodeMessageField(3, encodeMenuInfoSend(items)),
    ]);

/// The app-side rule (5..10 items, built-in ids only, no duplicates). Null when valid.
String? validateMenu(List<int> appIds) {
  final bad = appIds.where((i) => !builtinMenuApps.containsKey(i)).toList();
  if (bad.isNotEmpty) return 'not a menu app: $bad';
  if (appIds.toSet().length != appIds.length) return 'duplicate menu items';
  if (appIds.length < menuMinItems || appIds.length > menuMaxItems) {
    return 'the menu needs $menuMinItems to $menuMaxItems items (has ${appIds.length})';
  }
  return null;
}
