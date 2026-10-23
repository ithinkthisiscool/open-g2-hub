/// Hub-level formatting that sits between user data and the protocol builders, ported from
/// g2-hub: calendar event selection/formatting (hub/calendar_events.py), the manual-weather
/// conversion (hub/routes/weather.py) and quicklist uid assignment (hub/routes/tasks.py).
/// Pure Dart; local time is injectable so tests are timezone-independent.
library;

import 'dart:convert';

import 'dashboard.dart' show ScheduleEntry, decodeUtf8PrefixIgnore, weatherTypeNames;
import 'pytext.dart';

/// Returns the local UTC offset (seconds) at a unix time. Default: this device's zone.
typedef UtcOffsetFn = int Function(int epochSeconds);

int deviceUtcOffset(int epochSeconds) =>
    DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000).timeZoneOffset.inSeconds;

DateTime _local(int ts, UtcOffsetFn off) => DateTime.fromMillisecondsSinceEpoch((ts + off(ts)) * 1000, isUtc: true);

const int maxEvents = 8;
const int titleMaxBytes = 175, locationMaxBytes = 282, timeMaxBytes = 62;

/// One calendar event (start/end unix seconds).
class CalEvent {
  CalEvent({required this.id, required this.title, this.location = '', required this.start, required this.end, this.allDay = false});
  final String id;
  final String title;
  final String location;
  final int start;
  final int end;
  final bool allDay;

  Map<String, Object?> toJson() =>
      {'id': id, 'title': title, 'location': location, 'start': start, 'end': end, 'all_day': allDay};
  factory CalEvent.fromJson(Map<String, Object?> j) => CalEvent(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        location: (j['location'] ?? '').toString(),
        start: (j['start'] as num).toInt(),
        end: (j['end'] as num).toInt(),
        allDay: j['all_day'] == true,
      );
}

/// calendar_events.limit_bytes: cut to max-3 bytes on a UTF-8 boundary and append "...".
String limitBytes(String? text, int maxBytes) {
  final t = text ?? '';
  final b = utf8.encode(t);
  if (b.length <= maxBytes) return t;
  return '${decodeUtf8PrefixIgnore(b.sublist(0, maxBytes - 3))}...';
}

String _two(int v) => v.toString().padLeft(2, '0');

String _clock(int ts, bool h24, UtcOffsetFn off, {bool isEnd = false}) {
  final t = _local(ts, off);
  if (h24) {
    final s = '${_two(t.hour)}:${_two(t.minute)}';
    return isEnd && s == '00:00' ? '24:00' : s;
  }
  final h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '${_two(h12)}:${_two(t.minute)} ${t.hour < 12 ? 'AM' : 'PM'}';
}

int _dayOffset(int ts, int now, UtcOffsetFn off) {
  final a = _local(ts, off), b = _local(now, off);
  final da = DateTime.utc(a.year, a.month, a.day), db = DateTime.utc(b.year, b.month, b.day);
  return (da.difference(db).inHours / 24).round();
}

String timeString(CalEvent ev, int now, {bool h24 = false, UtcOffsetFn off = deviceUtcOffset}) {
  final prefix = _dayOffset(ev.start, now, off) == 1 ? 'Tmr ' : '';
  if (ev.allDay) return '${prefix}All day';
  return '$prefix${_clock(ev.start, h24, off)}-${_clock(ev.end, h24, off, isEnd: true)}';
}

/// Today's and tomorrow's events the glasses should show (earliest first, deduped, max 8).
List<CalEvent> upcoming(List<CalEvent> events, int now, {UtcOffsetFn off = deviceUtcOffset}) {
  final sorted = [...events];
  _stableSortBy(sorted, (e) => e.start);
  final seen = <String>{};
  final out = <CalEvent>[];
  for (final e in sorted) {
    final d = _dayOffset(e.start, now, off);
    if (d != 0 && d != 1 && !(e.start <= now && now < e.end)) continue;
    if (!e.allDay && e.end <= now) continue;
    final key = jsonEncode([e.title, e.start, e.end]);
    if (seen.contains(key)) continue;
    seen.add(key);
    out.add(e);
  }
  return out.length > maxEvents ? out.sublist(0, maxEvents) : out;
}

/// [(title, location, timeStr, endTs)] ready for dashboard.buildCalendarEventPush.
List<ScheduleEntry> toSchedules(List<CalEvent> events, int now, {bool h24 = false, UtcOffsetFn off = deviceUtcOffset}) => [
      for (final e in upcoming(events, now, off: off))
        (
          limitBytes(e.title.isEmpty ? 'Event' : e.title, titleMaxBytes),
          limitBytes(e.location, locationMaxBytes),
          limitBytes(timeString(e, now, h24: h24, off: off), timeMaxBytes),
          e.end,
        )
    ];

void _stableSortBy<T>(List<T> list, int Function(T) key) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = key(a.$2).compareTo(key(b.$2));
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].$2;
  }
}

/// Python round() (banker's rounding, half to even) for a double.
int pyRound(double x) {
  final f = x.floorToDouble();
  final diff = x - f;
  if (diff > 0.5) return f.toInt() + 1;
  if (diff < 0.5) return f.toInt();
  final fi = f.toInt();
  return fi.isEven ? fi : fi + 1;
}

/// Manual weather as the hub sends it: (tempC, weatherType, statusString).
(int, int, String) manualWeather(double tempF, int weatherType, String status) {
  final tempC = pyRound((tempF - 32) * 5 / 9);
  final s = status.isNotEmpty
      ? status
      : (weatherType >= 0 && weatherType < weatherTypeNames.length ? weatherTypeNames[weatherType] : '');
  return (tempC, weatherType, pyHead(s, 32));
}

/// A task as the hub stores it.
class TaskItem {
  TaskItem({this.uid, required this.title, this.completed = false});
  int? uid;
  String title;
  bool completed;
  Map<String, Object?> toJson() => {'uid': uid, 'title': title, 'completed': completed};
  factory TaskItem.fromJson(Map<String, Object?> j) =>
      TaskItem(uid: (j['uid'] as num?)?.toInt(), title: (j['title'] ?? '').toString(), completed: j['completed'] == true);
}

/// tasks.assign_uids: keep given uids, reuse the previous uid of a same-titled task, else
/// allocate a new one. The glasses report completion by uid, so uids must be stable.
List<TaskItem> assignUids(List<TaskItem> tasks, List<TaskItem> prev) {
  final prevByTitle = <String, int>{};
  for (final p in prev) {
    if (p.uid != null) prevByTitle[p.title] = p.uid!;
  }
  final used = <int>{for (final t in tasks) if (t.uid != null && t.uid != 0) t.uid!};
  var nextUid = [...prev.map((p) => p.uid ?? 0), ...used, 0].reduce((a, b) => a > b ? a : b) + 1;
  for (final t in tasks) {
    if (t.uid == null || t.uid == 0) {
      var uid = prevByTitle[t.title];
      if (uid == null || used.contains(uid)) {
        uid = nextUid;
        nextUid += 1;
      }
      t.uid = uid;
      used.add(uid);
    }
  }
  return tasks;
}
