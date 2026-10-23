/// Subscribed calendars (ICS / iCalendar feeds) → the hub's event shape. Port of
/// g2-hub/hub/calendar_sync.py (no dependencies besides the IANA database):
///   * line unfolding, text unescaping, SUMMARY / LOCATION / UID / STATUS
///   * DTSTART / DTEND / DURATION as DATE (all-day), UTC ("Z"), TZID or floating (local)
///   * RRULE DAILY / WEEKLY (BYDAY) / MONTHLY (BYMONTHDAY, BYDAY with ordinals) / YEARLY
///     (BYMONTH) with INTERVAL, COUNT, UNTIL, plus EXDATE and RECURRENCE-ID overrides
///   * not handled (like the hub): BYSETPOS, HOURLY.., RDATE; unknown TZIDs fall back to local
/// Only today .. +3 days is kept; hub_format.upcoming() applies the today/tomorrow rules.
library;

import '../protocol/hub_format.dart' show CalEvent;
import 'local_zone.dart';

const String idPrefix = 'ics:';
const int windowDays = 3;
const int maxBytes = 5000000;
const int maxCandidates = 20000;
const List<String> _days = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

class SyncError implements Exception {
  SyncError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// webcal:// → https://; anything but http(s) is rejected (FormatException).
String normalizeUrl(String? url) {
  var u = (url ?? '').trim();
  if (u.toLowerCase().startsWith('webcal://')) u = 'https://${u.substring(9)}';
  if (u.isNotEmpty && !RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(u)) {
    throw const FormatException('calendar URL must start with https:// (or webcal://)');
  }
  return u;
}

String unescapeIcs(String v) => v.replaceAllMapped(RegExp(r'\\(.)'), (m) => 'nN'.contains(m[1]!) ? '\n' : m[1]!);

typedef IcsProp = (String name, Map<String, String> params, String value);

/// One list of (NAME, params, value) per VEVENT.
List<List<IcsProp>> components(String text) {
  var t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  t = t.replaceAll(RegExp(r'\n[ \t]'), '');
  final out = <List<IcsProp>>[];
  List<IcsProp>? cur;
  for (final line in t.split('\n')) {
    if (line.isEmpty) continue;
    final up = line.toUpperCase();
    if (up == 'BEGIN:VEVENT') {
      cur = [];
    } else if (up == 'END:VEVENT') {
      if (cur != null) out.add(cur);
      cur = null;
    } else if (cur != null && line.contains(':')) {
      final i = line.indexOf(':');
      final parts = line.substring(0, i).split(';');
      final params = <String, String>{};
      for (final p in parts.skip(1)) {
        final j = p.indexOf('=');
        final k = j < 0 ? p : p.substring(0, j);
        final v = j < 0 ? '' : p.substring(j + 1);
        params[k.toUpperCase()] = _stripQuotes(v);
      }
      cur.add((parts[0].toUpperCase(), params, line.substring(i + 1)));
    }
  }
  return out;
}

String _stripQuotes(String v) {
  var a = 0, b = v.length;
  while (a < b && v[a] == '"') {
    a++;
  }
  while (b > a && v[b - 1] == '"') {
    b--;
  }
  return v.substring(a, b);
}

enum _ZKind { utc, named, local }

/// A parsed DTSTART/DTEND-like value: all-day date, or a wall time in its own zone.
class _Dt {
  _Dt(this.allDay, this.wall, this.kind, this.zone, this.epoch);
  final bool allDay;
  final DateTime wall; // naive (date at midnight for all-day)
  final _ZKind kind;
  final LocalZone? zone; // named zone
  final int epoch; // aware instant (unused for all-day)
}

DateTime _date(DateTime w) => DateTime.utc(w.year, w.month, w.day);

DateTime _ymd(String s) {
  final y = int.parse(s.substring(0, 4)), m = int.parse(s.substring(4, 6)), d = int.parse(s.substring(6, 8));
  final dt = DateTime.utc(y, m, d);
  if (dt.month != m || dt.day != d || m < 1) throw FormatException('bad date $s');
  return dt;
}

DateTime _ymdhms(String s) {
  if (!RegExp(r'^\d{8}T\d{6}$').hasMatch(s)) throw FormatException('bad date-time $s');
  final d = _ymd(s.substring(0, 8));
  final h = int.parse(s.substring(9, 11)), mi = int.parse(s.substring(11, 13)), se = int.parse(s.substring(13, 15));
  if (h > 23 || mi > 59 || se > 61) throw FormatException('bad time $s');
  return d.add(Duration(hours: h, minutes: mi, seconds: se));
}

_Dt _parseDt(String value, Map<String, String> params, LocalZone local) {
  final v = value.trim();
  if (params['VALUE'] == 'DATE' || RegExp(r'^\d{8}$').hasMatch(v)) {
    if (v.length < 8 || !RegExp(r'^\d{8}').hasMatch(v)) throw FormatException('bad date $v');
    final d = _ymd(v.substring(0, 8));
    return _Dt(true, d, _ZKind.local, null, local.epochOf(d));
  }
  if (v.endsWith('Z')) {
    final w = _ymdhms(v.substring(0, v.length - 1));
    return _Dt(false, w, _ZKind.utc, null, w.millisecondsSinceEpoch ~/ 1000);
  }
  final naive = _ymdhms(v);
  final tzid = params['TZID'];
  if (tzid != null && tzid.isNotEmpty) {
    final loc = zoneByName(tzid);
    if (loc != null) {
      final z = TzZone(loc);
      return _Dt(false, naive, _ZKind.named, z, z.epochOf(naive));
    }
  }
  return _Dt(false, naive, _ZKind.local, null, local.epochOf(naive));
}

Duration? parseDuration(String v) {
  final m = RegExp(r'^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$').firstMatch(v.trim());
  if (m == null) return null;
  int g(int i) => int.tryParse(m[i] ?? '') ?? 0;
  final d = Duration(days: g(2) * 7 + g(3), hours: g(4), minutes: g(5), seconds: g(6));
  return m[1] == '-' ? -d : d;
}

Map<String, String> parseRule(String value) {
  final r = <String, String>{};
  for (final part in value.split(';')) {
    final i = part.indexOf('=');
    r[(i < 0 ? part : part.substring(0, i)).toUpperCase()] = i < 0 ? '' : part.substring(i + 1);
  }
  return r;
}

List<(int, int)> _byday(String spec) {
  final out = <(int, int)>[];
  for (final tok in spec.split(',')) {
    final m = RegExp(r'^([+-]?\d+)?(MO|TU|WE|TH|FR|SA|SU)$').firstMatch(tok.trim().toUpperCase());
    if (m != null) out.add((m[1] != null ? int.parse(m[1]!) : 0, _days.indexOf(m[2]!)));
  }
  return out;
}

int _daysIn(int y, int m) => DateTime.utc(y, m + 1, 0).day;

List<DateTime> _monthDays(int year, int month, List<int> bymonthday, List<(int, int)> byday, int fallbackDay) {
  final n = _daysIn(year, month);
  final days = <int>{};
  for (var d in bymonthday) {
    d = d > 0 ? d : n + d + 1;
    if (d >= 1 && d <= n) days.add(d);
  }
  for (final (ordn, wd) in byday) {
    final matches = [for (var d = 1; d <= n; d++) if (DateTime.utc(year, month, d).weekday - 1 == wd) d];
    if (ordn == 0) {
      days.addAll(matches);
    } else if (matches.isNotEmpty && ordn.abs() <= matches.length) {
      days.add(ordn > 0 ? matches[ordn - 1] : matches[matches.length + ordn]);
    }
  }
  if (bymonthday.isEmpty && byday.isEmpty && fallbackDay <= n) days.add(fallbackDay);
  return (days.toList()..sort()).map((d) => DateTime.utc(year, month, d)).toList();
}

/// Wall-clock occurrences of a rule, in order, from [start] until a limit.
Iterable<DateTime> _candidates(Map<String, String> rule, DateTime start, DateTime? untilDate, DateTime limitDate) sync* {
  final freq = rule['FREQ'] ?? '';
  final interval = (int.tryParse(rule['INTERVAL'] ?? '') ?? 1).clamp(1, 1 << 30);
  if ((rule['INTERVAL'] ?? '').isNotEmpty && int.tryParse(rule['INTERVAL']!) == null) {
    throw FormatException('bad INTERVAL');
  }
  final byday = (rule['BYDAY'] ?? '').isNotEmpty ? _byday(rule['BYDAY']!) : <(int, int)>[];
  final bymd = (rule['BYMONTHDAY'] ?? '').isNotEmpty ? rule['BYMONTHDAY']!.split(',').map(int.parse).toList() : <int>[];
  final t = start.difference(_date(start));
  final sd = _date(start);
  final last = untilDate != null && untilDate.isBefore(limitDate) ? untilDate : limitDate;
  var k = 0;
  while (true) {
    List<DateTime> days;
    if (freq == 'DAILY') {
      days = [DateTime.utc(sd.year, sd.month, sd.day + k * interval)];
    } else if (freq == 'WEEKLY') {
      final monday = DateTime.utc(sd.year, sd.month, sd.day - (sd.weekday - 1) + 7 * k * interval);
      final wds = byday.isEmpty ? [sd.weekday - 1] : ({for (final b in byday) b.$2}.toList()..sort());
      days = [for (final wd in wds) DateTime.utc(monday.year, monday.month, monday.day + wd)];
    } else if (freq == 'MONTHLY') {
      final mi = sd.month - 1 + k * interval;
      days = _monthDays(sd.year + mi ~/ 12, mi % 12 + 1, bymd, byday, sd.day);
    } else if (freq == 'YEARLY') {
      final months = (rule['BYMONTH'] ?? '').isNotEmpty ? rule['BYMONTH']!.split(',').map(int.parse).toList() : [sd.month];
      days = [for (final m in months) ..._monthDays(sd.year + k * interval, m, bymd, byday, sd.day)];
    } else {
      return;
    }
    if (days.isNotEmpty && days.reduce((a, b) => a.isBefore(b) ? a : b).isAfter(last)) return;
    if (k > maxCandidates) return;
    for (final d in days) {
      if (!d.isBefore(sd)) yield d.add(t);
    }
    k++;
  }
}

/// (startTs, endTs, origTs, allDay) of one VEVENT overlapping [wstart, wend).
List<(int, int, int, bool)> _instances(List<IcsProp> ev, int wstart, int wend, LocalZone local) {
  final props = <String, List<(Map<String, String>, String)>>{};
  for (final (n, p, v) in ev) {
    props.putIfAbsent(n, () => []).add((p, v));
  }
  if (!props.containsKey('DTSTART')) return const [];
  final start = _parseDt(props['DTSTART']![0].$2, props['DTSTART']![0].$1, local);
  final allDay = start.allDay;
  Duration span;
  if (props.containsKey('DTEND')) {
    final end = _parseDt(props['DTEND']![0].$2, props['DTEND']![0].$1, local);
    if (end.allDay != allDay) throw StateError('date vs date-time'); // Python: TypeError
    if (allDay) {
      span = end.wall.difference(start.wall);
    } else if (start.kind == end.kind &&
        (start.kind == _ZKind.utc ||
            (start.kind == _ZKind.named && (start.zone as TzZone).location.name == (end.zone as TzZone).location.name))) {
      span = end.wall.difference(start.wall); // same tzinfo: Python subtracts wall times
    } else {
      span = Duration(seconds: end.epoch - start.epoch);
    }
  } else if (props.containsKey('DURATION') && parseDuration(props['DURATION']![0].$2) != null) {
    span = parseDuration(props['DURATION']![0].$2)!;
  } else {
    span = allDay ? const Duration(days: 1) : Duration.zero;
  }
  if (span <= Duration.zero) span = allDay ? const Duration(days: 1) : const Duration(hours: 1);

  int toDt(DateTime wall) {
    if (allDay) return local.epochOf(_date(wall));
    switch (start.kind) {
      case _ZKind.local:
        return local.epochOf(wall);
      case _ZKind.utc:
        return wall.millisecondsSinceEpoch ~/ 1000;
      case _ZKind.named:
        return start.zone!.epochOf(wall);
    }
  }

  DateTime toWall(_Dt d) {
    if (d.allDay) return d.wall;
    if (start.kind == _ZKind.local) return local.wallOf(d.epoch);
    return d.wall;
  }

  final baseWall = toWall(start);
  final exdates = <DateTime>{};
  for (final (params, value) in props['EXDATE'] ?? const <(Map<String, String>, String)>[]) {
    for (final v in value.split(',')) {
      try {
        exdates.add(toWall(_parseDt(v, params, local)));
      } on FormatException {
        // ignored, like the hub
      }
    }
  }

  var walls = [baseWall];
  if (props.containsKey('RRULE')) {
    final rule = parseRule(props['RRULE']![0].$2);
    DateTime? until;
    if ((rule['UNTIL'] ?? '').isNotEmpty) {
      try {
        final u = _parseDt(rule['UNTIL']!, const {}, local);
        until = u.allDay ? u.wall : _date(local.wallOf(u.epoch));
      } on FormatException {
        until = null;
      }
    }
    final limitWall = local.wallOf(wend + span.inSeconds);
    final limit = DateTime.utc(limitWall.year, limitWall.month, limitWall.day + 1);
    final countStr = rule['COUNT'] ?? '';
    final count = RegExp(r'^\d+$').hasMatch(countStr) ? int.parse(countStr) : null;
    walls = [];
    var i = 0;
    for (final w in _candidates(rule, baseWall, until, limit)) {
      if (count != null && i >= count) break;
      walls.add(w);
      i++;
    }
    if (!const {'DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'}.contains(rule['FREQ'])) walls = [baseWall];
  }
  final out = <(int, int, int, bool)>[];
  for (final w in walls) {
    if (exdates.contains(w)) continue;
    final s = toDt(w);
    final int e;
    if (allDay) {
      e = toDt(w.add(span));
    } else if (start.kind == _ZKind.named) {
      e = start.zone!.epochOf(start.zone!.wallOf(s).add(span));
    } else {
      e = s + span.inSeconds;
    }
    if (s < wend && e > wstart) out.add((s, e, s, allDay));
  }
  return out;
}

/// ICS text → events overlapping today..today+3 (local), earliest first. Throws [SyncError]
/// when the text is not a calendar.
List<CalEvent> parseIcs(String text, {required int now, LocalZone local = const SystemZone()}) {
  ensureTimeZones();
  if (!text.toUpperCase().contains('BEGIN:VCALENDAR')) throw SyncError('that URL did not return an ICS calendar');
  final todayWall = local.wallOf(now);
  final today = DateTime.utc(todayWall.year, todayWall.month, todayWall.day);
  final wstart = local.epochOf(today);
  final wend = local.epochOf(DateTime.utc(today.year, today.month, today.day + windowDays));
  final comps = components(text);
  final overrides = <String>{};
  String key(String uid, int ts) => '$uid\u0000$ts';
  for (final ev in comps) {
    final props = {for (final (n, p, v) in ev) n: (p, v)};
    if (props.containsKey('RECURRENCE-ID')) {
      try {
        final r = props['RECURRENCE-ID']!;
        final d = _parseDt(r.$2, r.$1, local);
        overrides.add(key(props['UID']?.$2 ?? '', d.allDay ? local.epochOf(d.wall) : d.epoch));
      } catch (_) {}
    }
  }
  final events = <CalEvent>[];
  for (final ev in comps) {
    final props = {for (final (n, p, v) in ev) n: (p, v)};
    if ((props['STATUS']?.$2 ?? '').toUpperCase() == 'CANCELLED') continue;
    List<(int, int, int, bool)> insts;
    try {
      insts = _instances(ev, wstart, wend, local);
    } catch (_) {
      continue;
    }
    if (insts.isEmpty) continue;
    final uid = props['UID']?.$2 ?? '';
    final isOverride = props.containsKey('RECURRENCE-ID');
    final t = unescapeIcs(props['SUMMARY']?.$2 ?? '').trim();
    final title = t.isEmpty ? 'Event' : t;
    final loc = unescapeIcs(props['LOCATION']?.$2 ?? '').replaceAll('\n', ', ').trim();
    for (final (s, e, orig, ad) in insts) {
      if (!isOverride && overrides.contains(key(uid, orig))) continue;
      events.add(CalEvent(id: '$idPrefix$uid@$s', title: title, location: loc, start: s, end: e, allDay: ad));
    }
  }
  events.sort((a, b) {
    final c = a.start.compareTo(b.start);
    return c != 0 ? c : _cp(a.title, b.title);
  });
  return events;
}

int _cp(String a, String b) {
  final ra = a.runes.toList(), rb = b.runes.toList();
  for (var i = 0; i < ra.length && i < rb.length; i++) {
    if (ra[i] != rb[i]) return ra[i].compareTo(rb[i]);
  }
  return ra.length.compareTo(rb.length);
}

/// Fetch + parse; never throws: (events, note) where note is '' on success.
Future<(List<CalEvent>, String)> syncIcs(String url, Future<String> Function(String url) fetch,
    {required int now, LocalZone local = const SystemZone()}) async {
  try {
    final u = normalizeUrl(url);
    if (u.isEmpty) return (<CalEvent>[], 'no calendar URL set');
    final text = await fetch(u);
    return (parseIcs(text, now: now, local: local), '');
  } on SyncError catch (e) {
    return (<CalEvent>[], e.message);
  } on FormatException catch (e) {
    return (<CalEvent>[], e.message);
  } catch (e) {
    return (<CalEvent>[], 'could not read calendar (${e.runtimeType})');
  }
}
