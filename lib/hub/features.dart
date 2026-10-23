/// Feature flows on top of a connected [G2Session], mirroring the g2-hub routes:
/// weather, calendar, news, tasks, menu (+ EvenHub apps), settings, stocks, health, dashboard
/// layout, notifications (EvenFile), watchface, EvenHub images, and the native Translate /
/// Teleprompter / Navigation apps (hub/native_apps.py).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../ble/lens_ad.dart';
import '../protocol/dashboard.dart' as dash;
import '../protocol/device.dart' as dev;
import '../protocol/evenhub.dart' as eh;
import '../protocol/evenhub_pages.dart' as ehp;
import '../protocol/file_service.dart' as fs;
import '../protocol/health.dart' as health;
import '../protocol/hub_format.dart' as fmt;
import '../protocol/menu.dart' as menu;
import '../protocol/navigation.dart' as nav;
import '../protocol/quicklist.dart' as ql;
import '../protocol/settings.dart' as st;
import '../protocol/stocks.dart' as stocks;
import '../protocol/teleprompter.dart' as tp;
import '../protocol/translate.dart' as tr;
import '../protocol/watchface.dart' as wf;
import 'file_transfer.dart';
import 'glasses_session.dart';
import 'models.dart';

/// Result of a push, for the UI.
class PushResult {
  PushResult(this.ok, this.message);
  final bool ok;
  final String message;
  @override
  String toString() => message;
}

/// Teleprompter position as the glasses report it.
class PrompterState {
  int page = 0;
  int line = 0;
  int totalPages = 0;
  int totalLines = 0;
  bool paused = false;
}

class G2Features {
  G2Features(this.s, {DateTime Function()? clock, fmt.UtcOffsetFn? utcOffset})
      : _clock = clock ?? DateTime.now,
        _off = utcOffset ?? fmt.deviceUtcOffset {
    _sub = s.frames.listen(_onFrame);
  }

  final G2Session s;
  final DateTime Function() _clock;
  final fmt.UtcOffsetFn _off;
  late final StreamSubscription<RxFrame> _sub;

  /// Called when the user ticks a task on the glasses: (uid, completed).
  void Function(int uid, bool completed)? onTaskToggled;

  /// Current task list (used to answer paging requests from the glasses).
  List<fmt.TaskItem> tasks = [];

  /// The glasses asked for fresh news (cmd 11, "scroll down to refresh").
  void Function()? onNewsRefreshRequested;

  /// EvenHub device events (clicks, menu launches, exits) for the app runtime.
  final _ehEvents = StreamController<Map<String, Object?>>.broadcast();
  Stream<Map<String, Object?>> get evenHubEvents => _ehEvents.stream;

  /// Navigation launched from the glasses menu (MENU_STARTUP) / a favorite picked / exited.
  void Function()? onNavMenuStartup;
  void Function(int index, String name)? onNavLocationSelected;
  void Function()? onNavExit;
  void Function(int method)? onNavTransportSwitch;

  /// Teleprompter launched from the glasses menu: file list wanted / file chosen.
  List<(String, String)> Function()? teleprompterFiles;
  String? Function(String fileId)? teleprompterFileText;
  final prompter = PrompterState();

  /// Holds the EvenHub heartbeat on (an EvenHub page or image is showing).
  bool holdHeartbeat = false;

  int get _nowS => _clock().millisecondsSinceEpoch ~/ 1000;
  final _qlMagics = <int>[];

  void dispose() {
    _sub.cancel();
    _appHb?.cancel();
    _ehEvents.close();
  }

  // ── dashboard helpers ───────────────────────────────────────────────────────────────────
  /// SID 0x01 is only acked while the EvenHub heartbeat runs: (re)start it and give the
  /// glasses 2 s to see it (hub start_hub_heartbeat + sleep 2).
  Future<void> _ensureHeartbeat() async {
    if (s.startHeartbeat()) {
      s.log('Restarting EvenHub heartbeat for SID=0x01 activation...');
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  Future<int?> _dashRequest(Uint8List Function(int magic) build, String label, {Duration? timeout}) async {
    final m = s.nextMagic();
    final raw = await s.request(dash.sidDashboardCh, build(m), m, label: label, timeout: timeout ?? const Duration(seconds: 4));
    return dash.ackFlag(raw) ?? (raw == null ? null : -1);
  }

  /// After pushes: stop the heartbeat so the native dashboard takes over (~5 s) and shows them.
  void showDashboard() {
    if (holdHeartbeat) return;
    if (s.stopHeartbeat()) s.log('Heartbeat stopped — native dashboard shows in ~5 s', LogLevel.ok);
  }

  // ── weather (status bar) ────────────────────────────────────────────────────────────────
  /// Live values (c.last, from Open-Meteo) when c.mode is 'auto', else the typed ones.
  Future<PushResult> pushWeather(WeatherConfig c) async {
    await _ensureHeartbeat();
    final unit = c.fahrenheit ? dash.tempUnitFahrenheit : dash.tempUnitCelsius;
    final live = c.mode == 'auto' && c.last['temp_c'] != null;
    final int tempC;
    final int wtype;
    final String status;
    if (live) {
      tempC = (c.last['temp_c'] as num).toInt();
      wtype = (c.last['weather_type'] as num?)?.toInt() ?? 0;
      status = (c.last['status'] ?? '').toString();
    } else {
      (tempC, wtype, status) = fmt.manualWeather(c.tempF, c.weatherType, c.status);
    }
    final flag = await _dashRequest(
        (m) => dash.buildWeatherPush(m, tempC.toDouble(),
            unit: unit,
            weatherType: wtype,
            updateTime: _clock().millisecondsSinceEpoch,
            statusString: status,
            rainfallIcon: live ? (c.last['rain_icon'] as num? ?? 0).toInt() : 0,
            rainfallHint: live ? (c.last['rain_hint'] ?? '').toString() : '',
            sunsetSelect: live ? (c.last['sunset_select'] as num? ?? 0).toInt() : 0,
            sunsetHint: live ? (c.last['sunset_hint'] ?? '').toString() : ''),
        'weather push');
    final ok = flag == 0;
    s.log('Weather → $tempC°C $status (flag=$flag)', ok ? LogLevel.ok : LogLevel.warn);
    return PushResult(ok, ok ? 'Weather sent' : 'Weather: ${flag == null ? 'no ack' : 'flag $flag'}');
  }

  // ── calendar ────────────────────────────────────────────────────────────────────────────
  Future<PushResult> pushCalendar(List<fmt.CalEvent> events, {bool h24 = false}) async {
    await _ensureHeartbeat();
    final schedules = fmt.toSchedules(events, _nowS, h24: h24, off: _off);
    var ok = true;
    final items = schedules.isEmpty ? <dash.ScheduleEntry?>[null] : schedules;
    for (var n = 0; n < items.length; n++) {
      final flag = await _dashRequest(
          (m) => dash.buildCalendarEventPush(m, items[n], schedules.length, n, authority: schedules.isEmpty ? 1 : 0),
          'calendar ${n + 1}/${schedules.length}');
      ok = ok && flag == 0;
    }
    s.log('Calendar → ${schedules.length} event(s)${ok ? ' (all acked)' : ' (some not acked)'}', ok ? LogLevel.ok : LogLevel.warn);
    showDashboard();
    return PushResult(ok, '${schedules.length} event(s) sent${ok ? '' : ' (not all acked)'}');
  }

  // ── news (V3 flow, live-confirmed) ──────────────────────────────────────────────────────
  Future<PushResult> pushNews(List<NewsItem> articles) async {
    if (articles.isEmpty) return PushResult(false, 'No news items');
    await _ensureHeartbeat();
    final mr = s.nextMagic();
    await s.request(dash.sidDashboardCh, dash.buildNewsReset(mr), mr, label: 'news reset');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final mc = s.nextMagic();
    final rawCount = await s.request(dash.sidDashboardCh, dash.buildNewsFifoCountRequestV3(mc), mc,
        label: 'news fifo count', timeout: const Duration(seconds: 4));
    final count = dash.newsFifoCount(rawCount);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    // The app sends local wall-clock milliseconds (UTC ms + the phone's UTC offset).
    final reportTime = (_nowS + _off(_nowS)) * 1000;
    final list = [for (var n = 0; n < count; n++) articles[n % articles.length]];
    final maxContent = list.map((a) => a.content.length).fold(0, (a, b) => a > b ? a : b);
    final t = maxContent > 600 ? 5000 : maxContent > 200 ? 4000 : 2500;
    var allAcked = true;
    for (var idx = 0; idx < count; idx++) {
      final a = list[idx];
      final m = s.nextMagic();
      final raw = await s.request(
          dash.sidDashboardCh,
          dash.buildNewsPushV3(m, idx, a.title, reportTime,
              source: a.source, content: a.content, sessionTotalCount: count, sessionNewsIndex: idx),
          m,
          label: 'news item $idx',
          timeout: Duration(milliseconds: t));
      if (raw == null) allAcked = false;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    showDashboard();
    return PushResult(allAcked, '$count news slot(s) sent${allAcked ? '' : ' (some not acked)'}');
  }

  // ── tasks (quicklist) ───────────────────────────────────────────────────────────────────
  Future<PushResult> pushTasks(List<fmt.TaskItem> list) async {
    final items = list.where((t) => t.title.trim().isNotEmpty).toList();
    tasks = items;
    await _ensureHeartbeat();
    final initFlag = await _dashRequest((m) => dash.buildDashboardInit(m), 'dashboard init');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final q = <ql.QuickItem>[
      for (var n = 0; n < items.length && n < ql.maxItemsPerPacket; n++)
        (items[n].uid!, n, items[n].completed, 0, items[n].title, ql.tsTypeTime)
    ];
    final m = s.nextMagic();
    _qlMagics.add(m);
    if (_qlMagics.length > 64) _qlMagics.removeAt(0);
    final ack = await s.request(ql.sidQuicklistCh, ql.buildQuicklistFullUpdate(q, m), m, label: 'quicklist');
    final flag = await _dashRequest((mm) => dash.buildQuicklistDisplayEnable(mm), 'quicklist display_setting');
    showDashboard();
    final ok = ack != null && flag == 0;
    s.log('Tasks → ${q.length} (init=$initFlag ack=${ack != null} slot=$flag)', ok ? LogLevel.ok : LogLevel.warn);
    return PushResult(ok, '${q.length} task(s) sent${ok ? '' : ' (check log)'}');
  }

  // ── menu (built-ins + installed EvenHub apps) ───────────────────────────────────────────
  Future<PushResult> pushMenu(List<int> appIds, {List<(String, int)> apps = const []}) async {
    if (apps.isEmpty) {
      final err = menu.validateMenu(appIds);
      if (err != null) return PushResult(false, err);
    }
    final m = s.nextMagic();
    final Uint8List payload;
    try {
      payload = apps.isEmpty ? menu.buildBuiltinMenuPush(m, appIds) : ehp.buildMenuPush(m, appIds, apps);
    } catch (e) {
      return PushResult(false, '$e');
    }
    final raw = await s.request(menu.sidMenuCh, payload, m, label: 'menu push', timeout: const Duration(seconds: 4));
    return PushResult(raw != null, raw != null ? 'Menu sent' : 'Menu: no ack');
  }

  // ── settings ────────────────────────────────────────────────────────────────────────────
  /// (sid, payload, label) for each set value, in the hub's order (settings_payloads), then units.
  List<(int, Uint8List, String)> settingsPayloads(GlassesSettings g) {
    final out = <(int, Uint8List, String)>[];
    int m() => s.nextMagic();
    if (g.autoBrightness != null) out.add((st.sidSettings, st.buildAutoBrightness(m(), g.autoBrightness), 'auto brightness'));
    if (g.brightness != null && g.autoBrightness != true) {
      out.add((st.sidSettings, st.buildBrightness(m(), g.brightness), 'brightness ${g.brightness}'));
    }
    if (g.silentMode != null) out.add((st.sidSettings, st.buildSilentMode(m(), g.silentMode), 'silent mode'));
    if (g.wearDetection != null) out.add((st.sidSettings, st.buildWearDetection(m(), g.wearDetection), 'wear detection'));
    if (g.headUp != null) out.add((st.sidSettings, st.buildHeadUp(m(), g.headUp, g.headUpAngle), 'head-up'));
    if (g.displayTimeout != null) {
      out.add((st.sidModule, st.buildDisplayTimeout(m(), g.displayTimeout == 0 ? 'never' : g.displayTimeout), 'display timeout'));
    }
    if (g.language != null) out.add((st.sidModule, st.buildLanguage(m(), g.language), 'language'));
    if (g.time24h != null || g.celsius != null || g.imperial != null) {
      out.add((
        st.sidSettings,
        st.buildUnits(m(),
            distanceUnit: g.imperial == true ? 1 : 0, timeFormat: g.time24h == true ? 0 : 1, temperatureUnit: g.celsius == false ? 2 : 1),
        'units'
      ));
    }
    return out;
  }

  Future<PushResult> applySettings(GlassesSettings g) async {
    final list = settingsPayloads(g);
    for (final (sid, pb, label) in list) {
      await s.sendFramed(sid, pb);
      s.log('Settings → $label');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await s.readSettings();
    return PushResult(true, '${list.length} setting(s) sent');
  }

  /// Battery, wear status, case and screen-off time (hub api_glasses_refresh).
  Future<void> refreshStatus() async {
    for (final (sid, b) in <(int, Uint8List Function(int))>[
      (st.sidSettings, st.buildReadSettings),
      (dev.sidOnboarding, dev.buildWearStatusQuery),
      (dev.sidCase, dev.buildCaseInfoQuery),
      (st.sidModule, st.buildReadDisplayTimeout),
    ]) {
      await s.sendFramed(sid, b(s.nextMagic()));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  /// Reboot (0x80 cmd 15, DECODED; the link drops and the app reconnects).
  Future<PushResult> restartGlasses() async {
    await s.sendFramed(dev.sid, dev.buildQuickRestart(s.nextMagic()));
    return PushResult(true, 'Restarting the glasses — they reconnect by themselves');
  }

  // ── stocks / health / layout (EXPERIMENTAL) ─────────────────────────────────────────────
  Future<PushResult> pushStocks(List<Map<String, Object?>> quotes) async {
    if (quotes.isEmpty) return PushResult(false, 'No quotes');
    await _ensureHeartbeat();
    var ok = true;
    for (var i = 0; i < quotes.length; i++) {
      final flag = await _dashRequest((m) => stocks.buildStockPush(m, quotes[i], stockTotal: quotes.length, stockNum: i),
          'stock ${quotes[i]['code']}');
      ok = ok && flag == 0;
    }
    showDashboard();
    return PushResult(ok, '${quotes.length} stock(s) sent${ok ? '' : ' (not all acked)'}');
  }

  Future<PushResult> pushHealth(Map<String, num> v, {bool showCard = true}) async {
    await _ensureHeartbeat();
    // (No display-enable for the health card: the firmware ignores it.)
    final m = s.nextMagic();
    final raw = await s.request(
        health.sid,
        health.buildDashboardSnapshot(m,
            steps: v['steps'],
            stepGoal: v['step_goal'],
            calories: v['calories'],
            calorieGoal: v['calorie_goal'],
            sleep: v['sleep'],
            sleepMinutes: v['sleep_minutes'],
            heartRate: v['heart_rate'],
            heartRateAvg: v['heart_rate_avg'],
            spo2: v['spo2'],
            spo2Avg: v['spo2_avg']),
        m,
        label: 'health snapshot',
        timeout: const Duration(seconds: 4));
    showDashboard();
    if (raw == null) return PushResult(false, 'Health: no ack (unconfirmed feature)');
    final d = health.decode(raw);
    final err = (d['error'] as int?) ?? 0;
    return PushResult(err == 0, err == 0 ? 'Health sent' : 'Health: error $err');
  }

  Future<PushResult> pushLayout(List<int> order, {required bool h24, required bool celsius}) async {
    await _ensureHeartbeat();
    final flag = await _dashRequest(
        (m) => dash.buildDashboardLayout(m, order, halfDayFormat: h24 ? 0 : 1, temperatureUnit: celsius ? dash.tempUnitCelsius : dash.tempUnitFahrenheit),
        'dashboard layout');
    showDashboard();
    return PushResult(flag == 0, flag == 0 ? 'Layout sent' : 'Layout: ${flag ?? 'no ack'}');
  }

  // ── notifications (SID 0x04 control + EvenFile JSON) ────────────────────────────────────
  Future<PushResult> notificationSetup({int dispTime = 5, bool dnd = false}) async {
    await s.sendFramed(fs.sidNotificationCh, fs.buildNotificationCtrl(s.nextMagic(), dispTime: dispTime, dnd: dnd));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await s.sendFramed(fs.sidNotificationCh, fs.buildWhitelistDisable(s.nextMagic()));
    return PushResult(true, 'Notifications switched on');
  }

  Future<PushResult> sendNotificationFile(Uint8List json) async {
    final (ok, msg) = await sendFile(s, fs.fileTypeNotification, json);
    return PushResult(ok, ok ? 'Notification shown' : 'Notification: $msg');
  }

  // ── EvenHub (pages, images) ─────────────────────────────────────────────────────────────
  Future<Uint8List?> evenHubRequest(Uint8List payload, int magic, {String label = 'evenhub', Duration timeout = const Duration(seconds: 3)}) =>
      s.request(eh.sidEvenHubCh, payload, magic, label: label, timeout: timeout);

  /// Draw a 4-bit grey image (packed) as an EvenHub image page. EXPERIMENTAL.
  Future<PushResult> pushImage(Uint8List packed, int width, int height) async {
    holdHeartbeat = true;
    s.startHeartbeat();
    final msgs = ehp.imagePushMessages(s.nextMagic, packed, width, height);
    final page = await evenHubRequest(msgs.first, readMagic(msgs.first), label: 'image page');
    if (page == null) return PushResult(false, 'The glasses did not acknowledge the image page (experimental)');
    for (final f in msgs.skip(1)) {
      final r = await evenHubRequest(f, readMagic(f), label: 'image fragment');
      if (ehp.ackCode(r, ehp.cmdImageAck) != ehp.okCode[ehp.cmdImageAck]) {
        return PushResult(false, 'The glasses rejected an image fragment (experimental)');
      }
    }
    return PushResult(true, 'Image sent (${packed.length} bytes)');
  }

  /// Leave an EvenHub page/image: let the native dashboard take over again.
  void releaseEvenHub() {
    holdHeartbeat = false;
    showDashboard();
  }

  static int readMagic(Uint8List payload) => dash.readMagic(payload);

  // ── watchface (SID 0x1F, EXPERIMENTAL) ──────────────────────────────────────────────────
  final _wfWaiters = <int, List<Completer<Map<String, Object?>>>>{};

  Future<Map<String, Object?>?> _wfWait(List<int> cmds, {Duration timeout = const Duration(seconds: 6)}) async {
    final c = Completer<Map<String, Object?>>();
    for (final cmd in cmds) {
      _wfWaiters.putIfAbsent(cmd, () => []).add(c);
    }
    try {
      return await c.future.timeout(timeout);
    } on TimeoutException {
      return null;
    } finally {
      for (final cmd in cmds) {
        _wfWaiters[cmd]?.remove(c);
      }
    }
  }

  Future<Map<String, Object?>?> watchfaceInfo() async {
    final w = _wfWait([wf.cmdInfoResponse]);
    await s.send(wf.sid, wf.buildInfoRequest(s.nextMagic()));
    return w;
  }

  /// REQUEST_UPGRADE → TRANSMIT_START → FILE_DATA fragments (each acked) → UPDATE_SUCCESS.
  Future<(bool, List<String>)> watchfaceUpload(Uint8List file) async {
    final steps = <String>[];
    var wait = _wfWait([wf.cmdTransmitStart, wf.cmdUpgradeResponse]);
    await s.send(wf.sid, wf.buildUpgradeRequest(s.nextMagic()));
    var r = await wait;
    if (r == null) return (false, [...steps, 'no answer to the upgrade request']);
    steps.add('${r['name']} ${r['status'] ?? r['value'] ?? ''}');
    if (r['cmd'] == wf.cmdUpgradeResponse) {
      if ((r['status'] as int? ?? 0) != 0) return (false, [...steps, 'glasses refused the upgrade']);
      r = await _wfWait([wf.cmdTransmitStart]);
      if (r == null) return (false, [...steps, 'no TRANSMIT_START']);
      steps.add('TRANSMIT_START');
    }
    final success = _wfWait([wf.cmdUpdateSuccess], timeout: const Duration(seconds: 30));
    final frags = wf.buildFileFragments(s.nextMagic, file);
    for (var i = 0; i < frags.length; i++) {
      wait = _wfWait([wf.cmdFileDataAck]);
      await s.send(wf.sid, frags[i]);
      final ack = await wait;
      if (ack == null || (ack['status'] as int? ?? 0) != 0) return (false, [...steps, 'fragment $i: ${ack ?? 'no ack'}']);
      steps.add('fragment $i acked');
    }
    final done = await success;
    steps.add(done != null ? 'UPDATE_SUCCESS' : 'no UPDATE_SUCCESS');
    return (done != null, steps);
  }

  // ── native apps: translate (text display), teleprompter, navigation ──────────────────────
  String? currentApp;
  Timer? _appHb;
  List<List<String>> _pages = [];
  Completer<Map<String, Object?>>? _commResp;
  Completer<Map<String, Object?>>? _tpResp;
  int _navCounter = 0;

  void _startAppHeartbeat(int sid, Duration every, Uint8List Function(int) build) {
    _appHb?.cancel();
    _appHb = Timer.periodic(every, (_) => s.send(sid, build(s.nextMagic())).catchError((Object _) {}));
  }

  Future<void> closeApp() async {
    final name = currentApp;
    currentApp = null;
    _appHb?.cancel();
    _appHb = null;
    if (name == 'translate') await s.send(tr.sid, tr.buildClose(s.nextMagic()));
    if (name == 'teleprompter') await s.send(tp.sid, tp.buildClose(s.nextMagic()));
    if (name == 'navigation') await s.send(nav.sid, nav.buildStop(s.nextMagic()));
  }

  Future<PushResult> translateOpen(String src, String dst) async {
    if (currentApp != 'translate') await closeApp();
    currentApp = 'translate';
    _commResp = Completer();
    await s.send(tr.sid, tr.buildOpen(s.nextMagic(), src, dst));
    final resp = await _commResp!.future.timeout(const Duration(seconds: 3), onTimeout: () => {});
    final err = resp['error'];
    if (err is int && err != 0) {
      currentApp = null;
      return PushResult(false, 'Translate open rejected (${tr.errorNames[err] ?? err})');
    }
    _startAppHeartbeat(tr.sid, tr.heartbeatInterval, tr.buildHeartbeat);
    return PushResult(true, resp.isEmpty ? 'Translate opened (no reply yet)' : 'Translate opened');
  }

  Future<PushResult> translateText(String src, String dst, {bool finalLine = true}) async {
    if (currentApp != 'translate') {
      final r = await translateOpen('EN', 'ES');
      if (!r.ok) return r;
    }
    _commResp = Completer();
    await s.send(tr.sid, tr.buildText(s.nextMagic(), src, dst, finalLine: finalLine));
    final resp = await _commResp!.future.timeout(const Duration(seconds: 3), onTimeout: () => {});
    return PushResult(resp['error'] == 0 || resp.isEmpty, resp.isEmpty ? 'Text sent (no reply)' : 'Text shown');
  }

  /// Start the teleprompter: byte-aware pages ([charsPerLine] wide), MANUAL or AUTO scroll
  /// ([scrollIntervalMs] per line), optional countdown. START is retried once on a FAIL reply,
  /// like the official app.
  Future<PushResult> teleprompterStart(String script,
      {int mode = tp.modeManual, int scrollIntervalMs = 0, int charsPerLine = tp.charsPerLine, int countdownSeconds = 0, int startPage = 0}) async {
    if (currentApp != null) await closeApp();
    _pages = tp.paginate(script, charsPerLine: charsPerLine);
    if (_pages.isEmpty) return PushResult(false, 'The script is empty');
    currentApp = 'teleprompter';
    final (pages, lines) = tp.totals(_pages);
    prompter
      ..page = startPage
      ..line = 0
      ..totalPages = pages
      ..totalLines = lines
      ..paused = false;
    Map<String, Object?> resp = {};
    for (var attempt = 0; attempt < 2; attempt++) {
      _tpResp = Completer();
      await s.send(tp.sid,
          tp.buildStart(s.nextMagic(), pages, lines, mode: mode, scrollIntervalMs: scrollIntervalMs, countdownSeconds: countdownSeconds, startPage: startPage));
      resp = await _tpResp!.future.timeout(const Duration(seconds: 3), onTimeout: () => {});
      if (resp.isEmpty || (resp['error'] as int? ?? 0) == 0) break;
    }
    if ((resp['error'] as int? ?? 0) != 0) {
      currentApp = null;
      return PushResult(false, 'The glasses rejected the teleprompter (${tp.errorNames[resp['error']] ?? resp['error']})');
    }
    _startAppHeartbeat(tp.sid, tp.heartbeatInterval, (m) => tp.buildHeartbeat(m, pageId: prompter.page, lineId: prompter.line));
    return PushResult(true, 'Teleprompter: $pages page(s), $lines line(s)${resp.isEmpty ? ' (no reply yet)' : ''}');
  }

  Future<void> teleprompterPause() async {
    prompter.paused = true;
    await s.send(tp.sid, tp.buildPause(s.nextMagic()));
  }

  Future<void> teleprompterResume() async {
    prompter.paused = false;
    await s.send(tp.sid, tp.buildResume(s.nextMagic()));
  }

  /// Move the glasses' view (PAGE_SCROLL_SYNC).
  Future<void> teleprompterJump(int page, [int line = 0]) async {
    prompter
      ..page = page
      ..line = line;
    await s.send(tp.sid, tp.buildScrollSync(s.nextMagic(), page, line));
  }

  Future<PushResult> navigationStart() async {
    if (currentApp != 'navigation') await closeApp();
    currentApp = 'navigation';
    _navCounter = 0;
    await s.send(nav.sid, nav.buildStart(s.nextMagic()));
    _startAppHeartbeat(nav.sid, nav.heartbeatInterval, nav.buildHeartbeat);
    return PushResult(true, 'Navigation opened');
  }

  Future<PushResult> navigationStep(String direction,
      {String? distance, String? road, String? remainingTime, String? remainingDistance, String? eta, String? speed, int method = nav.methodWalking}) async {
    if (currentApp != 'navigation') await navigationStart();
    _navCounter++;
    await s.send(
        nav.sid,
        nav.buildBasicInfo(s.nextMagic(), direction,
            distance: distance,
            road: road,
            remainingTime: remainingTime,
            remainingDistance: remainingDistance,
            eta: eta,
            speed: speed,
            method: method,
            counter: _navCounter));
    return PushResult(true, 'Turn sent: $direction ${distance ?? ''} ${road ?? ''}'.trim());
  }

  Future<void> navigationEvent(String kind) =>
      s.send(nav.sid, kind == 'arrive' ? nav.buildArrive(s.nextMagic()) : nav.buildRecalculating(s.nextMagic()));

  Future<void> navigationFavorites(List<String> names) => s.send(
      nav.sid, names.isEmpty ? nav.buildLocationNone(s.nextMagic()) : nav.buildLocationList(s.nextMagic(), names.take(20).toList()));

  Future<void> navigationError(String message) => s.send(nav.sid, nav.buildErrorInfo(s.nextMagic(), message));

  // ── incoming ────────────────────────────────────────────────────────────────────────────
  DateTime _lastNewsRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  void _onFrame(RxFrame f) {
    if (f.side != LensSide.right) return;
    switch (f.sid) {
      case dash.sidDashboardCh:
        final cmd = dash.readCmd(f.payload);
        if (cmd == dash.cmdDevRequestNewsUpgrade) {
          final now = _clock();
          if (now.difference(_lastNewsRefresh) > const Duration(seconds: 30)) {
            _lastNewsRefresh = now;
            s.log('News widget: the glasses asked for fresh news', LogLevel.ok);
            onNewsRefreshRequested?.call();
          }
        }
      case ql.sidQuicklistCh:
        final magic = dash.readMagic(f.payload);
        if (_qlMagics.contains(magic)) return; // the ack of our own push, not a tick
        for (final u in ql.decodeStatusUpdates(f.payload)) {
          onTaskToggled?.call(u['uid'] as int, u['completed'] as bool);
        }
        final ev = ql.decodeEvent(f.payload);
        if (ev != null) {
          final (event, pivot) = ev;
          final page = ql.pageAround<fmt.TaskItem>(tasks, (t) => t.uid ?? -1, event, pivot);
          final items = <ql.QuickItem>[
            for (final t in page) (t.uid!, tasks.indexOf(t), t.completed, 0, t.title, ql.tsTypeTime)
          ];
          final m = s.nextMagic();
          _qlMagics.add(m);
          _reply(s.send(ql.sidQuicklistCh, ql.buildQuicklistAddPage(items, m)));
        }
      case tr.sid:
        final msg = tr.decode(f.payload);
        if (msg['cmd'] == tr.cmdCommResp && _commResp != null && !_commResp!.isCompleted) _commResp!.complete(msg);
        if (msg['cmd'] == tr.cmdLangSwitchReq) _reply(s.send(tr.sid, tr.buildLangSwitchResponse(s.nextMagic())));
        if (msg['cmd'] == tr.cmdNotify && msg['value'] == tr.tcmdClose) _ended('translate');
      case tp.sid:
        _onTeleprompter(tp.decode(f.payload));
      case nav.sid:
        final msg = nav.decode(f.payload);
        if (msg['cmd'] == nav.cmdMenuStartup) {
          onNavMenuStartup?.call();
        } else if (msg['cmd'] == nav.cmdLocationSelected) {
          onNavLocationSelected?.call(msg['value'] as int? ?? 0, (msg['location'] ?? '') as String);
        } else if (msg['cmd'] == nav.cmdSwitchTransportReq) {
          _reply(s.send(nav.sid, nav.buildSwitchTransportResponse(s.nextMagic())));
          onNavTransportSwitch?.call(msg['method'] as int? ?? nav.methodWalking);
        } else if (nav.isExit(msg)) {
          _ended('navigation');
          onNavExit?.call();
        }
      case eh.sidEvenHubCh:
        final ev = eh.decodeDeviceEvent(f.payload);
        if (ev != null && !_ehEvents.isClosed) _ehEvents.add(ev);
      case wf.sid:
        final d = wf.decode(f.payload)..remove('data');
        s.log('Watchface ← ${d['name']}');
        for (final c in [...?_wfWaiters[d['cmd'] as int]]) {
          if (!c.isCompleted) c.complete(d);
        }
    }
  }

  void _onTeleprompter(Map<String, Object?> msg) {
    final cmd = msg['cmd'];
    if (cmd == tp.cmdPageDataRequest && msg['page'] != null) {
      final id = msg['page'] as int;
      if (id >= 0 && id < _pages.length) {
        _reply(s.send(tp.sid, tp.buildPage(s.nextMagic(), id, _pages[id])));
      } else {
        s.log('Teleprompter: glasses asked for page $id, script has ${_pages.length}', LogLevel.warn);
      }
    } else if (cmd == tp.cmdCommResp) {
      if (_tpResp != null && !_tpResp!.isCompleted) _tpResp!.complete(msg);
    } else if (cmd == tp.cmdPageScrollSync || cmd == tp.cmdHeartbeat) {
      prompter
        ..page = msg['page'] as int? ?? prompter.page
        ..line = msg['line'] as int? ?? prompter.line;
    } else if (cmd == tp.cmdModeSwitchReq) {
      _reply(s.send(tp.sid, tp.buildModeSwitchResponse(s.nextMagic())));
    } else if (cmd == tp.cmdFileListRequest) {
      // Opened from the glasses menu: offer the saved scripts.
      final files = teleprompterFiles?.call() ?? const [];
      _reply(s.send(tp.sid, tp.buildFileList(s.nextMagic(), [for (final (id, name) in files) (id, name)])));
    } else if (cmd == tp.cmdFileSelect) {
      final id = utf8.decode((msg['file_id'] as List<int>?) ?? const [], allowMalformed: true);
      final text = teleprompterFileText?.call(id);
      if (text != null) _reply(teleprompterStart(text));
    } else if (tp.isClose(msg)) {
      _ended('teleprompter');
    }
  }

  /// A reply / follow-up the glasses asked for, sent without waiting. If the link just dropped,
  /// the failed write is logged instead of becoming an uncaught error.
  void _reply(Future<Object?> f) => unawaited(f.then<void>((_) {}, onError: (Object e) => s.log('Reply to the glasses not sent: $e', LogLevel.warn)));

  void _ended(String name) {
    if (currentApp == name) {
      currentApp = null;
      _appHb?.cancel();
      _appHb = null;
      s.log('$name closed on the glasses');
    }
  }
}
