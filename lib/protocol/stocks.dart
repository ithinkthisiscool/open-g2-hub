/// Stocks card on the native dashboard (SID 0x01, cmd 2): one quote per message.
/// Port of g2/widgets/stocks.py (DECODED; never seen on the glasses).
library;

import 'dart:typed_data';

import 'dashboard.dart' as db;
import 'limits.dart' as lim;
import 'pb.dart';
import 'pytext.dart';

const int sid = db.sidDashboardCh;
const int cmd = db.cmdDashboardReceive;
const int widgetStock = db.widgetStock;
const int displayModeStock = 2;
const int maxCodeChars = 62, maxNameChars = 126;
const int trendFlat = 0, trendUp = 1, trendDown = 2;

/// (dict key, field number, kind) in field order. Kinds: str, float, double, varint.
const List<(String, int, String)> stockFields = [
  ('code', 1, 'str'),
  ('market_suffix', 2, 'str'),
  ('market_cap', 3, 'double'),
  ('change_percent', 4, 'float'),
  ('price', 5, 'float'),
  ('name', 6, 'str'),
  ('day_high', 7, 'float'),
  ('day_low', 8, 'float'),
  ('open', 9, 'float'),
  ('volume', 10, 'varint'),
  ('market_value', 11, 'double'),
  ('pe_ratio', 12, 'float'),
  ('trend', 13, 'varint'),
  ('point_total', 14, 'varint'),
  ('dark_price', 15, 'float'),
];
const int fBrightPrice = 16;

Uint8List encodePackedFloatField(int field, List<num> values) {
  final bd = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    bd.setFloat32(i * 4, values[i].toDouble(), Endian.little);
  }
  return encodeBytesField(field, bd.buffer.asUint8List());
}

/// One Stock message from a map (keys as in [stockFields] plus 'points').
Uint8List buildStock(Map<String, Object?> stock) {
  final s = Map<String, Object?>.from(stock);
  final points = (s['points'] as List?)?.cast<num>();
  if (points != null && points.isNotEmpty && s['point_total'] == null) s['point_total'] = points.length;
  final parts = <List<int>>[];
  for (final (key, field, kind) in stockFields) {
    final v = s[key];
    if (v == null) continue;
    switch (kind) {
      case 'str':
        final limit = key == 'name' ? lim.stockNameMaxBytes : lim.stockCodeMaxBytes;
        parts.add(encodeStringField(field, lim.utf8Fit(pyHead(v.toString(), key == 'name' ? maxNameChars : maxCodeChars), limit)));
      case 'float':
        parts.add(encodeFloatField(field, (v as num).toDouble()));
      case 'double':
        parts.add(encodeDoubleField(field, (v as num).toDouble()));
      default:
        parts.add(encodeVarintField(field, (v as num).toInt()));
    }
  }
  if (points != null && points.isNotEmpty) parts.add(encodePackedFloatField(fBrightPrice, points));
  return cat(parts);
}

Uint8List encodeStockWidget(List<int> stockBytes, int stockTotal, int stockNum) =>
    cat([encodeVarintField(1, stockTotal), encodeVarintField(2, stockNum), encodeMessageField(3, stockBytes)]);

/// Full SID 0x01 payload carrying ONE stock (stockNum 0-based of stockTotal).
Uint8List buildStockPush(int magic, Map<String, Object?> stock, {int stockTotal = 1, int stockNum = 0, int? packageId}) {
  final widget = encodeStockWidget(buildStock(stock), stockTotal, stockNum);
  final content = db.encodeDashboardContentWidget(encodeMessageField(2, widget));
  return db.encodeDashboardDataPackage(cmd, magic, db.encodeDashboardReceiveFromApp(packageId, content));
}

/// Base settings that make the stock card visible (order must contain WIDGET_STOCK).
Uint8List buildStockDisplayEnable(int magic, {List<int>? widgetOrder, int packageId = 1, int displayMode = 4}) {
  final order = widgetOrder ?? [db.widgetNews, db.widgetSchedule, widgetStock, widgetStock];
  if (!order.contains(widgetStock)) {
    throw G2ValueError('widget_order must contain WIDGET_STOCK (2) or the card never shows');
  }
  final setting = db.encodeDashboardDisplaySetting(order,
      statusDisplayOrder: [1, 2, 3], displayMode: displayMode, halfDayFormat: 1, temperatureUnit: db.tempUnitCelsius);
  return db.encodeDashboardDataPackage(cmd, magic, db.encodeDashboardReceiveFromApp(packageId, Uint8List(0), setting));
}
