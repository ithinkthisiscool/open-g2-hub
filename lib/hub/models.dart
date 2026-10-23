/// App data, persisted locally as JSON (shared_preferences).
///
/// The top-level fields that existed in phase 1 (`weather`, `events`, `tasks`, `news`, `menu`,
/// `settings`, ...) are the ACTIVE pair's configuration. Every pair of glasses keeps its own
/// copy (like the hub's per-device store): switching pairs swaps them via [pairSections] /
/// [applyPairSections]. Profiles are named snapshots of the hub's profile sections.
library;

import '../logic/feeds.dart' as feedlib;
import '../logic/health_values.dart';
import '../logic/notification_filter.dart';
import '../protocol/hub_format.dart';

List<Map<String, Object?>> _maps(Object? v) => [for (final x in (v is List ? v : const [])) if (x is Map) x.cast<String, Object?>()];
Map<String, Object?> _map(Object? v) => v is Map ? v.cast<String, Object?>() : <String, Object?>{};
List<String> _strs(Object? v) => [for (final x in (v is List ? v : const [])) x.toString()];
List<int> _ints(Object? v) => [for (final x in (v is List ? v : const [])) if (x is num) x.toInt()];
String? _strOrNull(Object? v) => v?.toString();
bool? _boolOrNull(Object? v) => v is bool ? v : null;
int? _intOrNull(Object? v) => v is num ? v.toInt() : null;

/// Items of a saved list; an item that cannot be read is dropped, not the whole list.
List<T> _items<T>(Object? v, T Function(Map<String, Object?>) parse) {
  final out = <T>[];
  for (final m in _maps(v)) {
    try {
      out.add(parse(m));
    } catch (_) {/* skip a broken item */}
  }
  return out;
}

/// A saved value that cannot be read falls back to [fallback] (one bad value must never cost
/// the user the rest of their data).
T _or<T>(T Function() read, T fallback) {
  try {
    return read();
  } catch (_) {
    return fallback;
  }
}

/// Settings backups leave private calendar links out wherever they appear (the active pair, the
/// other pairs' stored configuration, profile snapshots).
Object? _withoutSecrets(Object? v) {
  if (v is Map) {
    return {
      for (final e in v.entries) e.key: e.key == 'ics_url' ? '' : _withoutSecrets(e.value),
    };
  }
  if (v is List) return [for (final x in v) _withoutSecrets(x)];
  return v;
}

/// Status-bar weather: live (Open-Meteo, GPS or a city) or typed by hand.
class WeatherConfig {
  WeatherConfig({
    this.tempF = 72,
    this.weatherType = 1,
    this.status = '',
    this.fahrenheit = true,
    this.mode = 'auto',
    this.useGps = true,
    this.city = '',
    this.place = '',
    this.lat,
    this.lon,
    Map<String, Object?>? last,
    this.lastAt,
  }) : last = last ?? {};
  double tempF;
  int weatherType;
  String status;
  bool fahrenheit;

  /// 'auto' (live) or 'manual'.
  String mode;
  bool useGps;
  String city;
  String place;
  double? lat, lon;

  /// Last live reading (weatherFromForecast result) and when (unix s).
  Map<String, Object?> last;
  int? lastAt;

  Map<String, Object?> toJson() => {
        'temp_f': tempF,
        'type': weatherType,
        'status': status,
        'fahrenheit': fahrenheit,
        'mode': mode,
        'use_gps': useGps,
        'city': city,
        'place': place,
        'lat': lat,
        'lon': lon,
        'last': last,
        'last_at': lastAt,
      };
  factory WeatherConfig.fromJson(Map<String, Object?> j) => WeatherConfig(
        tempF: (j['temp_f'] as num?)?.toDouble() ?? 72,
        weatherType: (j['type'] as num?)?.toInt() ?? 1,
        status: (j['status'] ?? '').toString(),
        fahrenheit: j['fahrenheit'] != false,
        // phase-1 data had no mode: it was manual
        mode: (j['mode'] ?? (j.containsKey('temp_f') ? 'manual' : 'auto')).toString(),
        useGps: j['use_gps'] != false,
        city: (j['city'] ?? '').toString(),
        place: (j['place'] ?? '').toString(),
        lat: (j['lat'] as num?)?.toDouble(),
        lon: (j['lon'] as num?)?.toDouble(),
        last: _map(j['last']),
        lastAt: (j['last_at'] as num?)?.toInt(),
      );
}

class NewsItem {
  NewsItem({required this.title, this.source = '', this.content = ''});
  String title;
  String source;
  String content;
  Map<String, Object?> toJson() => {'title': title, 'source': source, 'content': content};
  factory NewsItem.fromJson(Map<String, Object?> j) =>
      NewsItem(title: (j['title'] ?? '').toString(), source: (j['source'] ?? '').toString(), content: (j['content'] ?? '').toString());
}

/// News widget: RSS feeds (the hub's sources + custom URLs) or the user's own items.
class NewsConfig {
  NewsConfig({this.mode = 'feeds', List<String>? feeds_}) : feeds = feeds_ ?? [...feedlib.defaultFeeds];
  String mode; // 'feeds' | 'manual'
  List<String> feeds;
  Map<String, Object?> toJson() => {'mode': mode, 'feeds': feeds};
  factory NewsConfig.fromJson(Map<String, Object?> j) =>
      NewsConfig(mode: (j['mode'] ?? 'feeds').toString(), feeds_: j['feeds'] is List ? _strs(j['feeds']) : null);
}

/// Fetched stories + the hub's seen-titles bookkeeping (not a profile section).
class NewsCache {
  NewsCache({List<Map<String, Object?>>? stories, this.fetchedAt = 0, List<String>? seenTitles, List<String>? feeds, this.lastPushedAt})
      : stories = stories ?? [],
        seenTitles = seenTitles ?? [],
        feeds = feeds ?? [];
  List<Map<String, Object?>> stories;
  int fetchedAt;
  List<String> seenTitles;
  List<String> feeds;
  int? lastPushedAt;
  Map<String, Object?> toJson() =>
      {'stories': stories, 'fetched_at': fetchedAt, 'seen_titles': seenTitles, 'feeds': feeds, 'last_pushed_at': lastPushedAt};
  factory NewsCache.fromJson(Map<String, Object?> j) => NewsCache(
      stories: _maps(j['stories']),
      fetchedAt: (j['fetched_at'] as num?)?.toInt() ?? 0,
      seenTitles: _strs(j['seen_titles']),
      feeds: _strs(j['feeds']),
      lastPushedAt: (j['last_pushed_at'] as num?)?.toInt());
}

/// Calendar sources besides typed events: an ICS link and the phone's own calendars.
class CalendarSources {
  CalendarSources({
    this.icsUrl = '',
    this.icsEnabled = false,
    List<CalEvent>? icsEvents,
    this.icsLastTry,
    this.icsLastOk,
    this.icsNote = '',
    this.phoneEnabled = false,
    List<String>? phoneCalendarIds,
    List<CalEvent>? phoneEvents,
  })  : icsEvents = icsEvents ?? [],
        phoneCalendarIds = phoneCalendarIds ?? [],
        phoneEvents = phoneEvents ?? [];
  String icsUrl;
  bool icsEnabled;
  List<CalEvent> icsEvents;
  int? icsLastTry, icsLastOk;
  String icsNote;
  bool phoneEnabled;
  List<String> phoneCalendarIds; // empty = all
  List<CalEvent> phoneEvents;

  Map<String, Object?> toJson({bool includeSecrets = true}) => {
        'ics_url': includeSecrets ? icsUrl : '',
        'ics_enabled': icsEnabled,
        'ics_events': icsEvents.map((e) => e.toJson()).toList(),
        'ics_last_try': icsLastTry,
        'ics_last_ok': icsLastOk,
        'ics_note': icsNote,
        'phone_enabled': phoneEnabled,
        'phone_calendar_ids': phoneCalendarIds,
        'phone_events': phoneEvents.map((e) => e.toJson()).toList(),
      };
  factory CalendarSources.fromJson(Map<String, Object?> j) => CalendarSources(
        icsUrl: (j['ics_url'] ?? '').toString(),
        icsEnabled: j['ics_enabled'] == true,
        icsEvents: _items(j['ics_events'], CalEvent.fromJson),
        icsLastTry: (j['ics_last_try'] as num?)?.toInt(),
        icsLastOk: (j['ics_last_ok'] as num?)?.toInt(),
        icsNote: (j['ics_note'] ?? '').toString(),
        phoneEnabled: j['phone_enabled'] == true,
        phoneCalendarIds: _strs(j['phone_calendar_ids']),
        phoneEvents: _items(j['phone_events'], CalEvent.fromJson),
      );
}

class StocksConfig {
  StocksConfig({this.enabled = false, List<String>? symbols, Map<String, Object?>? last, this.lastAt})
      : symbols = symbols ?? ['AAPL', 'MSFT', 'NVDA'],
        last = last ?? {};
  bool enabled;
  List<String> symbols;
  Map<String, Object?> last; // {quotes, errors}
  int? lastAt;
  Map<String, Object?> toJson() => {'enabled': enabled, 'symbols': symbols, 'last': last, 'last_at': lastAt};
  factory StocksConfig.fromJson(Map<String, Object?> j) => StocksConfig(
      enabled: j['enabled'] == true,
      symbols: j['symbols'] is List ? _strs(j['symbols']) : null,
      last: _map(j['last']),
      lastAt: (j['last_at'] as num?)?.toInt());
}

class HealthConfig {
  HealthConfig({this.enabled = false, Map<String, num>? values, this.showCard = true, this.source = 'typed', this.importedAt, this.importNote = ''})
      : values = values ?? {...healthDefaults};
  bool enabled;
  Map<String, num> values;
  bool showCard;

  /// 'typed' (the user types every value) or 'phone' (steps, heart rate and sleep come from
  /// Health Connect / Apple Health; goals stay typed).
  String source;

  /// Last successful import (unix s) and why the last one did not work ('' = it did).
  int? importedAt;
  String importNote;

  bool get fromPhone => source == 'phone';

  Map<String, Object?> toJson() =>
      {'enabled': enabled, 'values': values, 'show_card': showCard, 'source': source, 'imported_at': importedAt, 'import_note': importNote};
  factory HealthConfig.fromJson(Map<String, Object?> j) => HealthConfig(
      enabled: j['enabled'] == true,
      values: j['values'] is Map ? {for (final e in (j['values'] as Map).entries) if (e.value is num) e.key.toString(): e.value as num} : null,
      showCard: j['show_card'] != false,
      source: j['source'] == 'phone' ? 'phone' : 'typed',
      importedAt: _intOrNull(j['imported_at']),
      importNote: (j['import_note'] ?? '').toString());
}

/// Dashboard widget order (dashboard.WIDGET_* ids). [custom] false = the app's default init.
class LayoutConfig {
  LayoutConfig({List<int>? order, this.custom = false}) : order = order ?? [1, 3, 4, 2];
  List<int> order;
  bool custom;
  Map<String, Object?> toJson() => {'order': order, 'custom': custom};
  factory LayoutConfig.fromJson(Map<String, Object?> j) =>
      LayoutConfig(order: j['order'] is List ? _ints(j['order']) : null, custom: j['custom'] == true);
}

/// Glasses settings the user chose. null = leave unchanged. displayTimeout 0 = never.
class GlassesSettings {
  GlassesSettings({
    this.brightness = 25,
    this.autoBrightness = true,
    this.silentMode = false,
    this.wearDetection = true,
    this.headUp = true,
    this.headUpAngle = 30,
    this.displayTimeout = 10,
    this.language = 0,
    this.time24h,
    this.celsius,
    this.imperial,
  });
  int? brightness;
  bool? autoBrightness;
  bool? silentMode;
  bool? wearDetection;
  bool? headUp;
  int? headUpAngle;
  int? displayTimeout;
  int? language;

  /// Units (SID 0x09 field 9); null = the app default sent on connect (12 h, °C, metric).
  bool? time24h;
  bool? celsius;
  bool? imperial;

  Map<String, Object?> toJson() => {
        'brightness': brightness,
        'auto_brightness': autoBrightness,
        'silent_mode': silentMode,
        'wear_detection': wearDetection,
        'head_up': headUp,
        'head_up_angle': headUpAngle,
        'display_timeout': displayTimeout,
        'language': language,
        'time_24h': time24h,
        'celsius': celsius,
        'imperial': imperial,
      };
  factory GlassesSettings.fromJson(Map<String, Object?> j) => GlassesSettings(
        brightness: _intOrNull(j['brightness']),
        autoBrightness: _boolOrNull(j['auto_brightness']),
        silentMode: _boolOrNull(j['silent_mode']),
        wearDetection: _boolOrNull(j['wear_detection']),
        headUp: _boolOrNull(j['head_up']),
        headUpAngle: _intOrNull(j['head_up_angle']),
        displayTimeout: _intOrNull(j['display_timeout']),
        language: _intOrNull(j['language']),
        time24h: _boolOrNull(j['time_24h']),
        celsius: _boolOrNull(j['celsius']),
        imperial: _boolOrNull(j['imperial']),
      );
}

class WatchfaceConfig {
  WatchfaceConfig({this.style = 1, this.left = 'temperature', this.right = 'sunset', this.pos = 'center', this.date = true, this.temp = true, this.before, this.uploadedOk});
  int style;
  String left, right, pos;
  bool date, temp;
  Map<String, Object?>? before;
  bool? uploadedOk;
  Map<String, Object?> toJson() =>
      {'style': style, 'left': left, 'right': right, 'pos': pos, 'date': date, 'temp': temp, 'before': before, 'uploaded_ok': uploadedOk};
  factory WatchfaceConfig.fromJson(Map<String, Object?> j) => WatchfaceConfig(
      style: (j['style'] as num?)?.toInt() ?? 1,
      left: (j['left'] ?? 'temperature').toString(),
      right: (j['right'] ?? 'sunset').toString(),
      pos: (j['pos'] ?? 'center').toString(),
      date: j['date'] != false,
      temp: j['temp'] != false,
      before: j['before'] is Map ? _map(j['before']) : null,
      uploadedOk: _boolOrNull(j['uploaded_ok']));
}

class Profile {
  Profile(this.sections, this.savedAt);
  final Map<String, Object?> sections;
  final int savedAt;
  Map<String, Object?> toJson() => {'sections': sections, 'saved_at': savedAt};
  factory Profile.fromJson(Map<String, Object?> j) => Profile(_map(j['sections']), (j['saved_at'] as num?)?.toInt() ?? 0);
}

class ProfileSchedule {
  ProfileSchedule({this.enabled = false, List<Map<String, Object?>>? rules, this.lastTarget}) : rules = rules ?? [];
  bool enabled;
  List<Map<String, Object?>> rules;
  String? lastTarget;
  Map<String, Object?> toJson() => {'enabled': enabled, 'rules': rules, 'last_target': lastTarget};
  factory ProfileSchedule.fromJson(Map<String, Object?> j) =>
      ProfileSchedule(enabled: j['enabled'] == true, rules: _maps(j['rules']), lastTarget: _strOrNull(j['last_target']));
}

/// The paired glasses: one device id per lens (MAC on Android, UUID on iOS).
class PairedGlasses {
  PairedGlasses({required this.pairId, required this.rightId, required this.leftId, this.rightName = '', this.leftName = '', this.serial});
  final String pairId;
  final String rightId;
  final String leftId;
  final String rightName;
  final String leftName;
  final String? serial;
  Map<String, Object?> toJson() =>
      {'pair_id': pairId, 'right_id': rightId, 'left_id': leftId, 'right_name': rightName, 'left_name': leftName, 'serial': serial};
  factory PairedGlasses.fromJson(Map<String, Object?> j) => PairedGlasses(
        pairId: (j['pair_id'] ?? '').toString(),
        rightId: (j['right_id'] ?? '').toString(),
        leftId: (j['left_id'] ?? '').toString(),
        rightName: (j['right_name'] ?? '').toString(),
        leftName: (j['left_name'] ?? '').toString(),
        serial: _strOrNull(j['serial']),
      );
}

/// A saved pair: its name, last seen info and (when not active) its own configuration.
class PairRecord {
  PairRecord({required this.glasses, String? name, this.firmware, this.lastSeen, Map<String, Object?>? config})
      : name = name ?? 'Even G2 ${glasses.pairId}',
        config = config ?? {};
  PairedGlasses glasses;
  String name;
  String? firmware;
  int? lastSeen;
  Map<String, Object?> config;
  Map<String, Object?> toJson() => {'glasses': glasses.toJson(), 'name': name, 'firmware': firmware, 'last_seen': lastSeen, 'config': config};
  factory PairRecord.fromJson(Map<String, Object?> j) => PairRecord(
      glasses: PairedGlasses.fromJson(_map(j['glasses'])),
      name: _strOrNull(j['name']),
      firmware: _strOrNull(j['firmware']),
      lastSeen: (j['last_seen'] as num?)?.toInt(),
      config: _map(j['config']));
}

/// App look and layout (global, not per pair).
class UiPrefs {
  UiPrefs({this.theme = 'system', this.accent = 0xFF2E7D6B, List<String>? homeCards, List<String>? quickTiles, Map<String, bool>? features, this.beta = false, this.devMode = false})
      : homeCards = homeCards ?? [...defaultHomeCards],
        quickTiles = quickTiles ?? [...defaultQuickTiles],
        features = features ?? {};
  String theme; // system | light | dark | green | amber
  int accent;
  List<String> homeCards;
  List<String> quickTiles;
  Map<String, bool> features;
  bool beta;
  bool devMode;

  static const defaultHomeCards = ['glasses', 'quick', 'sync', 'dashboard', 'apps'];
  static const allHomeCards = ['glasses', 'quick', 'sync', 'dashboard', 'apps', 'log'];
  static const defaultQuickTiles = ['silent', 'auto_brightness', 'head_up', 'notifications', 'even_app'];
  static const allQuickTiles = ['silent', 'auto_brightness', 'head_up', 'wear_detection', 'notifications', 'teleprompter', 'navigation', 'even_app'];

  bool feature(String f) => features[f] ?? true;

  Map<String, Object?> toJson() => {
        'theme': theme,
        'accent': accent,
        'home_cards': homeCards,
        'quick_tiles': quickTiles,
        'features': features,
        'beta': beta,
        'dev_mode': devMode,
      };
  factory UiPrefs.fromJson(Map<String, Object?> j) => UiPrefs(
      theme: (j['theme'] ?? 'system').toString(),
      accent: (j['accent'] as num?)?.toInt() ?? 0xFF2E7D6B,
      homeCards: j['home_cards'] is List ? _strs(j['home_cards']) : null,
      quickTiles: j['quick_tiles'] is List ? _strs(j['quick_tiles']) : null,
      features: {for (final e in _map(j['features']).entries) e.key: e.value == true},
      beta: j['beta'] == true,
      devMode: j['dev_mode'] == true);
}

class NavFavorite {
  NavFavorite(this.name, this.query);
  String name;
  String query; // address or "lat,lon"
  Map<String, Object?> toJson() => {'name': name, 'query': query};
  factory NavFavorite.fromJson(Map<String, Object?> j) => NavFavorite((j['name'] ?? '').toString(), (j['query'] ?? '').toString());
}

class NavPrefs {
  NavPrefs({List<NavFavorite>? favorites, this.autoAdvance = true, this.method = 1}) : favorites = favorites ?? [];
  List<NavFavorite> favorites;
  bool autoAdvance;
  int method; // navigation.methodWalking / methodCycling
  Map<String, Object?> toJson() => {'favorites': favorites.map((f) => f.toJson()).toList(), 'auto_advance': autoAdvance, 'method': method};
  factory NavPrefs.fromJson(Map<String, Object?> j) => NavPrefs(
      favorites: _items(j['favorites'], NavFavorite.fromJson),
      autoAdvance: j['auto_advance'] != false,
      method: (j['method'] as num?)?.toInt() ?? 1);
}

class Script {
  Script(this.id, this.name, this.text);
  final String id;
  String name;
  String text;
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'text': text};
  factory Script.fromJson(Map<String, Object?> j) => Script((j['id'] ?? '').toString(), (j['name'] ?? '').toString(), (j['text'] ?? '').toString());
}

class TeleprompterPrefs {
  TeleprompterPrefs({List<Script>? scripts, this.mode = 1, this.intervalMs = 3000, this.charsPerLine = 28, this.countdown = 0})
      : scripts = scripts ?? [];
  List<Script> scripts;
  int mode;
  int intervalMs;
  int charsPerLine;
  int countdown;
  Map<String, Object?> toJson() => {
        'scripts': scripts.map((s) => s.toJson()).toList(),
        'mode': mode,
        'interval_ms': intervalMs,
        'chars_per_line': charsPerLine,
        'countdown': countdown,
      };
  factory TeleprompterPrefs.fromJson(Map<String, Object?> j) => TeleprompterPrefs(
      scripts: _items(j['scripts'], Script.fromJson),
      mode: (j['mode'] as num?)?.toInt() ?? 1,
      intervalMs: (j['interval_ms'] as num?)?.toInt() ?? 3000,
      charsPerLine: (j['chars_per_line'] as num?)?.toInt() ?? 28,
      countdown: (j['countdown'] as num?)?.toInt() ?? 0);
}

/// A user-made image widget (graph / metric / stock chart) pushed as an EvenHub image.
class CustomWidgetSpec {
  CustomWidgetSpec({required this.id, this.type = 'graph', this.title = '', this.values = '', this.url = '', this.unit = '', this.value = '', this.label = '', this.symbol = ''});
  final String id;
  String type, title, values, url, unit, value, label, symbol;
  Map<String, Object?> toJson() =>
      {'id': id, 'type': type, 'title': title, 'values': values, 'url': url, 'unit': unit, 'value': value, 'label': label, 'symbol': symbol};
  factory CustomWidgetSpec.fromJson(Map<String, Object?> j) {
    String s(String k) => (j[k] ?? '').toString();
    return CustomWidgetSpec(id: s('id'), type: s('type').isEmpty ? 'graph' : s('type'), title: s('title'), values: s('values'), url: s('url'), unit: s('unit'), value: s('value'), label: s('label'), symbol: s('symbol'));
  }
}

class AppData {
  // ── global ──
  PairedGlasses? glasses;
  List<PairRecord> pairs = [];
  bool onboarded = false;
  bool autoConnect = true;
  bool restoreOnConnect = true;

  /// The glasses were handed to the official Even app: the app does not connect (or reconnect)
  /// until the user takes them back. Survives restarts.
  bool handedOff = false;
  UiPrefs ui = UiPrefs();
  NotificationPrefs notifications = NotificationPrefs();
  NavPrefs nav = NavPrefs();
  TeleprompterPrefs teleprompter = TeleprompterPrefs();
  String teleprompterScript = '';
  List<CustomWidgetSpec> customWidgets = [];
  NewsCache newsCache = NewsCache();

  int get themeMode => const {'light': 1, 'dark': 2}[ui.theme] ?? (ui.theme == 'green' || ui.theme == 'amber' ? 2 : 0);
  set themeMode(int v) => ui.theme = const ['system', 'light', 'dark'][v.clamp(0, 2)];

  // ── the active pair's configuration ──
  WeatherConfig weather = WeatherConfig(mode: 'auto');
  List<CalEvent> events = [];
  bool h24 = false;
  CalendarSources calendar = CalendarSources();
  List<TaskItem> tasks = [];
  List<NewsItem> news = [];
  NewsConfig newsConfig = NewsConfig();
  List<int> menu = [1, 4, 5, 6, 7, 8];
  List<String> evenhubMenu = [];
  GlassesSettings settings = GlassesSettings();
  StocksConfig stocks = StocksConfig();
  HealthConfig health = HealthConfig();
  LayoutConfig layout = LayoutConfig();
  WatchfaceConfig watchface = WatchfaceConfig();
  Map<String, Profile> profiles = {};
  String? activeProfile;
  ProfileSchedule schedule = ProfileSchedule();

  /// All events the calendar widget gets: typed + ICS (when on) + phone calendars (when on).
  List<CalEvent> get allEvents => [
        ...events,
        if (calendar.icsEnabled && calendar.icsUrl.isNotEmpty) ...calendar.icsEvents,
        if (calendar.phoneEnabled) ...calendar.phoneEvents,
      ]..sort((a, b) => a.start.compareTo(b.start));

  /// One per-pair section as JSON (profile / pair-switch unit).
  Map<String, Object?>? section(String name, {bool includeSecrets = true}) => switch (name) {
        'weather' => weather.toJson(),
        'calendar' => {'events': events.map((e) => e.toJson()).toList(), 'h24': h24, 'sources': calendar.toJson(includeSecrets: includeSecrets)},
        'quicklist' => {'tasks': tasks.map((t) => t.toJson()).toList()},
        'menu' => {'items': menu},
        'evenhub_menu' => {'apps': evenhubMenu},
        'news' => {...newsConfig.toJson(), 'items': news.map((n) => n.toJson()).toList()},
        'stocks' => stocks.toJson(),
        'health' => health.toJson(),
        'settings' => settings.toJson(),
        'layout' => layout.toJson(),
        'watchface' => watchface.toJson(),
        'profiles' => {
            'profiles': profiles.map((k, v) => MapEntry(k, v.toJson())),
            'active': activeProfile,
            'schedule': schedule.toJson(),
          },
        _ => null,
      };

  void applySection(String name, Map<String, Object?> j) {
    switch (name) {
      case 'weather':
        weather = WeatherConfig.fromJson(j);
      case 'calendar':
        events = _items(j['events'], CalEvent.fromJson);
        h24 = j['h24'] == true;
        if (j['sources'] is Map) {
          final keepUrl = calendar.icsUrl;
          calendar = CalendarSources.fromJson(_map(j['sources']));
          if (calendar.icsUrl.isEmpty && keepUrl.isNotEmpty) calendar.icsUrl = keepUrl; // backups leave the link out
        }
      case 'quicklist':
        tasks = _items(j['tasks'], TaskItem.fromJson);
      case 'menu':
        menu = _ints(j['items']);
      case 'evenhub_menu':
        evenhubMenu = _strs(j['apps']);
      case 'news':
        newsConfig = NewsConfig.fromJson(j);
        news = _items(j['items'], NewsItem.fromJson);
      case 'stocks':
        stocks = StocksConfig.fromJson(j);
      case 'health':
        health = HealthConfig.fromJson(j);
      case 'settings':
        settings = GlassesSettings.fromJson(j);
      case 'layout':
        layout = LayoutConfig.fromJson(j);
      case 'watchface':
        watchface = WatchfaceConfig.fromJson(j);
      case 'profiles':
        profiles = {for (final e in _map(j['profiles']).entries) e.key: Profile.fromJson(_map(e.value))};
        activeProfile = _strOrNull(j['active']);
        schedule = ProfileSchedule.fromJson(_map(j['schedule']));
    }
  }

  static const pairSectionNames = [
    'weather', 'calendar', 'quicklist', 'menu', 'evenhub_menu', 'news', 'stocks', 'health', 'settings', 'layout', //
    'watchface', 'profiles',
  ];

  Map<String, Object?> pairSections() => {for (final n in pairSectionNames) n: section(n)};

  void applyPairSections(Map<String, Object?> s) {
    for (final n in pairSectionNames) {
      final v = s[n];
      try {
        applySection(n, v is Map ? v.cast<String, Object?>() : AppData().section(n)!); // defaults for a new pair
      } catch (_) {
        applySection(n, AppData().section(n)!); // unreadable: this section's defaults
      }
    }
  }

  /// Everything, for local storage ([includeSecrets] false = settings backup file: the ICS
  /// link is left out because it usually carries a private token).
  Map<String, Object?> toJson({bool includeSecrets = true}) {
    final j = _toJson(includeSecrets: includeSecrets);
    return includeSecrets ? j : (_withoutSecrets(j) as Map).cast<String, Object?>();
  }

  Map<String, Object?> _toJson({bool includeSecrets = true}) => {
        'version': 2,
        'glasses': glasses?.toJson(),
        'pairs': pairs.map((p) => p.toJson()).toList(),
        'onboarded': onboarded,
        'auto_connect': autoConnect,
        'restore_on_connect': restoreOnConnect,
        'handed_off': handedOff,
        'ui': ui.toJson(),
        'notifications': notifications.toJson(),
        'nav': nav.toJson(),
        'teleprompter': teleprompter.toJson(),
        'teleprompter_script': teleprompterScript,
        'custom_widgets': customWidgets.map((w) => w.toJson()).toList(),
        'news_cache': newsCache.toJson(),
        'pair': {for (final n in pairSectionNames) n: section(n, includeSecrets: includeSecrets)},
        // phase-1 flat keys (still read by older code paths and the first load after an update)
        'events': events.map((e) => e.toJson()).toList(),
        'h24': h24,
        'tasks': tasks.map((t) => t.toJson()).toList(),
        'news': news.map((n) => n.toJson()).toList(),
        'menu': menu,
        'settings': settings.toJson(),
        'weather': weather.toJson(),
        'theme_mode': themeMode,
      };

  static AppData fromJson(Map<String, Object?> j) {
    final d = AppData();
    if (j['glasses'] is Map) d.glasses = _or(() => PairedGlasses.fromJson(_map(j['glasses'])), null);
    d.pairs = _items(j['pairs'], PairRecord.fromJson);
    d.onboarded = j['onboarded'] == true;
    d.autoConnect = j['auto_connect'] != false;
    d.restoreOnConnect = j['restore_on_connect'] != false;
    d.handedOff = j['handed_off'] == true;
    if (j['ui'] is Map) {
      d.ui = _or(() => UiPrefs.fromJson(_map(j['ui'])), UiPrefs());
    } else if (j['theme_mode'] is num) {
      d.themeMode = (j['theme_mode'] as num).toInt();
    }
    if (j['notifications'] is Map) d.notifications = _or(() => NotificationPrefs.fromJson(_map(j['notifications'])), NotificationPrefs());
    if (j['nav'] is Map) d.nav = _or(() => NavPrefs.fromJson(_map(j['nav'])), NavPrefs());
    if (j['teleprompter'] is Map) d.teleprompter = _or(() => TeleprompterPrefs.fromJson(_map(j['teleprompter'])), TeleprompterPrefs());
    d.teleprompterScript = (j['teleprompter_script'] ?? '').toString();
    d.customWidgets = _items(j['custom_widgets'], CustomWidgetSpec.fromJson);
    if (j['news_cache'] is Map) d.newsCache = _or(() => NewsCache.fromJson(_map(j['news_cache'])), NewsCache());
    if (j['pair'] is Map) {
      d.applyPairSections(_map(j['pair']));
    } else {
      // phase-1 layout: flat keys
      d.events = _items(j['events'], CalEvent.fromJson);
      d.h24 = j['h24'] == true;
      d.tasks = _items(j['tasks'], TaskItem.fromJson);
      d.news = _items(j['news'], NewsItem.fromJson);
      if (d.news.isNotEmpty) d.newsConfig.mode = 'manual';
      if (j['menu'] is List) d.menu = _ints(j['menu']);
      if (j['settings'] is Map) d.settings = _or(() => GlassesSettings.fromJson(_map(j['settings'])), GlassesSettings());
      if (j['weather'] is Map) d.weather = _or(() => WeatherConfig.fromJson(_map(j['weather'])), WeatherConfig(mode: 'auto'));
    }
    // A phase-1 install had a single pair and no pair list.
    final g = d.glasses;
    if (g != null && !d.pairs.any((p) => p.glasses.pairId == g.pairId)) d.pairs.add(PairRecord(glasses: g));
    return d;
  }

  PairRecord? get activePair {
    final g = glasses;
    if (g == null) return null;
    for (final p in pairs) {
      if (p.glasses.pairId == g.pairId) return p;
    }
    return null;
  }
}
