/// Native dashboard (SID 0x01): base settings (init), calendar, news (V3), weather, widget
/// slots. Port of g2/widgets/dashboard.py. Rules (live-confirmed): the EvenHub heartbeat must
/// run for SID 0x01 writes to be accepted; send [buildDashboardInit] once after connecting;
/// stop the heartbeat after a push so the native dashboard shows the new content.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'pb.dart';
import 'pytext.dart';

const int sidDashboardCh = 0x01;

const int cmdNone = 0;
const int cmdDashboardRespond = 1;
const int cmdDashboardReceive = 2;
const int cmdAppRespond = 3;
const int cmdAppReceive = 4;
const int cmdRequestNewsInfo = 5;
const int cmdResponseNewsInfo = 6;
const int cmdAppRequestNewsInfo = 7;
const int cmdDevResponseNewsInfo = 8;
const int cmdAppSendNewsData = 9;
const int cmdDevResponseNewsData = 10;
const int cmdDevRequestNewsUpgrade = 11;
const int cmdDevNotifyNewsEvent = 12;
const int cmdAppRequestClearAllData = 13;
const int cmdDevResponseClearAllData = 14;

const int widgetUnknown = 0;
const int widgetNews = 1;
const int widgetStock = 2;
const int widgetSchedule = 3;
const int widgetQuicklist = 4;
const int widgetHealth = 5;

const int tempUnitUnknown = 0;
const int tempUnitCelsius = 1;
const int tempUnitFahrenheit = 2;

/// WeatherType enum values with the hub's display names (g2-hub weather.WEATHER_TYPES).
const List<String> weatherTypeNames = [
  'Unknown', 'Sunny', 'Cloudy', 'Drizzle', 'Heavy drizzle', 'Rain', 'Heavy rain', 'Thunderstorm', //
  'Thunder', 'Snow', 'Mist', 'Fog', 'Dust', 'Squalls', 'Tornado', 'Freezing rain', 'Clear night',
];

Uint8List encodeDashboardDisplaySetting(List<int> widgetDisplayOrder,
    {List<int>? statusDisplayOrder, int displayMode = 0, int halfDayFormat = 0, int temperatureUnit = 0}) {
  final status = statusDisplayOrder ?? const <int>[];
  final p = Pb().varint(1, displayMode).varint(2, status.length);
  if (status.isNotEmpty) p.add(encodePackedVarintField(3, status));
  p.varint(4, widgetDisplayOrder.length);
  if (widgetDisplayOrder.isNotEmpty) p.add(encodePackedVarintField(5, widgetDisplayOrder));
  p.varint(6, halfDayFormat).varint(7, temperatureUnit);
  return p.toBytes();
}

Uint8List encodeSchedule(int scheduleId, String title, String location, String timeStr, int endTimestamp) {
  final p = Pb().varint(1, scheduleId);
  if (title.isNotEmpty) p.string(2, title);
  if (location.isNotEmpty) p.string(3, location);
  if (timeStr.isNotEmpty) p.string(4, timeStr);
  p.varint(5, endTimestamp);
  return p.toBytes();
}

Uint8List encodeScheduleWidget(List<Uint8List> schedules,
    {int? scheduleTotal, int startIndex = 0, int scheduleAuthority = 0}) {
  final p = Pb().varint(1, scheduleTotal ?? schedules.length).varint(2, startIndex);
  for (final s in schedules) {
    p.message(3, s);
  }
  p.varint(4, scheduleAuthority);
  return p.toBytes();
}

Uint8List encodeWidgetComponentSchedule(List<int> w) => encodeMessageField(3, w);
Uint8List encodeDashboardContentWidget(List<int> w) => encodeMessageField(2, w);

Uint8List encodeDashboardReceiveFromApp(int? packageId, List<int> content, [List<int>? displaySetting]) {
  final p = Pb();
  if (packageId != null) p.varint(1, packageId);
  if (displaySetting != null) p.message(2, displaySetting);
  p.message(3, content);
  return p.toBytes();
}

Uint8List encodeDashboardDataPackage(int commandId, int magic, [List<int>? receive]) {
  final p = Pb().varint(1, commandId).varint(2, magic);
  if (receive != null) p.message(4, receive);
  return p.toBytes();
}

Uint8List encodeNews(int newsId, String title, int reportTime, String source, String content) {
  final p = Pb().varint(1, newsId);
  if (title.isNotEmpty) p.string(2, title);
  p.varint(3, reportTime);
  if (source.isNotEmpty) p.string(4, source);
  if (content.isNotEmpty) p.string(5, content);
  return p.toBytes();
}

Uint8List encodeNewsWidget(List<Uint8List> items, {int? newsTotal, int startIndex = 0, int forceUpgrade = 0}) {
  final p = Pb().varint(1, newsTotal ?? items.length).varint(2, startIndex);
  for (final n in items) {
    p.message(3, n);
  }
  p.varint(4, forceUpgrade);
  return p.toBytes();
}

Uint8List encodeWidgetComponentNews(List<int> w) => encodeMessageField(1, w);

/// rWeatherStatus. [temperature] is a protobuf FLOAT, always Celsius; [unit] only selects the
/// display. updateTime is epoch MILLISECONDS. Strings are cut to 32 characters like the app.
Uint8List encodeWeatherStatus(double temperature,
    {int unit = tempUnitCelsius,
    int weatherType = 0,
    int updateTime = 0,
    String statusString = '',
    int rainfallIcon = 0,
    String rainfallHint = '',
    int sunsetSelect = 0,
    String sunsetHint = ''}) {
  final p = Pb().float32(1, temperature).varint(2, unit).varint(3, weatherType).varint(4, updateTime);
  if (statusString.isNotEmpty) p.string(5, pyHead(statusString, 32));
  p.varint(6, rainfallIcon);
  if (rainfallHint.isNotEmpty) p.string(7, pyHead(rainfallHint, 32));
  p.varint(8, sunsetSelect);
  if (sunsetHint.isNotEmpty) p.string(9, pyHead(sunsetHint, 32));
  return p.toBytes();
}

Uint8List encodeStatusComponentWeather(List<int> w) => encodeMessageField(1, w);
Uint8List encodeDashboardContentStatus(List<int> s) => encodeMessageField(1, s);

/// News item tuple (news_id, title, report_time, source, content) for the V2 path.
typedef NewsItem = (int, String, int, String, String);

/// V2 news push — CONFIRMED NOT TO WORK on current firmware; kept for parity.
Uint8List buildNewsPush(int magic, List<NewsItem> items, {int packageId = 1, bool setDisplayOrder = true}) {
  final msgs = items.map((n) => encodeNews(n.$1, n.$2, n.$3, n.$4, n.$5)).toList();
  final content = encodeDashboardContentWidget(encodeWidgetComponentNews(encodeNewsWidget(msgs)));
  final ds = setDisplayOrder ? encodeDashboardDisplaySetting([widgetNews]) : null;
  return encodeDashboardDataPackage(cmdDashboardReceive, magic, encodeDashboardReceiveFromApp(packageId, content, ds));
}

Uint8List buildNewsProbe(int magic, int allCount, int reportTime, {int packageId = 1}) {
  final item = encodeVarintField(3, reportTime);
  final widget = cat([encodeVarintField(1, allCount), encodeVarintField(2, 0), encodeMessageField(3, item)]);
  final content = encodeDashboardContentWidget(encodeWidgetComponentNews(widget));
  return encodeDashboardDataPackage(cmdDashboardReceive, magic, encodeDashboardReceiveFromApp(packageId, content));
}

Uint8List buildNewsFifoCountRequest(int magic, [int cmd = 1]) => cat([
      encodeVarintField(1, cmdRequestNewsInfo),
      encodeVarintField(2, magic),
      encodeMessageField(7, encodeVarintField(1, cmd)),
    ]);

Uint8List encodeAppSendNewsData(int sessionId, int sessionStatus, int sessionTotalCount, int sessionNewsIndex,
    int newsId, String title, int reportTime, String source, String content) {
  final p = Pb()
      .varint(1, sessionId)
      .varint(2, sessionStatus)
      .varint(3, sessionTotalCount)
      .varint(4, sessionNewsIndex)
      .varint(5, newsId);
  if (title.isNotEmpty) p.string(6, title);
  p.varint(7, reportTime);
  if (source.isNotEmpty) p.string(8, source);
  if (content.isNotEmpty) p.string(9, content);
  return p.toBytes();
}

/// V3 FIFO count request (cmd 7, field 9). Reply: cmd 8, field 10 -> [newsFifoCount].
Uint8List buildNewsFifoCountRequestV3(int magic) => cat([
      encodeVarintField(1, cmdAppRequestNewsInfo),
      encodeVarintField(2, magic),
      encodeMessageField(9, encodeVarintField(1, 1)),
    ]);

/// Enable widget slots without content (DashboardDisplaySetting only).
Uint8List buildDisplayEnable(int magic, List<int> widgetTypes, {int packageId = 1}) {
  final ds = encodeDashboardDisplaySetting(widgetTypes);
  return encodeDashboardDataPackage(
      cmdDashboardReceive, magic, encodeDashboardReceiveFromApp(packageId, Uint8List(0), ds));
}

Uint8List buildNewsDisplayEnable(int magic, {int packageId = 1}) =>
    buildDisplayEnable(magic, [widgetNews], packageId: packageId);

Uint8List buildQuicklistDisplayEnable(int magic, {int packageId = 1}) =>
    buildDisplayEnable(magic, [widgetQuicklist], packageId: packageId);

/// Base-settings packet, LIVE-CONFIRMED: display_mode 4, status [1,2,3], widgets
/// [NEWS, SCHEDULE, STOCK, STOCK], 12 h clock, Celsius. Send once after connecting.
Uint8List buildDashboardInit(int magic, {int packageId = 1}) {
  final ds = encodeDashboardDisplaySetting(
    [widgetNews, widgetSchedule, widgetStock, widgetStock],
    statusDisplayOrder: [1, 2, 3],
    displayMode: 4,
    halfDayFormat: 1,
    temperatureUnit: tempUnitCelsius,
  );
  return encodeDashboardDataPackage(
      cmdDashboardReceive, magic, encodeDashboardReceiveFromApp(packageId, Uint8List(0), ds));
}

/// Clear the device news FIFO (cmd 13, field 15 {1: 1}).
Uint8List buildNewsReset(int magic) => cat([
      encodeVarintField(1, cmdAppRequestClearAllData),
      encodeVarintField(2, magic),
      encodeMessageField(15, encodeVarintField(1, 1)),
    ]);

/// LIVE-CONFIRMED news push (one article per call). reportTime in MILLISECONDS; newsId = slot.
Uint8List buildNewsPushV3(int magic, int newsId, String title, int reportTime,
    {String source = '',
    String content = '',
    int sessionId = 0,
    int sessionStatus = 0,
    int sessionTotalCount = 1,
    int sessionNewsIndex = 0}) {
  final data = encodeAppSendNewsData(
      sessionId, sessionStatus, sessionTotalCount, sessionNewsIndex, newsId, title, reportTime, source, content);
  return cat([encodeVarintField(1, cmdAppSendNewsData), encodeVarintField(2, magic), encodeMessageField(11, data)]);
}

/// Weather status-bar push. [temperature] whole-degree Celsius (sent as float). packageId unset.
Uint8List buildWeatherPush(int magic, double temperature,
    {int? packageId,
    int unit = tempUnitCelsius,
    int weatherType = 0,
    int updateTime = 0,
    String statusString = '',
    int rainfallIcon = 0,
    String rainfallHint = '',
    int sunsetSelect = 0,
    String sunsetHint = ''}) {
  final w = encodeWeatherStatus(temperature,
      unit: unit,
      weatherType: weatherType,
      updateTime: updateTime,
      statusString: statusString,
      rainfallIcon: rainfallIcon,
      rainfallHint: rainfallHint,
      sunsetSelect: sunsetSelect,
      sunsetHint: sunsetHint);
  final content = encodeDashboardContentStatus(encodeStatusComponentWeather(w));
  return encodeDashboardDataPackage(cmdDashboardReceive, magic, encodeDashboardReceiveFromApp(packageId, content));
}

/// One calendar entry as the app sends it: (title, location, timeStr, endTs).
typedef ScheduleEntry = (String, String, String, int);

/// ONE calendar event per message (scheduleTotal = n, scheduleNum = i). For "no events" pass
/// schedule null, total 0 and authority 1.
Uint8List buildCalendarEventPush(int magic, ScheduleEntry? schedule, int total, int index,
    {int authority = 0, int packageId = 1, bool setDisplayOrder = false}) {
  final w = Pb().varint(1, total).varint(2, index);
  if (schedule != null) {
    final (title, location, timeStr, endTs) = schedule;
    final s = Pb();
    if (title.isNotEmpty) s.string(2, title);
    if (location.isNotEmpty) s.string(3, location);
    if (timeStr.isNotEmpty) s.string(4, timeStr);
    s.varint(5, endTs);
    w.message(3, s.toBytes());
  }
  if (total == 0) w.varint(4, authority);
  final content = encodeDashboardContentWidget(encodeWidgetComponentSchedule(w.toBytes()));
  final ds = setDisplayOrder ? encodeDashboardDisplaySetting([widgetSchedule]) : null;
  return encodeDashboardDataPackage(cmdDashboardReceive, magic, encodeDashboardReceiveFromApp(packageId, content, ds));
}

/// Calendar tuple (schedule_id, title, location, time_str, end_ts) for the multi-event form.
typedef CalendarItem = (int, String, String, String, int);

/// LIVE-CONFIRMED multi-event calendar push in one message.
Uint8List buildCalendarPush(int magic, List<CalendarItem> schedules, {int packageId = 1, bool setDisplayOrder = false}) {
  final msgs = schedules.map((s) => encodeSchedule(s.$1, s.$2, s.$3, s.$4, s.$5)).toList();
  final content = encodeDashboardContentWidget(encodeWidgetComponentSchedule(encodeScheduleWidget(msgs)));
  final ds = setDisplayOrder ? encodeDashboardDisplaySetting([widgetSchedule]) : null;
  return encodeDashboardDataPackage(cmdDashboardReceive, magic, encodeDashboardReceiveFromApp(packageId, content, ds));
}

const int ackSuccess = 0, ackParameterError = 1, ackNewsVersionError = 2;
const Map<int, String> ackFlagNames = {
  0: 'DASHBOARD_RECEIVED_SUCCESS',
  1: 'DASHBOARD_PARAMETER_ERROR',
  2: 'DASHBOARD_NEWS_VERSION_ERROR',
};

/// Result flag of the ack to a Dashboard_Receive push; null when no ack / no field 3.
int? ackFlag(List<int>? pb) {
  if (pb == null) return null;
  final respond = readBytesField(pb, 3);
  if (respond == null) return null;
  return readVarintField(respond, 2, 0);
}

/// Slot count from the V3 FIFO reply (field 10 -> 1); [def] when missing / 0.
int newsFifoCount(List<int>? pb, [int def = 5]) {
  if (pb == null) return def;
  final resp = readBytesField(pb, 10);
  if (resp == null) return def;
  final v = readVarintField(resp, 1, def);
  return v == 0 ? def : v;
}

/// newsStatus of the reply to a V3 news push (field 12 -> 5); null when no reply.
int? newsStatus(List<int>? pb) {
  if (pb == null) return null;
  final resp = readBytesField(pb, 12);
  return resp != null ? readVarintField(resp, 5, 0) : 0;
}

/// Cut [text] so its UTF-8 form fits [maxBytes]: on overflow cut at maxBytes - len(ellipsis)
/// on a character boundary and append the ellipsis.
String limitUtf8(String? text, int maxBytes, [String ellipsis = '...']) {
  final t = text ?? '';
  final raw = utf8.encode(t);
  if (raw.length <= maxBytes) return t;
  var keep = maxBytes - utf8.encode(ellipsis).length;
  if (keep < 0) keep = 0;
  return _decodeIgnore(raw.sublist(0, keep)) + ellipsis;
}

/// Python bytes.decode('utf-8', 'ignore') for a prefix cut of valid UTF-8: drop an incomplete
/// trailing sequence.
String _decodeIgnore(List<int> b) {
  var end = b.length;
  // Walk back over continuation bytes to the lead byte of the last sequence.
  var i = end - 1;
  while (i >= 0 && (b[i] & 0xC0) == 0x80) {
    i--;
  }
  if (i >= 0) {
    final lead = b[i];
    final need = lead < 0x80 ? 1 : (lead >> 5) == 0x6 ? 2 : (lead >> 4) == 0xE ? 3 : 4;
    if (end - i < need) end = i;
  }
  return utf8.decode(b.sublist(0, end), allowMalformed: true);
}

/// Python bytes.decode('utf-8','ignore') of a UTF-8 prefix (exposed for other modules).
String decodeUtf8PrefixIgnore(List<int> b) => _decodeIgnore(b);

/// Base settings with a user-chosen widget order (the hub's init uses [NEWS, SCHEDULE, STOCK,
/// STOCK], display mode 4, status [1,2,3]). EXPERIMENTAL: only the default order is live-confirmed.
Uint8List buildDashboardLayout(int magic, List<int> widgetOrder,
    {int displayMode = 4, int halfDayFormat = 1, int temperatureUnit = tempUnitCelsius, int packageId = 1}) {
  final ds = encodeDashboardDisplaySetting(widgetOrder,
      statusDisplayOrder: [1, 2, 3], displayMode: displayMode, halfDayFormat: halfDayFormat, temperatureUnit: temperatureUnit);
  // Fields 2 (setting) and 3 (content) are one nanopb oneof in the firmware (desc 0x7d262c):
  // a trailing empty content field would replace the setting, so send field 2 only.
  final receive = Pb().varint(1, packageId).message(2, ds).toBytes();
  return encodeDashboardDataPackage(cmdDashboardReceive, magic, receive);
}

/// Field 1 (command id) of any message; 0 when absent.
int readCmd(List<int> pb) => readVarintField(pb, 1, 0);

/// Field 2 (magic) of any message; -1 when absent.
int readMagic(List<int> pb) => readVarintField(pb, 2, -1);
