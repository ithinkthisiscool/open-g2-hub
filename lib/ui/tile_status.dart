/// The one-line live status each tile shows ("Sunny 18°", "3 tasks", "Synced", "Off").
/// Pure functions of the app data, so they are unit-tested without widgets.
library;

import '../hub/models.dart';
import '../logic/notification_filter.dart' show NotificationPrefs;
import '../protocol/dashboard.dart' show weatherTypeNames;
import '../protocol/hub_format.dart' show TaskItem;

String _deg(num c, bool fahrenheit) => fahrenheit ? '${(c * 9 / 5 + 32).round()}°' : '${c.round()}°';

/// "Clear 18°", "Rain 9°" (live) or the typed values; what to do when nothing is set yet.
String weatherStatus(WeatherConfig w) {
  if (w.mode == 'manual') {
    final name = w.status.trim().isNotEmpty
        ? w.status.trim()
        : (w.weatherType >= 0 && w.weatherType < weatherTypeNames.length ? weatherTypeNames[w.weatherType] : '');
    final c = (w.tempF - 32) * 5 / 9;
    return '${name.isEmpty ? 'Typed' : name} ${_deg(c, w.fahrenheit)}'.trim();
  }
  final t = w.last['temp_c'];
  if (t is num) {
    final s = (w.last['status'] ?? '').toString();
    return '${s.isEmpty ? 'Now' : s} ${_deg(t, w.fahrenheit)}';
  }
  if (!w.useGps && w.lat == null && w.city.trim().isEmpty) return 'Choose a city';
  return 'Not fetched yet';
}

String _hm(int epoch, bool h24) {
  final d = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
  if (h24) return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}

/// "Next: Standup 10:00", "Now: Standup", "No events".
String calendarStatus(AppData d, int nowS) {
  final next = d.allEvents.where((e) => e.end > nowS).toList();
  if (next.isEmpty) return 'No events';
  final e = next.first;
  if (e.start <= nowS) return 'Now: ${e.title}';
  return e.allDay ? 'Next: ${e.title}' : 'Next: ${e.title} ${_hm(e.start, d.h24)}';
}

/// "3 tasks", "1 task", "All done", "No tasks".
String tasksStatus(List<TaskItem> tasks) {
  if (tasks.isEmpty) return 'No tasks';
  final open = tasks.where((t) => !t.completed).length;
  if (open == 0) return 'All done';
  return open == 1 ? '1 task' : '$open tasks';
}

String newsStatus(AppData d) {
  final n = d.newsConfig.mode == 'manual' ? d.news.length : d.newsCache.stories.length;
  if (n == 0) return d.newsConfig.mode == 'manual' ? 'No stories' : 'No stories yet';
  return n == 1 ? '1 story' : '$n stories';
}

String stocksStatus(StocksConfig s) => !s.enabled ? 'Off' : (s.symbols.isEmpty ? 'No symbols' : s.symbols.take(3).join(' · '));

String healthStatus(HealthConfig h) {
  if (!h.enabled) return 'Off';
  if (h.fromPhone && h.importedAt == null && h.importNote.isNotEmpty) return 'Needs attention';
  final steps = h.values['steps'];
  return steps == null ? 'On' : '$steps steps';
}

String layoutStatus(LayoutConfig l) => l.custom ? 'Your order' : 'Default order';

String profilesStatus(AppData d) {
  if (d.profiles.isEmpty) return 'None yet';
  if (d.activeProfile != null) return '${d.activeProfile} · active';
  return d.profiles.length == 1 ? '1 profile' : '${d.profiles.length} profiles';
}

String displayStatus(GlassesSettings g) =>
    '${g.autoBrightness == true ? 'Auto brightness' : 'Brightness ${g.brightness ?? 25}'}${g.silentMode == true ? ' · silent' : ''}';

String menuStatus(int items) => items == 1 ? '1 app' : '$items apps';

String notificationsStatus(NotificationPrefs p, {required bool supported, required bool access}) {
  if (!p.enabled) return 'Off';
  if (supported && !access) return 'Needs access';
  return p.quietHours ? 'On · quiet ${p.quietStart}–${p.quietEnd}' : 'On';
}

String handoffStatus(AppData d) => d.handedOff ? 'Handed off · tap to take back' : 'This app has the glasses';
