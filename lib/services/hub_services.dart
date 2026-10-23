/// Everything that keeps the glasses in sync without the user pressing "Send":
///
/// * a [SyncEngine] section per piece of glasses state (settings, layout, weather, menu, tasks,
///   calendar, news, stocks, health, notifications); screens call [changed] after an edit and
///   the change reaches the glasses ~1 s later, or on the next connect;
/// * on every (re)connect the full state is restored in the hub's order;
/// * periodic refreshes like the hub: weather, calendar (+ ICS + phone calendars) and stocks
///   every 15 min, news every 30 min, the profile schedule every minute;
/// * profiles (per pair, with schedule), saved pairs, settings backup/restore;
/// * notifications, navigation, EvenHub apps and image widgets.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../hub/features.dart';
import '../hub/glasses_session.dart';
import '../hub/hub_controller.dart';
import '../hub/models.dart';
import '../hub/sync_engine.dart';
import '../logic/feeds.dart' as feeds;
import '../logic/profiles.dart' as prof;
import '../logic/stock_quotes.dart' as quotes;
import '../logic/weather_logic.dart' as wl;
import '../logic/widget_data.dart' as wd;
import '../protocol/hub_format.dart' as fmt;
import '../protocol/watchface.dart' as wf;
import 'data_services.dart';
import 'evenhub_service.dart';
import 'health_import.dart';
import 'image_widgets.dart' as iw;
import 'nav_service.dart';
import 'net.dart';
import 'notification_service.dart';

/// Profile sections → the sync section that pushes them.
const Map<String, String> profileSyncKey = {
  'weather': 'weather', 'calendar': 'calendar', 'quicklist': 'tasks', 'menu': 'menu', 'evenhub_menu': 'menu', //
  'news': 'news', 'stocks': 'stocks', 'health': 'health', 'settings': 'settings', 'layout': 'layout',
};

class HubServices extends ChangeNotifier with WidgetsBindingObserver {
  HubServices(this.hub, {Net? net, bool startTimers = true})
      : net = net ?? HttpNet(),
        _timers = startTimers {
    weather = WeatherService(this.net);
    news = NewsService(this.net);
    calendar = CalendarService(this.net);
    stocks = StocksService(this.net);
    notifications = NotificationService(data: () => hub.data, features: () => features, log: _logw);
    nav = NavService(net: this.net, features: () => features, data: () => hub.data, log: _logw);
    sync = SyncEngine<G2Features>(log: _logw);
    healthSource = startTimers ? PluginHealthSource() : const NoHealthSource();
    _register();
  }

  /// Health Connect / Apple Health (tests put a fake here).
  late HealthSource healthSource;

  /// What the phone's health store allows, as last checked (null = not checked yet).
  HealthAvailability? healthAvailability;
  bool healthAccess = false;

  final HubController hub;
  final Net net;
  final bool _timers;
  late final WeatherService weather;
  late final NewsService news;
  late final CalendarService calendar;
  late final StocksService stocks;
  late final NotificationService notifications;
  late final NavService nav;
  late final SyncEngine<G2Features> sync;
  EvenHubRuntime? evenhub;
  AppRegistry? registry;
  Timer? _ticker;
  final _lastRun = <String, DateTime>{};
  String? weatherError, newsError, stocksError;
  final Set<int> _batteryWarned = {};
  StreamSubscription<GlassesStatus>? _statusSub;
  StreamSubscription<WireFrame>? _wireSub;

  /// Developer mode: the last frames sent/received (raw frame inspector).
  final wire = <WireFrame>[];
  bool wirePaused = false;

  AppData get data => hub.data;
  G2Features? get features => hub.status == LinkStatus.connected ? hub.features : null;

  void _logw(String m, {bool warn = false}) => hub.log(m, warn ? LogLevel.warn : LogLevel.info);

  // ── lifecycle ────────────────────────────────────────────────────────────────────────────
  Future<void> start() async {
    if (_timers) {
      _ticker ??= Timer.periodic(const Duration(minutes: 1), (_) => tick());
      WidgetsBinding.instance.addObserver(this);
    }
    try {
      registry = await AppRegistry.open();
      evenhub = EvenHubRuntime(registry: registry!, features: () => features, log: (m) => hub.log(m), batteryLevel: () => hub.glasses?.battery);
    } catch (_) {/* no app directory (tests) */}
    await notifications.start();
    unawaited(tick());
  }

  void onConnected(G2Features f) {
    f.onNewsRefreshRequested = () => unawaited(refreshNews(force: true));
    f.teleprompterFiles = () => [for (final s in data.teleprompter.scripts) (s.id, s.name)];
    f.teleprompterFileText = (id) => data.teleprompter.scripts.where((s) => s.id == id).firstOrNull?.text;
    nav.attach(f);
    evenhub?.attach(f);
    f.s.notificationDispTime = data.notifications.displaySeconds;
    _statusSub?.cancel();
    _statusSub = f.s.statusChanges.listen(_onStatus);
    _wireSub?.cancel();
    _wireSub = f.s.wire.listen((w) {
      if (!data.ui.devMode || wirePaused) return;
      wire.add(w);
      if (wire.length > 400) wire.removeRange(0, wire.length - 400);
    });
    sync.attach(f, restoreAll: data.restoreOnConnect);
    notifications.flushPending();
    final p = data.activePair;
    if (p != null) p.lastSeen = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }

  void onDisconnected() {
    _statusSub?.cancel();
    _statusSub = null;
    _wireSub?.cancel();
    _wireSub = null;
    sync.detach();
    evenhub?.detach();
  }

  /// The user (or the AI assistant) changed [section]: save and sync it to the glasses.
  void changed(String section) {
    unawaited(hub.save());
    sync.markDirty(section);
    notifyListeners();
  }

  /// Back in the app (e.g. from Android's notification-access or permission pages): re-check
  /// what the user may have granted or revoked there, so every tile's status line is current.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(onResumed());
  }

  Future<void> onResumed() async {
    await notifications.refreshAccess();
    final h = data.health;
    if (h.enabled && h.fromPhone) {
      await refreshHealthAccess();
      // Health Connect only answers apps in the foreground: a good moment for fresh numbers.
      if (healthAccess) await importHealth();
    }
    notifyListeners();
  }

  // ── sync sections (push functions; the order is the reconnect restore order) ──────────────
  void _register() {
    SyncOutcome out(PushResult r) => r.ok ? SyncOutcome.ok(r.message) : SyncOutcome.failed(r.message);
    sync.register('settings', (f) async => out(await f.applySettings(data.settings)), label: 'Display and behaviour');
    sync.register('layout', (f) async {
      if (!data.layout.custom) return const SyncOutcome.skipped();
      return out(await f.pushLayout(data.layout.order, h24: data.h24, celsius: !data.weather.fahrenheit));
    }, label: 'Dashboard layout');
    sync.register('weather', (f) async {
      final w = data.weather;
      if (w.mode == 'auto') {
        try {
          if (weather.stale(w) || w.last.isEmpty) await weather.refresh(w);
          weatherError = null;
        } catch (e) {
          weatherError = '$e'.replaceFirst('Bad state: ', '');
          notifyListeners();
          if (w.last.isEmpty) return SyncOutcome.failed(weatherError!);
        }
        unawaited(hub.save());
      }
      return out(await f.pushWeather(w));
    }, label: 'Weather');
    sync.register('menu', (f) async => out(await f.pushMenu(data.menu, apps: menuApps())), label: 'Menu');
    sync.register('tasks', (f) async {
      data.tasks = fmt.assignUids(data.tasks, data.tasks);
      if (data.tasks.isEmpty) return const SyncOutcome.skipped();
      return out(await f.pushTasks(data.tasks));
    }, label: 'Tasks');
    sync.register('calendar', (f) async => out(await f.pushCalendar(data.allEvents, h24: data.h24)), label: 'Calendar');
    sync.register('news', (f) async {
      if (data.newsConfig.mode == 'feeds') {
        try {
          await refreshNews(push: false);
        } catch (_) {}
      }
      final list = NewsService.articles(data);
      if (list.isEmpty) return const SyncOutcome.skipped('no news yet');
      final r = await f.pushNews(list);
      if (r.ok) data.newsCache.lastPushedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return out(r);
    }, label: 'News');
    sync.register('stocks', (f) async {
      if (!data.stocks.enabled || !data.ui.beta) return const SyncOutcome.skipped();
      final q = await refreshStocks();
      if (q.isEmpty) return SyncOutcome.failed(stocksError ?? 'no quotes');
      return out(await f.pushStocks(q));
    }, label: 'Stocks');
    sync.register('health', (f) async {
      if (!data.health.enabled || !data.ui.beta) return const SyncOutcome.skipped();
      // From the phone: fresh numbers first; if the store is not reachable the last ones go.
      if (data.health.fromPhone) await importHealth(push: false);
      return out(await f.pushHealth(data.health.values, showCard: data.health.showCard));
    }, label: 'Health');
    sync.register('notifications', (f) async {
      f.s.notificationDispTime = data.notifications.displaySeconds;
      return out(await f.notificationSetup(dispTime: data.notifications.displaySeconds));
    }, label: 'Notifications', restore: false);
  }

  // ── weather (the Weather page and the assistant go through these) ────────────────────────
  /// Fetch live weather now. Returns the error shown to the user, or null. Always queues the
  /// weather sync (the glasses get the new reading, or the place change on the next connect).
  Future<String?> refreshWeather() async {
    final w = data.weather;
    String? err;
    try {
      await weather.refresh(w);
    } catch (e) {
      err = '$e'.replaceFirst('Bad state: ', '');
    }
    weatherError = err;
    changed('weather');
    return err;
  }

  /// The user picked [p] (typed city): use it instead of GPS, drop the old place's reading,
  /// save, fetch its weather and sync. Returns an error to show, or null; the place is kept
  /// either way (it syncs when the weather service / glasses are reachable).
  Future<String?> setWeatherPlace(wl.GeoPlace p) async {
    data.weather
      ..mode = 'auto'
      ..useGps = false
      ..city = p.label
      ..place = p.label
      ..lat = p.lat
      ..lon = p.lon
      ..last = {}
      ..lastAt = null;
    changed('weather');
    return refreshWeather();
  }

  /// "Use my location" on/off. Off goes back to the saved city (or asks for one).
  Future<String?> setWeatherGps(bool on) async {
    final w = data.weather
      ..mode = 'auto'
      ..useGps = on
      ..last = {}
      ..lastAt = null;
    if (!on && w.place == currentLocationLabel) w.place = w.city;
    if (!on && w.lat == null && w.city.trim().isEmpty) {
      weatherError = null;
      changed('weather');
      return 'Type a city or town, then press search.';
    }
    return refreshWeather();
  }

  /// Live ('auto') or typed ('manual') weather.
  Future<String?> setWeatherMode(String mode) async {
    final w = data.weather..mode = mode == 'manual' ? 'manual' : 'auto';
    weatherError = null;
    changed('weather');
    if (w.mode == 'auto' && (w.last.isEmpty || weather.stale(w))) {
      if (!w.useGps && w.lat == null && w.city.trim().isEmpty) return null; // nothing to look up yet
      return refreshWeather();
    }
    return null;
  }

  // ── health card from Health Connect / Apple Health ────────────────────────────────────────
  Future<void> refreshHealthAccess() async {
    healthAvailability = await healthSource.availability();
    healthAccess = healthAvailability == HealthAvailability.available && await healthSource.hasAccess();
    notifyListeners();
  }

  /// Ask for access (user action). Returns true when the app may read the data.
  Future<bool> requestHealthAccess() async {
    healthAvailability = await healthSource.availability();
    if (healthAvailability != HealthAvailability.available) {
      notifyListeners();
      return false;
    }
    healthAccess = await healthSource.requestAccess() || await healthSource.hasAccess();
    notifyListeners();
    if (healthAccess) await importHealth();
    return healthAccess;
  }

  /// "Typed" or "From the phone" for the health card.
  Future<void> setHealthSource(bool fromPhone) async {
    data.health.source = fromPhone ? 'phone' : 'typed';
    data.health.importNote = '';
    changed('health');
    if (fromPhone) await refreshHealthAccess();
  }

  /// Read today's numbers into the health card. Returns the problem to show, or null. Values the
  /// store does not have keep what was there; [push] queues the sync when something changed.
  Future<String?> importHealth({bool push = true}) async {
    final h = data.health;
    if (!h.fromPhone) return null;
    final name = healthSource.name;
    String? note;
    try {
      final a = healthAvailability = await healthSource.availability();
      if (a == HealthAvailability.unsupported) {
        note = 'This phone has no $name.';
      } else if (a == HealthAvailability.notInstalled) {
        note = 'Install $name to import steps, heart rate and sleep.';
      } else if (a == HealthAvailability.updateRequired) {
        note = 'Update $name to import steps, heart rate and sleep.';
      } else if (!(healthAccess = await healthSource.hasAccess())) {
        note = 'Allow G2 Hub to read steps, heart rate and sleep in $name.';
      } else {
        final r = await healthSource.read(DateTime.now());
        final changedKeys = applyReading(h.values, r);
        h.importedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        if (r.isEmpty) note = 'No steps, heart rate or sleep in $name today yet.';
        if (push && changedKeys.isNotEmpty) sync.markDirty('health');
      }
    } catch (e) {
      // e.g. Health Connect refuses reads while the app is in the background: keep the last values.
      note = 'Could not read $name (${'$e'.replaceFirst('Bad state: ', '')}). The last numbers are kept.';
    }
    h.importNote = note ?? '';
    unawaited(hub.save());
    notifyListeners();
    return note;
  }

  /// Installed EvenHub apps in this pair's menu, within the 10-item limit.
  List<(String, int)> menuApps() {
    final reg = registry;
    if (reg == null) return const [];
    final room = 10 - data.menu.length;
    final out = <(String, int)>[];
    for (final pid in data.evenhubMenu) {
      final e = reg.get(pid);
      if (e != null && out.length < room) out.add(((e['menu_name'] ?? e['name'] ?? pid) as String, e['app_id'] as int));
    }
    return out;
  }

  // ── periodic refresh (every minute; each job on its own schedule) ─────────────────────────
  bool _due(String job, Duration every) {
    final last = _lastRun[job];
    final now = DateTime.now();
    if (last != null && now.difference(last) < every) return false;
    _lastRun[job] = now;
    return true;
  }

  Future<void> tick() async {
    scheduleTick(DateTime.now());
    final connected = features != null;
    if (_due('calendar', const Duration(minutes: 15))) {
      var changedEvents = false;
      try {
        changedEvents = await calendar.syncIcs(data.calendar) | await calendar.syncPhone(data.calendar);
      } catch (_) {}
      if (changedEvents) unawaited(hub.save());
      // The hub re-sends every 15 min so ended events drop off and tomorrow's become today's.
      if (connected && (changedEvents || data.allEvents.isNotEmpty)) sync.pushNow('calendar');
    }
    if (!connected) return;
    if (data.weather.mode == 'auto' && _due('weather', wl.refreshEvery)) {
      data.weather.lastAt = null; // force a fresh reading
      sync.pushNow('weather');
    }
    if (data.newsConfig.mode == 'feeds' && _due('news', feeds.refreshEvery)) unawaited(refreshNews(force: true));
    if (data.stocks.enabled && data.ui.beta && _due('stocks', const Duration(minutes: 15))) sync.pushNow('stocks');
    if (data.health.enabled && data.health.fromPhone && data.ui.beta && _due('health', const Duration(minutes: 15))) sync.pushNow('health');
  }

  /// Fetch fresh stories (hub auto_push_hn) and push when they changed.
  Future<void> refreshNews({bool force = false, bool push = true}) async {
    if (data.newsConfig.mode != 'feeds') return;
    final before = data.newsCache.stories.map((s) => s['title']).join('\n');
    try {
      final errors = await news.refresh(data.newsConfig, data.newsCache, force: force);
      newsError = errors.isEmpty ? null : errors.join('; ');
    } catch (e) {
      newsError = '$e'.replaceFirst('Bad state: ', '');
      notifyListeners();
      rethrow;
    }
    unawaited(hub.save());
    notifyListeners();
    if (push && data.newsCache.stories.map((s) => s['title']).join('\n') != before) sync.pushNow('news');
  }

  Future<List<Map<String, Object?>>> refreshStocks() async {
    try {
      final syms = quotes.parseSymbols(data.stocks.symbols.join(' '));
      final (q, errors) = await stocks.fetch(syms);
      data.stocks
        ..last = {'quotes': q, 'errors': errors}
        ..lastAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      stocksError = errors.isEmpty ? null : errors.join('; ');
      notifyListeners();
      return q;
    } on FormatException catch (e) {
      stocksError = e.message;
      return const [];
    }
  }

  // ── glasses status: low-battery warning on the glasses (hub frames._check_low_battery) ────
  void _onStatus(GlassesStatus s) {
    final p = data.activePair;
    if (p != null && s.rightVersion != null) p.firmware = s.rightVersion;
    final b = s.battery;
    if (b == null || !data.notifications.lowBatteryAlerts) return;
    if (s.charging == true || b > 25) {
      _batteryWarned.clear();
      return;
    }
    for (final level in const [20, 10]) {
      if (b <= level && _batteryWarned.add(level)) {
        hub.log('Glasses battery low: $b%', LogLevel.warn);
        unawaited(notifications.sendTest('Battery low', 'Glasses battery at $b%. Put them in the case to charge.'));
        break;
      }
    }
  }

  // ── profiles ─────────────────────────────────────────────────────────────────────────────
  Profile saveProfile(String name) {
    final n = prof.cleanName(name);
    final p = Profile({for (final s in prof.profileSections) s: data.section(s)}..['layout'] = data.section('layout'),
        DateTime.now().millisecondsSinceEpoch ~/ 1000);
    data.profiles[n] = p;
    data.activeProfile = n;
    unawaited(hub.save());
    notifyListeners();
    return p;
  }

  /// Write the profile back as the current configuration and sync what changed.
  void applyProfile(String name) {
    final p = data.profiles[name];
    if (p == null) throw prof.ProfileError("no profile named '$name'");
    final keys = <String>{};
    for (final e in p.sections.entries) {
      if (e.value is Map) {
        data.applySection(e.key, (e.value as Map).cast<String, Object?>());
        final k = profileSyncKey[e.key];
        if (k != null) keys.add(k);
      }
    }
    data.activeProfile = name;
    hub.log('Profile "$name" applied (${keys.join(', ')})', LogLevel.ok);
    for (final k in keys) {
      sync.markDirty(k);
    }
    unawaited(hub.save());
    notifyListeners();
  }

  bool deleteProfile(String name) {
    if (data.profiles.remove(name) == null) return false;
    if (data.activeProfile == name) data.activeProfile = null;
    unawaited(hub.save());
    notifyListeners();
    return true;
  }

  void setSchedule(bool enabled, List<Map<String, Object?>> rules) {
    final clean = prof.normalizeRules(rules);
    data.schedule
      ..enabled = enabled
      ..rules = clean
      ..lastTarget = enabled ? data.schedule.lastTarget : null;
    unawaited(hub.save());
    notifyListeners();
  }

  /// One scheduler evaluation (hub schedule_tick): acts only when the scheduled target changes,
  /// so a manual apply is not undone a minute later. Returns the applied profile name.
  String? scheduleTick(DateTime now) {
    final s = data.schedule;
    if (!s.enabled) return null;
    final target = prof.scheduledProfile(s.rules, now, known: data.profiles.keys.toSet());
    if (target == s.lastTarget) return null;
    s.lastTarget = target;
    unawaited(hub.save());
    if (target == null || target == data.activeProfile) return null;
    hub.log('Schedule: switching to profile "$target"');
    applyProfile(target);
    return target;
  }

  // ── saved pairs ──────────────────────────────────────────────────────────────────────────
  /// Make [g] the active pair: the current pair's configuration is stored with it and [g]'s
  /// own configuration is loaded (a new pair starts from a copy of the current one).
  Future<void> switchPair(PairedGlasses g, {String? name}) async {
    final cur = data.activePair;
    final changedPair = data.glasses?.pairId != g.pairId;
    if (cur != null && changedPair) cur.config = data.pairSections();
    var rec = data.pairs.where((p) => p.glasses.pairId == g.pairId).firstOrNull;
    if (rec == null) {
      rec = PairRecord(glasses: g, name: name);
      data.pairs.add(rec);
    } else {
      rec.glasses = g;
      if (rec.config.isNotEmpty) data.applyPairSections(rec.config);
    }
    rec.config = {};
    data.glasses = g;
    // The other glasses have never received this configuration (and "restore on connect" may be
    // off): everything is queued for their first connect.
    if (changedPair) sync.resyncAll();
    await hub.save();
    notifyListeners();
  }

  Future<void> renamePair(String pairId, String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    for (final p in data.pairs) {
      if (p.glasses.pairId == pairId) p.name = n.length > 40 ? n.substring(0, 40) : n;
    }
    await hub.save();
  }

  /// Forget a saved pair that is not the active one.
  Future<bool> forgetPair(String pairId) async {
    if (data.glasses?.pairId == pairId) return false;
    data.pairs.removeWhere((p) => p.glasses.pairId == pairId);
    await hub.save();
    return true;
  }

  // ── backup ───────────────────────────────────────────────────────────────────────────────
  static const backupFormat = 'g2hub-mobile-settings';

  /// Every setting as JSON, without secrets (ICS links; API keys live in secure storage and
  /// are never part of AppData).
  String exportBackup() => const JsonEncoder.withIndent(' ').convert({
        'format': backupFormat,
        'version': 1,
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'data': data.toJson(includeSecrets: false)..remove('news_cache'),
      });

  /// Restore a backup. Keeps the current ICS link when the backup has none. Throws
  /// FormatException when the file is not a backup.
  Future<void> importBackup(String text) async {
    final j = jsonDecode(text);
    if (j is! Map || j['format'] != backupFormat || j['data'] is! Map) throw const FormatException('not a G2 Hub settings backup');
    final keepUrl = data.calendar.icsUrl;
    final cache = data.newsCache;
    final d = AppData.fromJson((j['data'] as Map).cast<String, Object?>());
    if (d.calendar.icsUrl.isEmpty) d.calendar.icsUrl = keepUrl;
    d.newsCache = cache;
    d.handedOff = data.handedOff; // a backup never grabs (or releases) the glasses
    // Other glasses in the backup: let go of the current pair first, so the session never keeps
    // talking to glasses the app no longer shows.
    final otherPair = d.glasses?.pairId != data.glasses?.pairId;
    final reconnect = otherPair && hub.status != LinkStatus.noGlasses && hub.status != LinkStatus.disconnected;
    if (otherPair) await hub.disconnect();
    hub.data = d;
    if (otherPair) hub.status = d.glasses == null ? LinkStatus.noGlasses : LinkStatus.disconnected;
    await hub.save();
    sync.resyncAll();
    notifyListeners();
    if (otherPair && d.glasses != null && d.onboarded && (reconnect || d.autoConnect) && !d.handedOff) unawaited(hub.connect());
  }

  // ── image widgets (stock chart / custom widgets) ─────────────────────────────────────────
  Future<PushResult> pushCustomWidget(CustomWidgetSpec w) async {
    final f = features;
    if (f == null) return PushResult(false, 'Not connected');
    try {
      switch (w.type) {
        case 'stock':
          return await pushStockChart(w.symbol);
        case 'metric':
          return await f.pushImage(iw.pack(iw.renderMetric(w.title, w.value, label: w.label)), iw.imgW, iw.imgH);
        default:
          final vals = w.values.trim().isNotEmpty ? wd.parseValues(w.values) : await _fetchValues(w.url);
          return await f.pushImage(iw.pack(iw.renderGraph(w.title, vals, unit: w.unit)), iw.imgW, iw.imgH);
      }
    } on FormatException catch (e) {
      return PushResult(false, e.message);
    } on NetError catch (e) {
      return PushResult(false, 'data URL: ${e.message}');
    }
  }

  Future<List<double>> _fetchValues(String url) async {
    final u = Uri.tryParse(url.trim());
    if (u == null || !(u.scheme == 'http' || u.scheme == 'https') || u.host.isEmpty) {
      throw const FormatException('data URL must start with http:// or https://');
    }
    return wd.parsePayload(await net.getText(u, timeout: wd.fetchTimeout, maxBytes: wd.maxBytes));
  }

  Future<PushResult> pushStockChart(String symbol) async {
    final f = features;
    if (f == null) return PushResult(false, 'Not connected');
    final sym = quotes.parseSymbols(symbol).first;
    final (q, errors) = await stocks.fetch([sym]);
    if (q.isEmpty) return PushResult(false, errors.isNotEmpty ? errors.first : '$sym: no data');
    final prices = [for (final p in (q.first['points'] as List? ?? const [])) (p as num).toDouble()];
    final price = (q.first['price'] as num?)?.toDouble();
    if (price != null && (prices.isEmpty || prices.last != price)) prices.add(price);
    return f.pushImage(iw.pack(iw.renderStockChart(sym, prices)), iw.imgW, iw.imgH);
  }

  // ── watchface (experimental) ─────────────────────────────────────────────────────────────
  Future<(bool, List<String>)> uploadWatchface() async {
    final f = features;
    if (f == null) return (false, ['Not connected']);
    final w = data.watchface;
    final info = await f.watchfaceInfo();
    w.before = info == null ? null : {for (final k in ['exists', 'version', 'hash']) k: info[k]};
    final file = wf.buildHubLayout('${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
        style: w.style, left: w.left, right: w.right, pos: w.pos, date: w.date, temp: w.temp);
    final r = await f.watchfaceUpload(file);
    w.uploadedOk = r.$1;
    unawaited(hub.save());
    return r;
  }

  @override
  void dispose() {
    if (_timers) WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _statusSub?.cancel();
    sync.dispose();
    notifications.dispose();
    super.dispose();
  }
}
