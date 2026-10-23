/// "Report a problem": a single, scrubbed JSON diagnostics bundle the user can preview and then
/// share (Android share sheet) or save. Nothing is uploaded; nothing leaves the phone unless the
/// user shares the file themselves.
///
/// What goes in: app / Android / BLE adapter info, permission states, the connection history,
/// the hub log, recent raw frames (header fields always, payload bytes only for services that
/// carry no user text), sync state per section, Even AI / live-translate state events, on-device
/// model stats, non-secret settings (as flags and counts), and recent uncaught errors.
///
/// Scrubbing is deterministic (same input, same output) and on by default:
///
/// * settings are summarised from an allow-list (switches, numbers, counts), never dumped;
/// * every string that goes in passes [Scrubber.text]: known personal values collected from the
///   app's own data (task / event / news titles, teleprompter scripts, city / place, names,
///   AI questions and replies, notification content, ICS link, API keys, …) are replaced by a
///   typed placeholder, then patterns catch what is not known in advance (API keys, ICS and
///   query-string URLs, e-mail, phone numbers, coordinates, quoted text in log lines);
/// * lens Bluetooth addresses, lens names and the serial number are replaced by stable aliases
///   (lens-R / lens-L / serial) unless the user turns that off;
/// * frame payloads of services that carry user text (notifications, Even AI, translate,
///   teleprompter, quicklist, dashboard, navigation, files, EvenHub, …) keep only their
///   top-level numeric header fields; every byte string becomes `<n bytes redacted>`.
library;

import 'dart:convert';

import '../ai/config/ai_config.dart';
import '../ai/config/secret_store.dart' show maskKey;
import '../hub/even_ai_hub.dart';
import '../hub/glasses_session.dart';
import '../hub/hub_controller.dart';
import '../hub/models.dart';
import '../protocol/pb.dart' show hex;
import '../protocol/sids.dart';
import 'diagnostics_recorder.dart';

const diagnosticsFormat = 'g2hub-diagnostics';

/// What the user chose on the Report a problem screen.
class ReportOptions {
  const ReportOptions({this.anonymiseLens = true, this.maxFrames = 200, this.maxLogLines = 500});

  /// Replace lens Bluetooth addresses / names and the serial number with lens-R / lens-L / serial.
  final bool anonymiseLens;

  /// Most recent frames to include (0 = none).
  final int maxFrames;
  final int maxLogLines;
}

/// The finished bundle: exactly what the preview shows and what is shared or saved.
class DiagnosticsBundle {
  const DiagnosticsBundle(this.fileName, this.text);
  final String fileName;
  final String text;
}

/// Platform facts gathered before building (tests pass fixed values).
class PlatformFacts {
  const PlatformFacts({this.device = const {}, this.permissions = const {}, this.ble = const {}});

  /// Android version, model, app versionName / versionCode, …
  final Map<String, Object?> device;

  /// permission name → granted / denied / permanentlyDenied / …
  final Map<String, String> permissions;

  /// Adapter state and LE capabilities.
  final Map<String, Object?> ble;
}

// ── scrubbing ───────────────────────────────────────────────────────────────────────────────

/// Services whose payloads never carry user text: shown as hex (unless a known personal value
/// or a long printable run is found in the bytes anyway). Everything else is redacted.
const Set<int> plainPayloadSids = {
  sidMenu, sidSettings, sidOnboarding, sidModuleConfig, sidDeviceConfig, sidCase, //
  0xC0, 0xC1, 0xC2, 0xC3, // OTA control
};

class _Known {
  _Known(this.value, this.label, this.secret) : lower = value.toLowerCase();
  final String value;
  final String lower;
  final String label;

  /// Secrets match anywhere; personal values only as whole words.
  final bool secret;
  RegExp? _re;
  RegExp get re => _re ??= RegExp(
        secret ? RegExp.escape(value) : '(?<![A-Za-z0-9])${RegExp.escape(value)}(?![A-Za-z0-9])',
        caseSensitive: false,
      );
}

/// Deterministic text scrubber. Build it with every personal / secret value the app knows,
/// then run every outgoing string through [text].
class Scrubber {
  Scrubber({this.anonymiseLens = true});
  final bool anonymiseLens;
  final Map<String, _Known> _known = {};
  final Map<String, String> _aliases = {}; // lowercase id → alias (lens ids, serial)
  final List<List<int>> _byteNeedles = [];

  /// Values shorter than this are not matched (they would hit ordinary words).
  static const minLength = 3;

  /// A personal value (task title, city, name, …). Long texts also add their lines and
  /// sentences, so a fragment quoted in a log line is caught too.
  void personal(String label, String? value) {
    final v = _clean(value);
    if (v == null) return;
    _add(v, label, secret: false);
    if (v.length > 24) {
      var n = 0;
      for (final part in v.split(RegExp(r'[\n\r]+|(?<=[.!?;])\s+'))) {
        final p = part.trim();
        if (p.length >= 12 && p != v) {
          _add(p, label, secret: false);
          if (++n >= 50) break;
        }
      }
    }
  }

  /// A secret (API key, private link): matched anywhere, even inside a longer token.
  void secret(String label, String? value) {
    final v = _clean(value);
    if (v == null || v.length < 6) return;
    _add(v, label, secret: true);
  }

  /// A lens id / name / serial: replaced by [alias] when [anonymiseLens] is on.
  void lensId(String? id, String alias) {
    final v = _clean(id);
    if (v == null || !anonymiseLens) return;
    _aliases[v.toLowerCase()] = alias;
    _byteNeedles.add(utf8.encode(v));
    final mac = RegExp(r'^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$');
    if (mac.hasMatch(v)) {
      final b = [for (final p in v.split(RegExp('[:-]'))) int.parse(p, radix: 16)];
      _byteNeedles
        ..add(b)
        ..add(b.reversed.toList());
    }
  }

  String? _clean(String? v) {
    final t = v?.replaceAll('\u0000', '').trim();
    return t == null || t.length < minLength ? null : t;
  }

  void _add(String v, String label, {required bool secret}) {
    final k = v.toLowerCase();
    final old = _known[k];
    if (old != null && (old.secret || !secret)) return;
    _known[k] = _Known(v, label, secret);
    _byteNeedles.add(utf8.encode(v));
  }

  List<_Known>? _sorted;
  List<_Known> get _ordered => _sorted ??= (_known.values.toList()
    ..sort((a, b) {
      final c = b.value.length.compareTo(a.value.length);
      return c != 0 ? c : a.lower.compareTo(b.lower);
    }));

  List<MapEntry<String, String>>? _aliasList;

  static final _patterns = <(RegExp, String)>[
    // API keys and tokens.
    (RegExp(r'\bsk-[A-Za-z0-9_\-]{10,}'), '<api-key>'),
    (RegExp(r'\bAIza[0-9A-Za-z_\-]{20,}'), '<api-key>'),
    (RegExp(r'\b(?:gh[pousr]|xox[abprs])[-_][A-Za-z0-9_\-]{10,}'), '<api-key>'),
    (RegExp(r'\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]+'), '<token>'),
    (
      RegExp(r'\b(bearer|token|api[_-]?key|x-api-key|apikey|key|secret|password|authorization|auth)(\s*[:=]\s*|\s+)([A-Za-z0-9._~+/\-]{12,}=*)', caseSensitive: false),
      r'$1$2<redacted>'
    ),
    // Private calendar links, then credentials and query strings in any other link.
    (RegExp(r'\b(?:webcal|https?)://[^\s"<>\x00]*\.ics\b[^\s"<>\x00]*', caseSensitive: false), '<ics-url>'),
    (RegExp(r'\bwebcal://[^\s"<>\x00]+', caseSensitive: false), '<ics-url>'),
    (RegExp(r'\b(https?://)[^/\s"<>@\x00]+@', caseSensitive: false), r'$1<user>@'),
    (RegExp(r'\b(https?://[^\s"<>?#\x00]+)\?[^\s"<>\x00]*', caseSensitive: false), r'$1?<query>'),
    // Contact details.
    (RegExp(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}'), '<email>'),
    (RegExp(r'\+\d[\d \-()]{7,}\d'), '<phone>'),
    // Coordinates.
    (RegExp(r'-?\b\d{1,3}\.\d{3,}\s*,\s*-?\d{1,3}\.\d{3,}\b'), '<lat,lon>'),
    (RegExp(r'\b(lat|lon|lng|latitude|longitude)(\W{1,3})-?\d{1,3}\.\d+', caseSensitive: false), r'$1$2<redacted>'),
  ];

  static final _lensPatterns = <(RegExp, String)>[
    (RegExp(r'\b([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b'), '<ble-address>'),
    (RegExp(r'\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b'), '<ble-id>'),
    (RegExp(r'(Even G2_\w+?_[LR]_)[0-9A-Za-z]+'), r'$1<id>'),
  ];

  /// Free text (log lines, error messages): quoted spans and a few known log shapes that carry
  /// user content.
  static final _freePatterns = <(RegExp, String Function(Match))>[
    (RegExp(r'"([^"\n]*)"'), (m) => m[1]!.isEmpty ? '""' : '"<${m[1]!.length} chars redacted>"'),
    (RegExp('“([^”\n]*)”'), (m) => '"<${m[1]!.length} chars redacted>"'),
    (RegExp('«([^»\n]*)»'), (m) => '"<${m[1]!.length} chars redacted>"'),
    // Assistant tool calls are logged as name(arguments).
    (RegExp(r'(Even AI tool: [A-Za-z_]+)\([^\n]*\)'), (m) => '${m[1]}(<redacted>)'),
    // Notification log lines name the app.
    (RegExp(r'(Notification from )[^:\n]+:'), (m) => '${m[1]}<app>:'),
    // EvenHub page errors may quote the app's own data.
    (RegExp(r'(\] page error: )[^\n]*'), (m) => '${m[1]}<redacted>'),
  ];

  /// Scrub [s]. [free] adds the free-text rules (quoted spans etc.).
  String text(String s, {bool free = true}) {
    if (s.isEmpty) return s;
    var out = s.replaceAll('\u0000', '');
    final labels = <String>[];
    String mark(String label) {
      labels.add(label);
      return '\u0000${labels.length - 1}\u0000';
    }

    // 1. Known values, longest first; a match becomes a sentinel so shorter values cannot match
    //    inside a placeholder.
    var lower = out.toLowerCase();
    for (final k in _ordered) {
      if (!lower.contains(k.lower)) continue;
      final next = out.replaceAll(k.re, mark('<${k.label}>'));
      if (next != out) {
        out = next;
        lower = out.toLowerCase();
      } else {
        labels.removeLast();
      }
    }
    // 2. Lens ids / serial → aliases.
    if (anonymiseLens) {
      final aliases = _aliasList ??= (_aliases.entries.toList()..sort((a, b) => b.key.length.compareTo(a.key.length)));
      for (final e in aliases) {
        if (!lower.contains(e.key)) continue;
        out = out.replaceAll(RegExp(RegExp.escape(e.key), caseSensitive: false), mark(e.value));
        lower = out.toLowerCase();
      }
      for (final (re, rep) in _lensPatterns) {
        out = out.replaceAllMapped(re, (m) => mark(_expand(rep, m)));
      }
    }
    // 3. Patterns.
    for (final (re, rep) in _patterns) {
      out = out.replaceAllMapped(re, (m) => _expand(rep, m));
    }
    if (free) {
      for (final (re, f) in _freePatterns) {
        out = out.replaceAllMapped(re, f);
      }
    }
    // 4. Sentinels → placeholders.
    return out.replaceAllMapped(RegExp('\u0000(\\d+)\u0000'), (m) => labels[int.parse(m[1]!)]);
  }

  static String _expand(String rep, Match m) => rep.replaceAllMapped(RegExp(r'\$(\d)'), (x) => m[int.parse(x[1]!)] ?? '');

  /// True when [bytes] contain a known value (UTF-8) or a lens address (text or raw).
  bool bytesContainKnown(List<int> bytes) {
    for (final n in _byteNeedles) {
      if (_indexOf(bytes, n) >= 0) return true;
    }
    return false;
  }

  static int _indexOf(List<int> h, List<int> n) {
    if (n.isEmpty || n.length > h.length) return -1;
    outer:
    for (var i = 0; i <= h.length - n.length; i++) {
      for (var j = 0; j < n.length; j++) {
        if (h[i + j] != n[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}

/// True when [b] holds a run of [min] or more printable ASCII bytes (likely text).
bool hasPrintableRun(List<int> b, {int min = 8}) {
  var run = 0;
  for (final x in b) {
    if (x >= 0x20 && x < 0x7F) {
      if (++run >= min) return true;
    } else {
      run = 0;
    }
  }
  return false;
}

/// Top-level protobuf fields with every byte string replaced: "1=3", "2=17",
/// "3:<12 bytes redacted>". Only numeric fields are shown. Null unless the payload parses as a
/// G2 message exactly (starts with the field-1 command varint, every length in range, nothing
/// left over), so raw bytes or text are never read as numbers.
List<String>? redactedFields(List<int> payload) {
  final out = <String>[];
  var i = 0;
  final n = payload.length;
  (int, int)? varint(int at) {
    var v = 0;
    for (var k = 0; k < 10; k++) {
      if (at + k >= n) return null;
      final b = payload[at + k];
      if (k < 9) v |= (b & 0x7F) << (7 * k);
      if (b & 0x80 == 0) return (v, at + k + 1);
    }
    return null;
  }

  while (i < n) {
    final key = varint(i);
    if (key == null) return null;
    final field = key.$1 >> 3, wire = key.$1 & 7;
    if (field < 1 || field > 64) return null;
    if (out.isEmpty && (field != 1 || wire != 0)) return null;
    i = key.$2;
    switch (wire) {
      case 0:
        final v = varint(i);
        if (v == null) return null;
        out.add('$field=${v.$1}');
        i = v.$2;
      case 2:
        final len = varint(i);
        if (len == null || len.$1 < 0 || len.$2 + len.$1 > n) return null;
        out.add('$field:<${len.$1} bytes redacted>');
        i = len.$2 + len.$1;
      case 1 || 5:
        final size = wire == 1 ? 8 : 4;
        if (i + size > n) return null;
        out.add('$field:<$size bytes redacted>');
        i += size;
      default:
        return null;
    }
  }
  return out.isEmpty ? null : out;
}

/// One frame for the bundle. Payloads of text-carrying services keep only header fields.
Map<String, Object?> frameJson(WireFrame w, Scrubber s) {
  final plain = plainPayloadSids.contains(w.sid) && !s.bytesContainKnown(w.payload) && !hasPrintableRun(w.payload);
  return {
    't': w.at.toUtc().toIso8601String(),
    'dir': w.rx ? 'rx' : 'tx',
    'lens': w.side.name == 'right' ? 'R' : 'L',
    'sid': '0x${w.sid.toRadixString(16).padLeft(2, '0')}',
    'service': sidName(w.sid),
    'flag': '0x${w.flag.toRadixString(16).padLeft(2, '0')}',
    'len': w.payload.length,
    if (plain) 'hex': hex(w.payload),
    if (!plain) ...{
      'fields': redactedFields(w.payload),
      'payload': '<${w.payload.length} bytes redacted>',
    },
  };
}

// ── building ────────────────────────────────────────────────────────────────────────────────

String _two(int v) => v.toString().padLeft(2, '0');

String reportFileName(DateTime t) {
  final u = t.toUtc();
  return 'g2hub-report-${u.year}${_two(u.month)}${_two(u.day)}-${_two(u.hour)}${_two(u.minute)}${_two(u.second)}Z.json';
}

String _utc(DateTime t) => t.toUtc().toIso8601String();
String? _unix(int? s) => s == null ? null : _utc(DateTime.fromMillisecondsSinceEpoch(s * 1000));

/// Everything personal or secret the app knows about, for [Scrubber].
Future<Scrubber> buildScrubber(HubController hub, {AiHub? ai, bool anonymiseLens = true}) async {
  final s = Scrubber(anonymiseLens: anonymiseLens);
  final d = hub.data;

  // Lens addresses / names / serial: stable aliases.
  void lenses(PairedGlasses g, String prefix) {
    s.lensId(g.rightId, '${prefix}lens-R');
    s.lensId(g.leftId, '${prefix}lens-L');
    s.lensId(g.rightName, '${prefix}lens-R-name');
    s.lensId(g.leftName, '${prefix}lens-L-name');
    s.lensId(g.serial, '${prefix}serial');
  }

  if (d.glasses != null) lenses(d.glasses!, '');
  var i = 1;
  for (final p in d.pairs) {
    if (p.glasses.pairId == d.glasses?.pairId) continue;
    lenses(p.glasses, 'pair${++i}-');
  }

  // Names the user gave things.
  for (final p in d.pairs) {
    if (p.name != 'Even G2 ${p.glasses.pairId}') s.personal('name', p.name);
  }
  void calendar(CalendarSources c) {
    s.secret('ics-url', c.icsUrl);
    for (final e in [...c.icsEvents, ...c.phoneEvents]) {
      s.personal('event-title', e.title);
      s.personal('event-location', e.location);
    }
  }

  // The active pair's configuration…
  void weather(WeatherConfig w) {
    s.personal('city', w.city);
    s.personal('place', w.place);
    for (final v in [w.lat, w.lon]) {
      if (v == null) continue;
      s.personal('coordinate', '$v');
      for (var n = 2; n <= 6; n++) {
        s.personal('coordinate', v.toStringAsFixed(n));
      }
    }
    for (final v in w.last.values) {
      if (v is String) s.personal('place', v);
    }
  }

  weather(d.weather);
  calendar(d.calendar);
  for (final e in d.events) {
    s.personal('event-title', e.title);
    s.personal('event-location', e.location);
  }
  for (final t in d.tasks) {
    s.personal('task-title', t.title);
  }
  for (final n in d.news) {
    s.personal('news-title', n.title);
    s.personal('news-source', n.source);
    s.personal('news-text', n.content);
  }
  for (final f in d.newsConfig.feeds) {
    s.secret('feed-url', f.contains('?') ? f : null);
  }
  for (final st in d.newsCache.stories) {
    s.personal('news-title', st['title']?.toString());
  }
  for (final t in d.newsCache.seenTitles) {
    s.personal('news-title', t);
  }
  for (final p in d.profiles.keys) {
    s.personal('profile-name', p);
  }
  // …and the other pairs' stored configurations (same shapes, as JSON).
  void walkJson(Object? v, String key) {
    if (v is Map) {
      for (final e in v.entries) {
        walkJson(e.value, e.key.toString());
      }
    } else if (v is List) {
      for (final x in v) {
        walkJson(x, key);
      }
    } else if (v is String) {
      switch (key) {
        case 'title' || 'location' || 'city' || 'place' || 'source' || 'content' || 'name' || 'text':
          s.personal(key == 'content' || key == 'text' ? 'text' : key, v);
        case 'ics_url':
          s.secret('ics-url', v);
      }
    }
  }

  for (final p in d.pairs) {
    walkJson(p.config, '');
  }
  for (final p in d.profiles.values) {
    walkJson(p.sections, '');
  }

  // Global data.
  for (final sc in d.teleprompter.scripts) {
    s.personal('script-name', sc.name);
    s.personal('teleprompter-text', sc.text);
  }
  s.personal('teleprompter-text', d.teleprompterScript);
  for (final f in d.nav.favorites) {
    s.personal('place', f.name);
    s.personal('place', f.query);
  }
  for (final w in d.customWidgets) {
    s.personal('widget-title', w.title);
    s.personal('widget-label', w.label);
    s.personal('widget-value', w.value);
    s.personal('widget-values', w.values);
    s.secret('widget-url', w.url);
  }
  for (final name in d.notifications.appNames.values) {
    s.personal('app-name', name);
  }
  for (final e in hub.services.notifications.recent) {
    s.personal('app-name', e.n.appName);
    s.personal('notification-title', e.n.title);
    s.personal('notification-text', e.n.text);
    s.personal('notification-text', e.n.subText);
  }

  // AI: keys, endpoints, prompts, history, what is on screen now.
  if (ai != null) {
    try {
      final all = await ai.secrets.readAll();
      for (final v in all.values) {
        s.secret('api-key', v);
      }
    } catch (_) {/* keystore unavailable */}
    final c = ai.settings;
    const defaultNames = {'Claude', 'Deepgram', 'On this phone', 'Model', 'Speech', 'Gemini', 'OpenAI', 'Whisper'};
    for (final p in c.llmProfiles) {
      if (!defaultNames.contains(p.name)) s.personal('profile-name', p.name);
      s.secret('endpoint', p.baseUrl);
      s.personal('system-prompt', p.systemPrompt);
    }
    for (final p in c.sttProfiles) {
      if (!defaultNames.contains(p.name)) s.personal('profile-name', p.name);
      s.secret('endpoint', p.baseUrl);
    }
    s.personal('ai-text', c.fallbackQuestion);
    s.personal('ai-text', c.cannedReply);
    for (final sc in c.customShortcuts) {
      s.personal('shortcut-phrase', sc.phrase);
    }
    for (final h in ai.history) {
      s.personal('ai-question', h.question);
      s.personal('ai-reply', h.reply);
      for (final a in h.actions) {
        final open = a.indexOf('(');
        if (open > 0 && a.endsWith(')')) s.personal('ai-text', a.substring(open + 1, a.length - 1));
      }
    }
    final e = ai.evenAi;
    if (e != null) {
      s.personal('ai-question', e.question);
      s.personal('ai-reply', e.reply);
    }
    for (final l in ai.live.lines) {
      s.personal('transcript', l.original);
      s.personal('translation', l.translated);
    }
  }
  return s;
}

/// Build the bundle. [now] and [facts] are injectable for tests.
Future<DiagnosticsBundle> buildDiagnosticsReport({
  required HubController hub,
  AiHub? ai,
  DiagnosticsRecorder? recorder,
  PlatformFacts facts = const PlatformFacts(),
  String description = '',
  ReportOptions options = const ReportOptions(),
  String appVersion = '',
  DateTime? now,
}) async {
  final at = now ?? DateTime.now();
  final rec = recorder ?? DiagnosticsRecorder.instance;
  final s = await buildScrubber(hub, ai: ai, anonymiseLens: options.anonymiseLens);
  final d = hub.data;
  final svc = hub.services;
  String sc(String? v) => s.text(v ?? '');

  final frames = svc.wire.length <= options.maxFrames ? svc.wire : svc.wire.sublist(svc.wire.length - options.maxFrames);
  final logs = hub.logs.length <= options.maxLogLines ? hub.logs : hub.logs.sublist(hub.logs.length - options.maxLogLines);
  final g = hub.glasses;

  final report = <String, Object?>{
    'format': diagnosticsFormat,
    'version': 1,
    'created_at': _utc(at),
    'tz_offset_min': at.timeZoneOffset.inMinutes,
    'scrubbed': true,
    'options': {'anonymise_lens': options.anonymiseLens, 'max_frames': options.maxFrames, 'max_log_lines': options.maxLogLines},
    'description': sc(description.trim()),
    'app': {'version': appVersion, ...{for (final e in facts.device.entries) if (e.key.startsWith('app_')) e.key.substring(4): e.value}},
    'device': {for (final e in facts.device.entries) if (!e.key.startsWith('app_')) e.key: e.value is String ? sc(e.value as String) : e.value},
    'ble': {for (final e in facts.ble.entries) e.key: e.value is String ? sc(e.value as String) : e.value},
    'permissions': {
      ...facts.permissions,
      'notification_access': svc.notifications.supported ? (svc.notifications.accessGranted ? 'granted' : 'denied') : 'n/a',
      'health': svc.healthAccess ? 'granted' : (svc.healthAvailability?.name ?? 'not checked'),
    },
    'connection': {
      'status': hub.status.name,
      'want_connected': hub.wantConnected,
      'auto_connect': d.autoConnect,
      'restore_on_connect': d.restoreOnConnect,
      'handed_off': d.handedOff,
      'paired': d.glasses != null,
      'pairs': d.pairs.length,
      'history': [
        for (final e in hub.connectionHistory)
          {'t': _utc(e.at), 'event': e.event, if (e.detail.isNotEmpty) 'detail': sc(e.detail), 'attempt': e.attempt},
      ],
    },
    'glasses': {
      if (d.glasses != null) 'pair_id': d.glasses!.pairId,
      'lens_right': d.glasses == null ? null : sc(d.glasses!.rightId),
      'lens_left': d.glasses == null ? null : sc(d.glasses!.leftId),
      'serial': d.glasses?.serial == null ? null : sc(d.glasses!.serial),
      'battery': g?.battery,
      'charging': g?.charging,
      'case_battery': g?.caseBattery,
      'worn': g?.worn,
      'firmware_left': g?.leftVersion,
      'firmware_right': g?.rightVersion,
      'silent_mode': g?.silentMode,
      'brightness': g?.brightnessLevel,
      'brightness_auto': g?.brightnessAuto,
      'head_up_angle': g?.headUpAngle,
      'foreground_app': g?.foregroundApp,
      'display_timeout': g?.displayTimeout,
      'last_keepalive_echo': g?.lastKeepaliveEcho == null ? null : _utc(g!.lastKeepaliveEcho!),
      'saved_pairs': [
        for (final p in d.pairs) {'firmware': p.firmware, 'last_seen': _unix(p.lastSeen), 'active': p.glasses.pairId == d.glasses?.pairId},
      ],
    },
    'settings': _settings(d, hub),
    'sync': {
      'connected': svc.sync.connected,
      'busy': svc.sync.busy,
      'sections': [
        for (final x in svc.sync.sections)
          {
            'key': x.key,
            'status': x.status.name,
            'dirty': svc.sync.isDirty(x.key),
            'dirty_since': x.dirtySince == null ? null : _utc(x.dirtySince!),
            'last_push': x.lastSynced == null ? null : _utc(x.lastSynced!),
            'failures': x.failures,
            'last_error': x.lastError == null ? null : sc(x.lastError),
            'restore': x.restore,
          },
      ],
      'recent_pushes': svc.sync.history.length <= 50 ? svc.sync.history : svc.sync.history.sublist(svc.sync.history.length - 50),
    },
    'services': {
      'weather_error': svc.weatherError == null ? null : sc(svc.weatherError),
      'news_error': svc.newsError == null ? null : sc(svc.newsError),
      'stocks_error': svc.stocksError == null ? null : sc(svc.stocksError),
      'evenhub_running': svc.evenhub?.running,
      'evenhub_apps': _evenhubApps(hub),
    },
    'notifications': _notifications(hub),
    'ai': ai == null ? null : await _ai(ai, rec, sc),
    'frames': {
      'recorded_in_developer_mode': d.ui.devMode,
      'total_buffered': svc.wire.length,
      'included': frames.length,
      'items': [for (final w in frames) frameJson(w, s)],
    },
    'errors': [
      for (final e in rec.errors) {'t': _utc(e.at), 'source': e.source, 'error': sc(e.error), 'stack': s.text(e.stack, free: false)},
    ],
    'log': [
      for (final l in logs) '${_utc(l.at)} ${l.level.name.padRight(4)} ${sc(l.message)}',
    ],
    'not_included': const [
      'API keys and tokens (only whether a key is set, masked)',
      'calendar links, event, task, news and widget titles, teleprompter text',
      'location (GPS, city, saved places)',
      'notification titles, text and app names (only per-package counts)',
      'AI questions, replies, transcripts and translations',
      'EvenHub app data',
      'text inside frames of text-carrying services (only header fields and byte counts)',
      'lens Bluetooth addresses and serial number (unless anonymisation was turned off)',
    ],
  };
  final text = const JsonEncoder.withIndent('  ').convert(report);
  return DiagnosticsBundle(reportFileName(at), text);
}

Map<String, Object?> _settings(AppData d, HubController hub) {
  final w = d.weather;
  final c = d.calendar;
  final n = d.notifications;
  return {
    'onboarded': d.onboarded,
    'ui': {
      'theme': d.ui.theme,
      'home_cards': d.ui.homeCards,
      'quick_tiles': d.ui.quickTiles,
      'features_off': [for (final e in d.ui.features.entries) if (!e.value) e.key]..sort(),
      'beta': d.ui.beta,
      'developer_mode': d.ui.devMode,
    },
    'glasses_settings': d.settings.toJson(),
    'layout': d.layout.toJson(),
    'menu': d.menu,
    'evenhub_menu_items': d.evenhubMenu.length,
    'weather': {
      'mode': w.mode,
      'use_gps': w.useGps,
      'fahrenheit': w.fahrenheit,
      'has_city': w.city.isNotEmpty,
      'has_coordinates': w.lat != null && w.lon != null,
      'last_update': _unix(w.lastAt),
    },
    'calendar': {
      'typed_events': d.events.length,
      'h24': d.h24,
      'ics_enabled': c.icsEnabled,
      'ics_link_set': c.icsUrl.isNotEmpty,
      'ics_events': c.icsEvents.length,
      'ics_last_try': _unix(c.icsLastTry),
      'ics_last_ok': _unix(c.icsLastOk),
      'phone_enabled': c.phoneEnabled,
      'phone_calendars_selected': c.phoneCalendarIds.length,
      'phone_events': c.phoneEvents.length,
    },
    'tasks': {'count': d.tasks.length, 'completed': d.tasks.where((t) => t.completed).length},
    'news': {
      'mode': d.newsConfig.mode,
      'feeds': d.newsConfig.feeds.length,
      'own_items': d.news.length,
      'cached_stories': d.newsCache.stories.length,
      'fetched_at': d.newsCache.fetchedAt == 0 ? null : _unix(d.newsCache.fetchedAt),
      'last_pushed_at': _unix(d.newsCache.lastPushedAt),
    },
    'stocks': {'enabled': d.stocks.enabled, 'symbols': d.stocks.symbols.length, 'last_update': _unix(d.stocks.lastAt)},
    'health': {'enabled': d.health.enabled, 'source': d.health.source, 'show_card': d.health.showCard, 'imported_at': _unix(d.health.importedAt)},
    'watchface': {'style': d.watchface.style, 'left': d.watchface.left, 'right': d.watchface.right, 'pos': d.watchface.pos, 'uploaded_ok': d.watchface.uploadedOk},
    'profiles': {'count': d.profiles.length, 'active_set': d.activeProfile != null, 'schedule_enabled': d.schedule.enabled, 'schedule_rules': d.schedule.rules.length},
    'notifications': {
      'enabled': n.enabled,
      'new_apps_allowed': n.newAppsAllowed,
      'apps_allowed': n.apps.values.where((v) => v).length,
      'apps_blocked': n.apps.values.where((v) => !v).length,
      'quiet_hours': n.quietHours,
      'skip_ongoing': n.skipOngoing,
      'show_content': n.showContent,
      'display_seconds': n.displaySeconds,
      'low_battery_alerts': n.lowBatteryAlerts,
    },
    'navigation': {'favorites': d.nav.favorites.length, 'auto_advance': d.nav.autoAdvance, 'method': d.nav.method},
    'teleprompter': {
      'scripts': d.teleprompter.scripts.length,
      'mode': d.teleprompter.mode,
      'interval_ms': d.teleprompter.intervalMs,
      'chars_per_line': d.teleprompter.charsPerLine,
      'countdown': d.teleprompter.countdown,
    },
    'custom_widgets': {for (final t in d.customWidgets.map((w) => w.type).toSet().toList()..sort()) t: d.customWidgets.where((w) => w.type == t).length},
  };
}

List<String> _evenhubApps(HubController hub) {
  try {
    return (hub.services.registry?.load().keys.toList() ?? <String>[])..sort();
  } catch (_) {
    return const [];
  }
}

/// Package-level counts only: no titles, text or app names.
Map<String, Object?> _notifications(HubController hub) {
  final byPkg = <String, Map<String, int>>{};
  for (final e in hub.services.notifications.recent) {
    final m = byPkg.putIfAbsent(e.n.package, () => {});
    m['received'] = (m['received'] ?? 0) + 1;
    m['verdict_${e.verdict.name}'] = (m['verdict_${e.verdict.name}'] ?? 0) + 1;
    final r = e.result;
    final outcome = r == null ? 'pending' : (r == 'shown' ? 'shown' : (r == 'waiting for the glasses' ? 'waiting' : 'failed'));
    m[outcome] = (m[outcome] ?? 0) + 1;
  }
  final keys = byPkg.keys.toList()..sort();
  return {
    'supported': hub.services.notifications.supported,
    'recent': {for (final k in keys) k: byPkg[k]},
  };
}

Future<Map<String, Object?>> _ai(AiHub ai, DiagnosticsRecorder rec, String Function(String?) sc) async {
  final c = ai.settings;
  String llm(LlmProfile? p) => p == null ? 'none' : '${p.provider.name}:${p.model}';
  Future<Map<String, Object?>> llmJson(LlmProfile p) async => {
        'provider': p.provider.name,
        'model': sc(p.model),
        'endpoint': p.baseUrl.isEmpty ? 'default' : (p.baseUrl.trim().startsWith('https://') ? 'custom https' : 'custom http'),
        'max_tokens': p.maxTokens,
        'tools': p.toolsEnabled,
        'custom_system_prompt': p.systemPrompt.trim().isNotEmpty,
        'key': maskKey(await _key(ai, 'llm_key:${p.id}')),
      };
  final local = ai.local;
  final run = local?.lastRun;
  final e = ai.evenAi;
  final live = ai.live;
  return {
    'settings': {
      'mode': c.mode.name,
      'listen': c.listen,
      'listen_seconds': c.listenSeconds,
      'show_question': c.showQuestion,
      'voice_shortcuts': c.voiceShortcuts,
      'custom_shortcuts': c.customShortcuts.length,
      'tools': c.tools,
      'auto_close_reply': c.autoCloseReply,
      'assistant': llm(c.llmById(c.assistantProfileId)),
      'assistant_fallback': llm(c.llmById(c.assistantFallbackProfileId)),
      'translation_engine': c.translationEngine.name,
      'translation': llm(c.llmById(c.translationProfileId)),
      'stt': c.sttById(c.sttProfileId)?.provider.name ?? 'none',
      'stt_fallback': c.sttById(c.sttFallbackProfileId)?.provider.name ?? 'none',
      'translate': '${c.translateSrc}>${c.translateDst}',
      'translate_hands_free': c.translateHandsFree,
      'live_source': c.liveSource,
      'live_idle_stop_min': c.liveIdleStopMin,
      'vad_engine': c.vadEngine,
      'vad_sensitivity': c.vadSensitivity.name,
      'vad_silence_ms': c.vadSilenceMs,
      'local_idle_unload_min': c.localIdleUnloadMin,
      'local_slow_s': c.localSlowSec,
    },
    'llm_profiles': [for (final p in c.llmProfiles) await llmJson(p)],
    'stt_profiles': [
      for (final p in c.sttProfiles)
        {
          'provider': p.provider.name,
          'model': sc(p.model),
          'language': p.language,
          'endpoint': p.baseUrl.isEmpty ? 'default' : 'custom',
          'key': maskKey(await _key(ai, 'stt_key:${p.id}')),
        },
    ],
    'problems': {
      'assistant': ai.assistantProblem == null ? null : sc(ai.assistantProblem),
      'speech': ai.speechProblem == null ? null : sc(ai.speechProblem),
      'translation': ai.translationProblem == null ? null : sc(ai.translationProblem),
    },
    'even_ai': {
      'phase': e?.phase.name,
      'session_open': e?.sessionOpen,
      'turn_running': e?.turnRunning,
    },
    'live_translate': {
      'running': live.running,
      'languages': '${live.src}>${live.dst}',
      'source': live.sourceName,
      'utterances': live.utterances,
      'rearms': live.rearms,
      'last_error': live.lastError.isEmpty ? null : sc(live.lastError),
      'last_push_error': live.lastPushError.isEmpty ? null : sc(live.lastPushError),
    },
    'events': [for (final x in rec.aiEvents) {'t': _utc(x.at), 'component': x.component, 'event': sc(x.event)}],
    'history': [
      for (final h in ai.history.length <= 30 ? ai.history : ai.history.sublist(ai.history.length - 30))
        {
          't': _utc(h.at),
          'source': h.source,
          'mode': h.mode,
          'model': h.model == null ? null : sc(h.model),
          'actions': [for (final a in h.actions) a.split('(').first.split(':').first.trim()],
          'error': h.error == null ? null : sc(h.error),
          'audio_s': h.audioSeconds,
          'confidence': h.confidence,
          'question_chars': h.question.length,
          'reply_chars': h.reply.length,
        },
    ],
    'on_device_model': local == null
        ? null
        : {
            'loaded_model': local.loadedModelId,
            'loading': local.loading,
            'last_error': local.lastError == null ? null : sc(local.lastError),
            'last_run': run == null
                ? null
                : {
                    'model': sc(run.model),
                    'load_ms': run.loadTime?.inMilliseconds,
                    'prompt_tokens': run.result.promptTokens,
                    'prompt_tokens_per_s': double.parse(run.result.promptTokensPerSecond.toStringAsFixed(1)),
                    'completion_tokens': run.result.completionTokens,
                    'tokens_per_s': double.parse(run.result.tokensPerSecond.toStringAsFixed(1)),
                    'first_token_ms': run.result.timeToFirstToken?.inMilliseconds,
                    'duration_ms': run.result.duration.inMilliseconds,
                    'finish': run.result.finishReason,
                  },
          },
  };
}

Future<String?> _key(AiHub ai, String name) async {
  try {
    return await ai.secrets.read(name);
  } catch (_) {
    return null;
  }
}
