/// The assistant's tools acting on the app's real data (HubController): the same tasks,
/// calendar, news, weather and settings the screens edit, saved and synced to the glasses.
library;

import '../ai/assistant/tools.dart';
import '../protocol/hub_format.dart' as fmt;
import 'hub_controller.dart';

class HubToolHost implements GlassesToolHost {
  HubToolHost(this.hub, {this.sync});
  final HubController hub;

  /// Hands a changed section to the app's auto-sync (sync engine `markDirty`); when null the
  /// change is pushed right away through the connected session.
  final void Function(String section)? sync;

  Future<void> _commit(String section, Future<void> Function() pushNow) async {
    await hub.save();
    final s = sync;
    if (s != null) {
      s(section);
    } else {
      await pushNow();
    }
  }

  @override
  List<NewsStory> newsStories() => [for (final n in hub.data.news) NewsStory(n.title, source: n.source, content: n.content)];

  @override
  Future<void> refreshNews() => _commit('news', () async {
        if (hub.data.news.isNotEmpty) await hub.run((f) => f.pushNews(hub.data.news));
      });

  @override
  List<ToolTask> loadTasks() => [for (final t in hub.data.tasks) ToolTask(t.title, completed: t.completed)];

  @override
  Future<void> saveTasks(List<ToolTask> tasks) async {
    hub.setTasks([for (final t in tasks) fmt.TaskItem(title: t.title, completed: t.completed)]);
    await _commit('tasks', () async {
      if (hub.data.tasks.isNotEmpty) await hub.run((f) => f.pushTasks(hub.data.tasks));
    });
  }

  @override
  List<ToolEvent> calendarEvents() => [
        for (final e in hub.data.events)
          ToolEvent(title: e.title, start: e.start, end: e.end, allDay: e.allDay, location: e.location)
      ];

  @override
  Future<void> setCalendar(List<ToolEvent> events) async {
    final old = {for (final e in hub.data.events) '${e.title}|${e.start}': e.id};
    hub.data.events = [
      for (var i = 0; i < events.length; i++)
        fmt.CalEvent(
          id: old['${events[i].title}|${events[i].start}'] ?? 'ai-${DateTime.now().microsecondsSinceEpoch}-$i',
          title: events[i].title,
          location: events[i].location,
          start: events[i].start,
          end: events[i].end,
          allDay: events[i].allDay,
        )
    ];
    await _commit('calendar', () async => hub.run((f) => f.pushCalendar(hub.data.events, h24: hub.data.h24)));
  }

  @override
  String? weatherSummary() {
    final w = hub.data.weather;
    final t = w.fahrenheit ? '${w.tempF.round()}°F' : '${((w.tempF - 32) * 5 / 9).round()}°C';
    return w.status.trim().isEmpty ? t : '$t, ${w.status.trim()}';
  }

  @override
  Future<String> pushWeather() async {
    await _commit('weather', () async => hub.run((f) => f.pushWeather(hub.data.weather)));
    return weatherSummary() ?? '';
  }

  @override
  Map<String, Object?> glassesStatus() {
    final g = hub.glasses;
    final s = hub.data.settings;
    return {
      if (g?.battery != null) 'battery': g!.battery,
      if (g?.charging != null) 'charging': g!.charging,
      if (g?.worn != null) 'worn': g!.worn,
      if (g?.caseBattery != null) 'case_battery': g!.caseBattery,
      if (g?.rightVersion != null) 'right_version': g!.rightVersion,
      'brightness_auto': g?.brightnessAuto ?? s.autoBrightness,
      'brightness_level': g?.brightnessLevel ?? s.brightness,
      'silent_mode': g?.silentMode ?? s.silentMode,
      'head_up': s.headUp,
      'head_up_angle': g?.headUpAngle ?? s.headUpAngle,
      'wear_detection': s.wearDetection,
      'display_timeout': g?.displayTimeout ?? s.displayTimeout,
    };
  }

  @override
  Future<void> setBrightness({int? level, bool auto = false}) async {
    final s = hub.data.settings;
    s.autoBrightness = auto;
    if (!auto) s.brightness = (level ?? 25).clamp(1, 50);
    await _commit('settings', () async => hub.run((f) => f.applySettings(s)));
  }

  @override
  Future<void> setSilentMode(bool on) async {
    hub.data.settings.silentMode = on;
    await _commit('settings', () async => hub.run((f) => f.applySettings(hub.data.settings)));
  }

  @override
  Future<void> sendNotification(String title, String message) async {
    throw ToolFailure('sending a notification to the glasses is not available in this app version');
  }

  @override
  Future<String?> closeApp() async {
    final f = hub.features;
    if (f == null) throw ToolFailure('glasses not connected');
    final name = f.currentApp;
    await f.closeApp();
    return name;
  }
}
