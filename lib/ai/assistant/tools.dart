/// The glasses tools the assistant can call — port of g2-hub/hub/assistant_tools.py (same
/// names, descriptions, schemas and reply texts). "Read me the second news article", "add buy
/// milk to my list", "set brightness to 30" are answered by calling these.
///
/// The app supplies a [GlassesToolHost] (lib/hub/even_ai_tools_host.dart) that reads and
/// changes the same saved data the screens use, so what the assistant changes is persisted
/// and synced to the glasses like any other edit.
library;

import '../providers/llm.dart';

class ToolTask {
  ToolTask(this.title, {this.completed = false});
  String title;
  bool completed;
}

class ToolEvent {
  ToolEvent({required this.title, required this.start, required this.end, this.allDay = false, this.location = ''});
  final String title;

  /// Epoch seconds.
  final int start;
  final int end;
  final bool allDay;
  final String location;
}

class NewsStory {
  const NewsStory(this.title, {this.source = '', this.content = ''});
  final String title;
  final String source;
  final String content;
}

/// What the tools need from the app.
abstract class GlassesToolHost {
  List<NewsStory> newsStories();
  Future<void> refreshNews();
  List<ToolTask> loadTasks();
  Future<void> saveTasks(List<ToolTask> tasks);
  List<ToolEvent> calendarEvents();
  Future<void> setCalendar(List<ToolEvent> events);
  String? weatherSummary();
  Future<String> pushWeather();
  Map<String, Object?> glassesStatus();
  Future<void> setBrightness({int? level, bool auto = false});
  Future<void> setSilentMode(bool on);
  Future<void> sendNotification(String title, String message);

  /// Close the open full-screen app; returns its name or null if none was open.
  Future<String?> closeApp();
}

class ToolFailure implements Exception {
  ToolFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

Map<String, Object?> _obj([Map<String, Object?> props = const {}, List<String> required = const []]) =>
    {'type': 'object', 'properties': props, if (required.isNotEmpty) 'required': required};

const _str = {'type': 'string'};
const _bool = {'type': 'boolean'};

final List<ToolSpec> glassesTools = [
  ToolSpec('list_news', 'List the news articles currently on the glasses news widget (number, source, title).', _obj()),
  ToolSpec('read_news_article', 'Get the full text of one news article from the widget so you can read it to the user.',
      _obj({'number': {'type': 'integer', 'description': '1-based article number from list_news'}}, ['number'])),
  ToolSpec('refresh_news', 'Fetch fresh stories and push them to the news widget.', _obj()),
  ToolSpec('list_tasks', "List the tasks on the glasses' task list (quicklist) with done status.", _obj()),
  ToolSpec('add_task', 'Add a task to the task list on the glasses.', _obj({'title': _str}, ['title'])),
  ToolSpec('set_task_done', 'Mark a task done or not done. Match by its title (partial is fine) or its 1-based number.',
      _obj({'task': _str, 'done': _bool}, ['task', 'done'])),
  ToolSpec('remove_task', 'Delete a task from the list (by title or 1-based number).', _obj({'task': _str}, ['task'])),
  ToolSpec('list_calendar', 'List upcoming calendar events shown on the glasses.', _obj()),
  ToolSpec('add_calendar_event', 'Add an event to the glasses calendar. Give start as local "YYYY-MM-DD HH:MM", or minutes_from_now.',
      _obj({
        'title': _str,
        'start': {'type': 'string', 'description': 'local time YYYY-MM-DD HH:MM'},
        'minutes_from_now': {'type': 'number'},
        'duration_min': {'type': 'number', 'description': 'default 60'},
        'location': _str,
        'all_day': _bool,
      }, ['title'])),
  ToolSpec('remove_calendar_event', 'Delete a calendar event by (partial) title.', _obj({'title': _str}, ['title'])),
  ToolSpec('get_weather', 'Current weather where the user is, as shown on the glasses.', _obj()),
  ToolSpec('get_glasses_status', 'Battery, charging, worn, charging-case battery, firmware and display settings of the glasses.', _obj()),
  ToolSpec('set_brightness', 'Set display brightness 1-50, or auto=true for automatic brightness.',
      _obj({'level': {'type': 'integer', 'minimum': 1, 'maximum': 50}, 'auto': _bool})),
  ToolSpec('set_silent_mode', 'Turn silent (do not disturb) mode on or off.', _obj({'on': _bool}, ['on'])),
  ToolSpec('send_notification', 'Show a notification on the glasses.', _obj({'title': _str, 'message': _str}, ['title', 'message'])),
  ToolSpec('close_display',
      'Hide the display: close whatever full-screen app (translate, teleprompter, navigation) is open on the glasses, returning to the normal dashboard.',
      _obj()),
  ToolSpec('show_dashboard', 'Go back to the glasses dashboard (closes any open full-screen app).', _obj()),
  ToolSpec('show_weather', 'Fetch fresh weather and push it to the glasses dashboard.', _obj()),
  ToolSpec('adjust_brightness', 'Change display brightness relative to now (delta in 1-50 units, positive brighter, negative dimmer).',
      _obj({'delta': {'type': 'integer', 'minimum': -49, 'maximum': 49}}, ['delta'])),
];

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _two(int v) => v.toString().padLeft(2, '0');
String _date(DateTime t) => '${_days[t.weekday - 1]} ${_two(t.day)} ${_months[t.month - 1]}';
String _hm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';
DateTime _local(int s) => DateTime.fromMillisecondsSinceEpoch(s * 1000);

class AssistantTools {
  AssistantTools(this.host, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final GlassesToolHost host;
  final DateTime Function() _clock;

  static final Set<String> names = {for (final t in glassesTools) t.name};

  /// Run tool [name]. Throws [ToolFailure] for bad input / unknown tools.
  Future<String> run(String name, Map<String, Object?> a) async {
    switch (name) {
      case 'list_news':
        final s = host.newsStories();
        if (s.isEmpty) return 'The news widget is empty.';
        return [for (var i = 0; i < s.length; i++) '${i + 1}. [${s[i].source}] ${s[i].title}'].join('\n');
      case 'read_news_article':
        final s = host.newsStories();
        final n = _int(a['number']);
        if (n == null || n < 1 || n > s.length) return 'There are ${s.length} articles; pick 1-${s.length}.';
        final st = s[n - 1];
        return '${st.title} (${st.source})\n\n${st.content.isEmpty ? 'No article text available.' : st.content}';
      case 'refresh_news':
        await host.refreshNews();
        return 'Fresh stories are being fetched and pushed to the news widget.';
      case 'list_tasks':
        final t = host.loadTasks();
        if (t.isEmpty) return 'The task list is empty.';
        return [for (var i = 0; i < t.length; i++) '${i + 1}. [${t[i].completed ? 'x' : ' '}] ${t[i].title}'].join('\n');
      case 'add_task':
        final title = _reqStr(a, 'title');
        final t = [...host.loadTasks(), ToolTask(title.trim().length > 120 ? title.trim().substring(0, 120) : title.trim())];
        await host.saveTasks(t);
        return 'Added "$title". The list now has ${t.length} tasks.';
      case 'set_task_done':
        final t = host.loadTasks();
        final i = _find(t.map((x) => x.title).toList(), _reqStr(a, 'task'));
        final done = a['done'] == true;
        t[i].completed = done;
        await host.saveTasks(t);
        return 'Marked "${t[i].title}" as ${done ? 'done' : 'not done'}.';
      case 'remove_task':
        final t = host.loadTasks();
        final removed = t.removeAt(_find(t.map((x) => x.title).toList(), _reqStr(a, 'task')));
        await host.saveTasks(t);
        return 'Removed "${removed.title}".';
      case 'list_calendar':
        final now = _clock().millisecondsSinceEpoch ~/ 1000;
        final ev = host.calendarEvents().where((e) => e.end > now).toList()..sort((x, y) => x.start.compareTo(y.start));
        if (ev.isEmpty) return 'No upcoming events.';
        return [
          for (final e in ev)
            '- ${e.title}: ${e.allDay ? 'all day ${_date(_local(e.start))}' : '${_date(_local(e.start))} ${_hm(_local(e.start))} to ${_hm(_local(e.end))}'}'
                '${e.location.isNotEmpty ? ' at ${e.location}' : ''}'
        ].join('\n');
      case 'add_calendar_event':
        return _addEvent(a);
      case 'remove_calendar_event':
        final ev = [...host.calendarEvents()];
        final removed = ev.removeAt(_find(ev.map((e) => e.title).toList(), _reqStr(a, 'title')));
        await host.setCalendar(ev);
        return 'Removed "${removed.title}".';
      case 'get_weather':
        return host.weatherSummary() ?? 'Weather has not been fetched yet.';
      case 'get_glasses_status':
        final s = host.glassesStatus();
        if (s.isEmpty) return 'No status yet (glasses may be disconnected).';
        const keys = ['battery', 'charging', 'worn', 'case_battery', 'right_version', 'brightness_auto', 'brightness_level', //
          'silent_mode', 'head_up', 'head_up_angle', 'wear_detection', 'display_timeout'];
        return [for (final k in keys) if (s.containsKey(k)) '$k=${s[k]}'].join(', ');
      case 'set_brightness':
        if (a['auto'] == true) {
          await host.setBrightness(auto: true);
          return 'Brightness set to automatic.';
        }
        final level = (_int(a['level']) ?? 25).clamp(1, 50);
        await host.setBrightness(level: level);
        return 'Brightness set to $level of 50.';
      case 'set_silent_mode':
        final on = a['on'] == true;
        await host.setSilentMode(on);
        return 'Silent mode ${on ? 'on' : 'off'}.';
      case 'send_notification':
        await host.sendNotification(_reqStr(a, 'title'), _reqStr(a, 'message'));
        return 'Notification sent.';
      case 'close_display':
        final closed = await host.closeApp();
        return closed != null ? 'Closed $closed.' : 'No full-screen app was open; the display is on the dashboard.';
      case 'show_dashboard':
        final closed = await host.closeApp();
        return closed != null ? 'Back to the dashboard.' : 'Already on the dashboard.';
      case 'show_weather':
        return 'Weather: ${await host.pushWeather()}';
      case 'adjust_brightness':
        final cur = host.glassesStatus()['brightness_level'];
        final level = ((cur is num ? cur.toInt() : 25) + (_int(a['delta']) ?? 0)).clamp(1, 50);
        return run('set_brightness', {'level': level});
    }
    throw ToolFailure('unknown tool $name');
  }

  Future<String> _addEvent(Map<String, Object?> a) async {
    final title = _reqStr(a, 'title');
    final allDay = a['all_day'] == true;
    final dur = ((a['duration_min'] as num?) ?? 60).toDouble();
    int start;
    final startStr = a['start'];
    if (startStr is String && startStr.trim().isNotEmpty) {
      final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})').firstMatch(startStr.trim());
      if (m == null) throw ToolFailure('start must look like "YYYY-MM-DD HH:MM"');
      final g = [for (var i = 1; i <= 5; i++) int.parse(m.group(i)!)];
      start = DateTime(g[0], g[1], g[2], g[3], g[4]).millisecondsSinceEpoch ~/ 1000;
    } else if (a['minutes_from_now'] is num) {
      start = _clock().millisecondsSinceEpoch ~/ 1000 + ((a['minutes_from_now'] as num) * 60).round();
    } else {
      throw ToolFailure('give start ("YYYY-MM-DD HH:MM") or minutes_from_now');
    }
    var end = start + (dur * 60).round();
    if (allDay) {
      final t = _local(start);
      start = DateTime(t.year, t.month, t.day).millisecondsSinceEpoch ~/ 1000;
      end = start + 86340;
    }
    final loc = (a['location'] ?? '').toString();
    await host.setCalendar([...host.calendarEvents(), ToolEvent(title: title, start: start, end: end, allDay: allDay, location: loc)]);
    return 'Added "$title" to the calendar.';
  }

  static String _reqStr(Map<String, Object?> a, String k) {
    final v = a[k];
    if (v == null) throw ToolFailure('missing $k');
    return v.toString();
  }

  static int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');

  /// 1-based number, else first case-insensitive substring match (hub _find).
  static int _find(List<String> items, String key) {
    key = key.trim();
    final n = int.tryParse(key);
    if (n != null && RegExp(r'^\d+$').hasMatch(key) && n >= 1 && n <= items.length) return n - 1;
    final low = key.toLowerCase();
    for (var i = 0; i < items.length; i++) {
      if (items[i].toLowerCase().contains(low)) return i;
    }
    throw ToolFailure('no item matching "$key"');
  }

  /// "add_task(Buy milk)" — the hub's action label.
  static String label(String name, Map<String, Object?> args) {
    final vals = args.values.map((v) {
      final s = '$v';
      return s.length > 30 ? s.substring(0, 30) : s;
    }).join(', ');
    return '$name($vals)';
  }
}
