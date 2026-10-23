/// Dashboard: what the glasses show when you look up. Every edit is saved for this pair and
/// synced to the glasses automatically (the sync engine pushes ~1 s after the last change, or
/// when the glasses connect). No send buttons.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../hub/hub_controller.dart';
import '../hub/models.dart';
import '../logic/calendar_sync.dart' as ics;
import '../logic/feeds.dart' as feeds;
import '../logic/health_values.dart';
import '../logic/profiles.dart' as prof;
import '../logic/stock_quotes.dart' as quotes;
import '../logic/weather_logic.dart' as wl;
import '../protocol/dashboard.dart' show weatherTypeNames, widgetHealth, widgetNews, widgetQuicklist, widgetSchedule, widgetStock;
import '../protocol/hub_format.dart';
import '../services/data_services.dart';
import '../services/health_import.dart';
import 'app_scope.dart';
import 'common.dart';
import 'tile_status.dart';
import 'tiles.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});
  @override
  Widget build(BuildContext context) => PageList(
        title: 'Dashboard',
        subtitle: 'What your glasses show when you look up. Tap a widget to change it; changes sync by themselves.',
        children: [TileGrid(tiles: dashboardTiles(context))],
      );
}

/// The dashboard features as tiles (also used on Home).
List<Widget> dashboardTiles(BuildContext context) {
  final hub = AppScope.of(context);
  final d = hub.data;
  final ui = d.ui;
  final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  void open(String title, Widget card) => openSection(context, title, [card]);
  return [
    if (ui.feature('weather'))
      FeatureTile(
        icon: Icons.wb_sunny_outlined,
        title: 'Weather',
        status: hub.services.weatherError != null && d.weather.mode == 'auto' && d.weather.last.isEmpty ? 'Needs attention' : weatherStatus(d.weather),
        attention: hub.services.weatherError != null && d.weather.mode == 'auto' && d.weather.last.isEmpty,
        onTap: () => open('Weather', const WeatherCard()),
      ),
    if (ui.feature('calendar'))
      FeatureTile(icon: Icons.event_outlined, title: 'Calendar', status: calendarStatus(d, nowS), onTap: () => open('Calendar', const CalendarCard())),
    if (ui.feature('tasks'))
      FeatureTile(icon: Icons.checklist, title: 'Tasks', status: tasksStatus(d.tasks), onTap: () => open('Tasks', const TasksCard())),
    if (ui.feature('news'))
      FeatureTile(icon: Icons.newspaper, title: 'News', status: newsStatus(d), onTap: () => open('News', const NewsCard())),
    if (ui.beta && ui.feature('stocks'))
      FeatureTile(
        icon: Icons.show_chart,
        title: 'Stocks',
        beta: true,
        active: d.stocks.enabled,
        status: stocksStatus(d.stocks),
        onTap: () => open('Stocks', const StocksCard()),
      ),
    if (ui.beta && ui.feature('health'))
      FeatureTile(
        icon: Icons.favorite_outline,
        title: 'Health',
        beta: true,
        active: d.health.enabled,
        status: healthStatus(d.health),
        attention: d.health.enabled && healthStatus(d.health) == 'Needs attention',
        onTap: () => open('Health', const HealthCard()),
      ),
    if (ui.beta)
      FeatureTile(
        icon: Icons.view_carousel_outlined,
        title: 'Widget order',
        beta: true,
        status: layoutStatus(d.layout),
        onTap: () => open('Widget order', const LayoutCard()),
      ),
    if (ui.feature('profiles'))
      FeatureTile(icon: Icons.layers_outlined, title: 'Profiles', status: profilesStatus(d), onTap: () => open('Profiles', const ProfilesCard())),
  ];
}

// ── weather ───────────────────────────────────────────────────────────────────────────────────
class WeatherCard extends StatefulWidget {
  const WeatherCard({super.key});
  @override
  State<WeatherCard> createState() => _WeatherCardState();
}

class _WeatherCardState extends State<WeatherCard> {
  bool _busy = false;
  String? _error;
  final _city = TextEditingController();
  bool _cityInit = false;

  @override
  void dispose() {
    _city.dispose();
    super.dispose();
  }

  HubController get _hub => AppScope.of(context);

  /// The typed text differs from the place in use: it has not been looked up yet.
  bool get _draft {
    final t = _city.text.trim();
    final w = _hub.data.weather;
    return t.isNotEmpty && t != w.city.trim() && t != w.place.trim();
  }

  Future<void> _run(Future<String?> Function() job) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await job();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  /// Look the typed city up; one match is used right away, several are offered to choose from.
  Future<bool> _search() async {
    final svc = _hub.services;
    final q = _city.text.trim();
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    List<wl.GeoPlace> places;
    try {
      places = await svc.weather.search(q);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = friendlyError(e);
        });
      }
      return false;
    }
    if (!mounted) return false;
    setState(() => _busy = false);
    final pick = places.length == 1 ? places.first : await _choose(q, places);
    if (pick == null || !mounted) return false;
    _city.text = pick.label;
    await _run(() => svc.setWeatherPlace(pick));
    if (mounted && _error == null) showMessage(context, 'Weather for ${pick.label}');
    return true;
  }

  Future<wl.GeoPlace?> _choose(String q, List<wl.GeoPlace> places) => showDialog<wl.GeoPlace>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text('Which ${wl.splitPlaceQuery(q).$1}?'),
          children: [
            for (final p in places)
              ListTile(
                leading: const Icon(Icons.place_outlined),
                title: Text(p.name),
                subtitle: Text(p.detail.isEmpty ? '${p.lat.toStringAsFixed(2)}, ${p.lon.toStringAsFixed(2)}' : p.detail),
                onTap: () => Navigator.pop(ctx, p),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ),
            ),
          ],
        ),
      );

  /// Leaving with a typed but not looked-up city: ask instead of dropping it silently.
  Future<void> _onPop(bool didPop) async {
    if (didPop) return;
    final nav = Navigator.of(context);
    final use = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use this city?'),
        content: Text('You typed "${_city.text.trim()}" but did not look it up yet.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Discard')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Look it up')),
        ],
      ),
    );
    if (!mounted || use == null) return;
    if (use) {
      if (!await _search()) return;
    } else {
      _city.text = _hub.data.weather.city;
    }
    if (mounted) nav.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final w = hub.data.weather;
    final svc = hub.services;
    if (!_cityInit) {
      _city.text = w.city;
      _cityInit = true;
    }
    final err = _error ?? (w.mode == 'auto' ? svc.weatherError : null);
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_draft,
      onPopInvokedWithResult: (didPop, _) => _onPop(didPop),
      child: SectionCard(
        icon: Icons.wb_sunny_outlined,
        title: 'Weather',
        sync: 'weather',
        subtitle: 'In the status bar of the dashboard. Live weather refreshes every 15 minutes.',
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'auto', label: Text('Live')),
              ButtonSegment(value: 'manual', label: Text('Type it')),
            ],
            selected: {w.mode},
            onSelectionChanged: _busy ? null : (s) => _run(() => svc.setWeatherMode(s.first)),
          ),
          const SizedBox(height: 8),
          if (w.mode == 'auto') ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(w.useGps ? Icons.my_location : Icons.location_city),
              title: Text(w.place.isNotEmpty ? w.place : (w.useGps ? currentLocationLabel : 'No city chosen yet')),
              subtitle: Text((w.last['summary'] as String?) ?? (_busy ? 'Looking it up…' : 'No live weather yet')),
              trailing: IconButton(
                tooltip: 'Refresh now',
                onPressed: _busy || (!w.useGps && w.lat == null && w.city.isEmpty) ? null : () => _run(svc.refreshWeather),
                icon: const Icon(Icons.refresh),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use my location'),
              subtitle: const Text("From the phone's GPS. Off: a city you choose."),
              value: w.useGps,
              onChanged: _busy
                  ? null
                  : (v) async {
                      if (v && !await ensureLocation(context, why: 'live weather for where you are')) return;
                      await _run(() => svc.setWeatherGps(v));
                    },
            ),
            if (!w.useGps)
              TextField(
                controller: _city,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: 'City or town',
                  hintText: 'e.g. Lyon, or Springfield, Missouri',
                  helperText: _draft ? 'Press search to use this place' : null,
                  suffixIcon: IconButton(
                    tooltip: 'Search',
                    onPressed: _busy || _city.text.trim().isEmpty ? null : _search,
                    icon: const Icon(Icons.search),
                  ),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (!_busy && _city.text.trim().isNotEmpty) _search();
                },
              ),
            if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
          ] else ...[
            CommitField(
              initial: w.tempF.toStringAsFixed(w.tempF % 1 == 0 ? 0 : 1),
              label: 'Temperature (°F)',
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              validator: (v) {
                final d = double.tryParse(v.trim().replaceAll(',', '.'));
                if (d == null) return 'Enter a number, e.g. 72';
                if (d < -80 || d > 150) return 'Between -80 and 150 °F';
                return null;
              },
              onChanged: (v) {
                w.tempF = double.parse(v.trim().replaceAll(',', '.'));
                hub.changed('weather');
              },
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              isExpanded: true,
              initialValue: w.weatherType.clamp(0, weatherTypeNames.length - 1),
              decoration: const InputDecoration(labelText: 'Condition'),
              items: [for (var i = 0; i < weatherTypeNames.length; i++) DropdownMenuItem(value: i, child: Text(weatherTypeNames[i]))],
              onChanged: (v) {
                w.weatherType = v ?? 1;
                hub.changed('weather');
              },
            ),
            const SizedBox(height: 8),
            CommitField(
              initial: w.status,
              label: 'Text (optional)',
              maxLength: 32,
              onChanged: (v) {
                w.status = v;
                hub.changed('weather');
              },
            ),
          ],
          if (err != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(err, style: TextStyle(color: cs.error)),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show in °F'),
            value: w.fahrenheit,
            onChanged: (v) {
              w.fahrenheit = v;
              hub.changed('weather');
            },
          ),
        ],
      ),
    );
  }
}

// ── calendar ──────────────────────────────────────────────────────────────────────────────────
/// An event typed on the phone. All-day events cover the whole local day (local midnight to the
/// next local midnight, which is 23 or 25 hours on a DST change day).
CalEvent typedEvent({
  required String id,
  required String title,
  String location = '',
  required DateTime start,
  required int minutes,
  required bool allDay,
}) {
  int epoch(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;
  final day = DateTime(start.year, start.month, start.day);
  return CalEvent(
    id: id,
    title: title,
    location: location,
    start: allDay ? epoch(day) : epoch(start),
    end: allDay ? epoch(DateTime(start.year, start.month, start.day + 1)) : epoch(start) + minutes * 60,
    allDay: allDay,
  );
}

class CalendarCard extends StatefulWidget {
  const CalendarCard({super.key});
  @override
  State<CalendarCard> createState() => _CalendarCardState();
}

class _CalendarCardState extends State<CalendarCard> {
  bool _syncing = false;

  Future<void> _edit({CalEvent? ev, int? inMinutes}) async {
    final hub = AppScope.of(context);
    final now = DateTime.now();
    var start = ev != null
        ? DateTime.fromMillisecondsSinceEpoch(ev.start * 1000)
        : inMinutes != null
        ? now.add(Duration(minutes: inMinutes))
        : DateTime(now.year, now.month, now.day, now.hour + 1);
    var minutes = ev != null ? ((ev.end - ev.start) ~/ 60) : 60;
    var allDay = ev?.allDay ?? false;
    final title = TextEditingController(text: ev?.title ?? '');
    final loc = TextEditingController(text: ev?.location ?? '');
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false, // a stray tap outside must not throw the typed event away
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(ev == null ? 'New event' : 'Edit event'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  autofocus: ev == null,
                  decoration: const InputDecoration(labelText: 'Title'),
                  onChanged: (_) => setD(() {}),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: loc,
                  decoration: const InputDecoration(labelText: 'Location'),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(MaterialLocalizations.of(ctx).formatMediumDate(start)),
                  subtitle: Text(TimeOfDay.fromDateTime(start).format(ctx)),
                  trailing: const Icon(Icons.edit_calendar),
                  onTap: () async {
                    final first = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));
                    final last = now.add(const Duration(days: 365));
                    final d = await showDatePicker(
                      context: ctx,
                      firstDate: start.isBefore(first) ? start : first,
                      lastDate: start.isAfter(last) ? start : last,
                      initialDate: start,
                    );
                    if (d == null || !ctx.mounted) return;
                    final t = await showTimePicker(context: ctx, initialTime: TimeOfDay.fromDateTime(start));
                    setD(() => start = DateTime(d.year, d.month, d.day, t?.hour ?? start.hour, t?.minute ?? start.minute));
                  },
                ),
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  initialValue: const [15, 30, 45, 60, 90, 120, 180, 240].contains(minutes) ? minutes : 60,
                  decoration: const InputDecoration(labelText: 'Duration'),
                  items: [
                    for (final m in const [15, 30, 45, 60, 90, 120, 180, 240])
                      DropdownMenuItem(value: m, child: Text(m < 60 ? '$m min' : '${m / 60} h')),
                  ],
                  onChanged: (v) => minutes = v ?? 60,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('All day'),
                  value: allDay,
                  onChanged: (v) => setD(() => allDay = v),
                ),
              ],
            ),
          ),
          actions: [
            if (ev != null)
              TextButton(
                onPressed: () {
                  hub.data.events.removeWhere((x) => x.id == ev.id);
                  Navigator.pop(ctx, null);
                  hub.changed('calendar');
                },
                child: const Text('Delete'),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: title.text.trim().isEmpty ? null : () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (saved != true || title.text.trim().isEmpty) return;
    final s = start.millisecondsSinceEpoch ~/ 1000;
    final e = typedEvent(
      id: ev?.id ?? '$s-${title.text.hashCode.abs() % 100000}',
      title: title.text.trim(),
      location: loc.text.trim(),
      start: start,
      minutes: minutes,
      allDay: allDay,
    );
    hub.data.events
      ..removeWhere((x) => x.id == e.id)
      ..add(e)
      ..sort((a, b) => a.start.compareTo(b.start));
    hub.changed('calendar');
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final d = hub.data;
    final c = d.calendar;
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final all = d.allEvents.where((e) => e.end > nowS - 3600).toList();
    final shown = upcoming(d.allEvents, nowS).map((e) => e.id).toSet();
    final t = Theme.of(context).textTheme;

    Future<void> syncNow() async {
      if (_syncing) return;
      setState(() => _syncing = true);
      var changed = false;
      try {
        changed = await hub.services.calendar.syncIcs(c) | await hub.services.calendar.syncPhone(c);
      } catch (e) {
        c.icsNote = friendlyError(e);
      } finally {
        if (mounted) setState(() => _syncing = false);
      }
      unawaited(hub.save());
      if (changed) hub.changed('calendar');
    }

    return SectionCard(
      icon: Icons.event_outlined,
      title: 'Calendar',
      sync: 'calendar',
      subtitle: "Today's and tomorrow's events (up to 8) appear on your glasses.",
      children: [
        if (all.isEmpty) const EmptyState(text: 'No events yet. Add one below, or sync a calendar.', icon: Icons.event_available),
        for (final e in all)
          ListTile(
            dense: true,
            leading: Icon(e.id.startsWith('ics:') ? Icons.link : (e.id.startsWith('dev:') ? Icons.smartphone : Icons.event)),
            title: Text(e.title),
            subtitle: Text(
              '${timeString(e, nowS, h24: d.h24)}${e.location.isNotEmpty ? ' · ${e.location}' : ''}'
              '${shown.contains(e.id) ? '' : ' · not on the glasses yet'}',
            ),
            onTap: e.id.startsWith('ics:') || e.id.startsWith('dev:') ? null : () => _edit(ev: e),
          ),
        Wrap(
          spacing: 8,
          children: [
            ActionChip(avatar: const Icon(Icons.add, size: 18), label: const Text('Event'), onPressed: () => _edit()),
            ActionChip(label: const Text('In 15 min'), onPressed: () => _edit(inMinutes: 15)),
            ActionChip(label: const Text('In 1 hour'), onPressed: () => _edit(inMinutes: 60)),
          ],
        ),
        SwitchListTile(
          title: const Text('24-hour clock'),
          value: d.h24,
          onChanged: (v) {
            d.h24 = v;
            hub.changed('calendar');
          },
        ),
        const Divider(),
        Text('Phone calendar', style: t.titleSmall),
        SwitchListTile(
          title: const Text('Show events from this phone'),
          subtitle: const Text('Google, Samsung, Outlook … whatever the phone syncs'),
          value: c.phoneEnabled,
          onChanged: (v) async {
            if (v && !await hub.services.calendar.requestPhonePermission()) {
              if (context.mounted) {
                showPermissionMessage(context, 'Calendar access was not allowed. Allow "Calendar" for G2 Hub in the app settings to show your phone\'s events.');
              }
              return;
            }
            c.phoneEnabled = v;
            if (v) await hub.services.calendar.syncPhone(c);
            hub.changed('calendar');
          },
        ),
        AdvancedSection(
          title: 'Calendar link (ICS)',
          children: [
            _IcsLinkField(
              initial: c.icsUrl,
              onSaved: (url) {
                c
                  ..icsUrl = url
                  ..icsEvents = []
                  ..icsNote = ''
                  ..icsLastOk = null
                  ..icsEnabled = url.isNotEmpty;
                hub.changed('calendar');
                if (url.isNotEmpty) syncNow();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep this calendar synced (every 15 minutes)'),
              value: c.icsEnabled,
              onChanged: c.icsUrl.isEmpty
                  ? null
                  : (v) {
                      c.icsEnabled = v;
                      hub.changed('calendar');
                      if (v) syncNow();
                    },
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    c.icsNote.isNotEmpty
                        ? c.icsNote
                        : c.icsLastOk != null
                        ? 'Synced ${c.icsEvents.length} event(s) · ${DateTime.fromMillisecondsSinceEpoch(c.icsLastOk! * 1000).toString().substring(11, 16)}'
                        : 'Not synced.',
                    style: t.bodySmall?.copyWith(color: c.icsNote.isNotEmpty ? Theme.of(context).colorScheme.error : null),
                  ),
                ),
                TextButton(onPressed: _syncing || (!c.icsEnabled && !c.phoneEnabled) ? null : syncNow, child: Text(_syncing ? 'Syncing…' : 'Sync now')),
              ],
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('Where do I find the link?', style: t.bodyMedium),
              children: const [
                Text(
                  'Google Calendar: Settings → your calendar → "Secret address in iCal format". Outlook: Settings → '
                  'Calendar → Shared calendars → Publish → ICS. Apple iCloud: share the calendar as Public and copy the '
                  'webcal:// link. The link is private: it stays on this phone and is left out of settings backups.',
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// The ICS link: checked and used when the user saves it (not on every keystroke).
class _IcsLinkField extends StatefulWidget {
  const _IcsLinkField({required this.initial, required this.onSaved});
  final String initial;
  final ValueChanged<String> onSaved;
  @override
  State<_IcsLinkField> createState() => _IcsLinkFieldState();
}

class _IcsLinkFieldState extends State<_IcsLinkField> {
  late final _c = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _save() {
    final v = _c.text.trim();
    if (v.isEmpty) {
      setState(() => _error = null);
      widget.onSaved('');
      return;
    }
    try {
      final url = ics.normalizeUrl(v);
      setState(() => _error = null);
      _c.text = url;
      FocusScope.of(context).unfocus();
      widget.onSaved(url);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final changed = _c.text.trim() != widget.initial;
    return TextField(
      controller: _c,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.done,
      decoration: InputDecoration(
        labelText: 'Calendar link',
        hintText: 'https://calendar.google.com/…/basic.ics',
        errorText: _error,
        errorMaxLines: 3,
        helperText: changed ? 'Press ✓ to use this link' : null,
        suffixIcon: IconButton(tooltip: 'Use this link', onPressed: changed ? _save : null, icon: const Icon(Icons.check)),
      ),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _save(),
    );
  }
}

// ── tasks ─────────────────────────────────────────────────────────────────────────────────────
class TasksCard extends StatefulWidget {
  const TasksCard({super.key});
  @override
  State<TasksCard> createState() => _TasksCardState();
}

class _TasksCardState extends State<TasksCard> {
  final _new = TextEditingController();

  void _add(HubController hub) {
    final t = _new.text.trim();
    if (t.isEmpty) return;
    hub.setTasks([...hub.data.tasks, TaskItem(title: t)]);
    _new.clear();
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final tasks = hub.data.tasks;
    return SectionCard(
      icon: Icons.checklist,
      title: 'Tasks',
      sync: 'tasks',
      subtitle: 'Ticks you make on the glasses come back here. Up to 20 are shown.',
      children: [
        if (tasks.isEmpty) const EmptyState(text: 'No tasks. Add one below.', icon: Icons.task_alt),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: true,
          onReorderItem: (a, b) {
            tasks.insert(b, tasks.removeAt(a));
            hub.setTasks(tasks);
          },
          children: [
            for (final t in tasks)
              CheckboxListTile(
                key: ValueKey('task-${t.uid}-${t.title}'),
                value: t.completed,
                title: Text(t.title, style: t.completed ? const TextStyle(decoration: TextDecoration.lineThrough) : null),
                controlAffinity: ListTileControlAffinity.leading,
                secondary: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    tasks.remove(t);
                    hub.setTasks(tasks);
                  },
                ),
                onChanged: (v) {
                  t.completed = v ?? false;
                  hub.setTasks(tasks);
                },
              ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _new,
                decoration: const InputDecoration(labelText: 'New task'),
                onSubmitted: (_) => _add(hub),
              ),
            ),
            IconButton(onPressed: () => _add(hub), icon: const Icon(Icons.add)),
          ],
        ),
        if (tasks.any((t) => t.completed))
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => hub.setTasks(tasks.where((t) => !t.completed).toList()), child: const Text('Clear done')),
          ),
      ],
    );
  }
}

// ── news ──────────────────────────────────────────────────────────────────────────────────────
class NewsCard extends StatefulWidget {
  const NewsCard({super.key});
  @override
  State<NewsCard> createState() => _NewsCardState();
}

class _NewsCardState extends State<NewsCard> {
  bool _busy = false;

  Future<void> _editItem(HubController hub, {NewsItem? item}) async {
    final title = TextEditingController(text: item?.title ?? '');
    final source = TextEditingController(text: item?.source ?? '');
    final content = TextEditingController(text: item?.content ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item == null ? 'New story' : 'Edit story'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Headline'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: source,
                decoration: const InputDecoration(labelText: 'Source'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: content,
                decoration: const InputDecoration(labelText: 'Text'),
                maxLines: 5,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || title.text.trim().isEmpty) return;
    if (item == null) {
      hub.data.news.add(NewsItem(title: title.text.trim(), source: source.text.trim(), content: content.text.trim()));
    } else {
      item
        ..title = title.text.trim()
        ..source = source.text.trim()
        ..content = content.text.trim();
    }
    hub.changed('news');
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final cfg = hub.data.newsConfig;
    final cache = hub.data.newsCache;
    final svc = hub.services;
    Future<void> refresh() async {
      setState(() => _busy = true);
      try {
        await svc.refreshNews(force: true);
      } catch (_) {}
      if (mounted) setState(() => _busy = false);
    }

    return SectionCard(
      icon: Icons.newspaper,
      title: 'News',
      sync: 'news',
      subtitle: 'Five stories rotate on your glasses; scroll down on the glasses to get new ones. Refreshes every 30 minutes.',
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'feeds', label: Text('News sources')),
            ButtonSegment(value: 'manual', label: Text('My own')),
          ],
          selected: {cfg.mode},
          onSelectionChanged: (s) {
            cfg.mode = s.first;
            hub.changed('news');
            if (cfg.mode == 'feeds' && cache.stories.isEmpty) refresh();
          },
        ),
        const SizedBox(height: 8),
        if (cfg.mode == 'feeds') ...[
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final e in feeds.feeds.entries)
                FilterChip(
                  label: Text(e.value.$1),
                  selected: cfg.feeds.contains(e.key),
                  onSelected: (v) {
                    if (v) {
                      cfg.feeds.add(e.key);
                    } else if (cfg.feeds.length > 1) {
                      cfg.feeds.remove(e.key);
                    }
                    hub.save();
                    refresh();
                  },
                ),
              for (final u in cfg.feeds.where((f) => !feeds.feeds.containsKey(f)))
                InputChip(
                  label: Text(Uri.tryParse(u)?.host ?? u),
                  selected: true,
                  onDeleted: cfg.feeds.length > 1
                      ? () {
                          cfg.feeds.remove(u);
                          hub.save();
                          refresh();
                        }
                      : null,
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('RSS link'),
                onPressed: () async {
                  final c = TextEditingController();
                  final url = await showDialog<String>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Add an RSS or Atom feed'),
                      content: TextField(
                        controller: c,
                        decoration: const InputDecoration(hintText: 'https://…/feed.xml'),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Add')),
                      ],
                    ),
                  );
                  if (url == null || url.isEmpty) return;
                  final u = Uri.tryParse(url);
                  if (u == null || !(u.scheme == 'http' || u.scheme == 'https') || u.host.isEmpty) {
                    if (context.mounted) showMessage(context, 'That is not a web link. Paste the feed address, starting with https://', ok: false);
                    return;
                  }
                  if (cfg.feeds.contains(url)) {
                    if (context.mounted) showMessage(context, 'That feed is already in the list');
                    return;
                  }
                  cfg.feeds.add(url);
                  unawaited(hub.save());
                  unawaited(refresh());
                },
              ),
            ],
          ),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
          if (svc.newsError != null) Text(svc.newsError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (cache.stories.isEmpty && !_busy) const EmptyState(text: 'No stories fetched yet.', icon: Icons.newspaper),
          for (final s in cache.stories)
            ListTile(
              dense: true,
              title: Text((s['title'] ?? '').toString(), maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${s['source']}${s['text_extracted'] == true ? '' : ' · summary only'}'),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(onPressed: _busy ? null : refresh, icon: const Icon(Icons.refresh), label: const Text('New stories')),
          ),
        ] else ...[
          if (hub.data.news.isEmpty) const EmptyState(text: 'No stories. Add your own below.', icon: Icons.article_outlined),
          for (final n in hub.data.news)
            ListTile(
              title: Text(n.title),
              subtitle: Text([n.source, n.content].where((x) => x.isNotEmpty).join(' — '), maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () => _editItem(hub, item: n),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  hub.data.news.remove(n);
                  hub.changed('news');
                },
              ),
            ),
          OutlinedButton.icon(onPressed: () => _editItem(hub), icon: const Icon(Icons.add), label: const Text('Add story')),
        ],
      ],
    );
  }
}

// ── stocks / health (Beta) ───────────────────────────────────────────────────────────────────
class StocksCard extends StatefulWidget {
  const StocksCard({super.key});
  @override
  State<StocksCard> createState() => _StocksCardState();
}

class _StocksCardState extends State<StocksCard> {
  String? _error;
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final s = hub.data.stocks;
    final q = (s.last['quotes'] as List?)?.whereType<Map>().toList() ?? const [];
    return SectionCard(
      icon: Icons.show_chart,
      title: 'Stocks',
      beta: true,
      sync: 'stocks',
      subtitle: 'Quotes from Yahoo Finance (free, no account), refreshed every 15 minutes. Not yet seen on real glasses.',
      children: [
        SwitchListTile(
          title: const Text('Show stocks on the dashboard'),
          value: s.enabled,
          onChanged: (v) {
            s.enabled = v;
            hub.changed('stocks');
          },
        ),
        CommitField(
          initial: s.symbols.join(', '),
          label: 'Symbols (up to 8)',
          hint: 'AAPL, MSFT, NVDA',
          onChanged: (v) {
            try {
              s.symbols = quotes.parseSymbols(v);
              _error = null;
              hub.changed('stocks');
            } on FormatException catch (e) {
              _error = e.message;
            }
            setState(() {});
          },
        ),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (hub.services.stocksError != null) Text(hub.services.stocksError!, style: Theme.of(context).textTheme.bodySmall),
        for (final x in q) ListTile(dense: true, title: Text(quotes.summary(x.cast<String, Object?>())), subtitle: Text('${x['name']}')),
        if (hub.data.ui.feature('custom_widgets'))
          Align(
            alignment: Alignment.centerRight,
            child: ActionButton(
              outlined: true,
              icon: Icons.insert_chart_outlined,
              label: "Show ${s.symbols.isEmpty ? '' : s.symbols.first} chart",
              onPressed: () => hub.services.pushStockChart(s.symbols.isEmpty ? 'AAPL' : s.symbols.first),
            ),
          ),
      ],
    );
  }
}

class HealthCard extends StatefulWidget {
  const HealthCard({super.key});
  static const labels = {
    'steps': 'Steps', 'step_goal': 'Step goal', 'calories': 'Calories (kcal)', 'calorie_goal': 'Calorie goal', //
    'sleep_minutes': 'Sleep (minutes)', 'sleep': 'Sleep score', 'heart_rate': 'Heart rate (bpm)', 'heart_rate_avg': 'Average heart rate',
    'spo2': 'Blood oxygen (%)', 'spo2_avg': 'Average blood oxygen',
  };
  @override
  State<HealthCard> createState() => _HealthCardState();
}

class _HealthCardState extends State<HealthCard> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final svc = AppScope.of(context, listen: false).services;
    if (svc.data.health.fromPhone) unawaited(svc.refreshHealthAccess());
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final svc = hub.services;
    final h = hub.data.health;
    final source = svc.healthSource.name;
    final imported = h.fromPhone ? importedHealthKeys.toSet() : const <String>{};
    final avail = svc.healthAvailability;
    return SectionCard(
      icon: Icons.favorite_outline,
      title: 'Health',
      beta: true,
      sync: 'health',
      subtitle: h.fromPhone
          ? "Steps, heart rate and last night's sleep come from $source; goals and the rest are typed. Not yet seen on real glasses."
          : "Today's numbers for the health card (typed by you). Not yet seen on real glasses.",
      children: [
        SwitchListTile(
          title: const Text('Show the health card'),
          value: h.enabled,
          onChanged: (v) {
            h.enabled = v;
            hub.changed('health');
          },
        ),
        SegmentedButton<bool>(
          segments: [
            const ButtonSegment(value: false, label: Text('Type them')),
            ButtonSegment(value: true, label: Text('From $source')),
          ],
          selected: {h.fromPhone},
          onSelectionChanged: _busy ? null : (s) => _run(() => svc.setHealthSource(s.first)),
        ),
        if (h.fromPhone) ...[
          const SizedBox(height: 8),
          if (avail == HealthAvailability.unsupported)
            PermissionBanner(
              icon: Icons.health_and_safety_outlined,
              title: '$source is not available',
              text: 'This phone cannot give health data to apps. Type the numbers instead.',
              actionLabel: 'Type them',
              onAction: () => _run(() => svc.setHealthSource(false)),
            )
          else if (avail == HealthAvailability.notInstalled || avail == HealthAvailability.updateRequired)
            PermissionBanner(
              icon: Icons.download_outlined,
              title: avail == HealthAvailability.notInstalled ? 'Install $source' : 'Update $source',
              text: '$source keeps the steps, heart rate and sleep your phone and watch record. Get it from the Play Store, then come back.',
              actionLabel: avail == HealthAvailability.notInstalled ? 'Install' : 'Update',
              onAction: svc.healthSource.install,
            )
          else if (avail == HealthAvailability.available && !svc.healthAccess)
            PermissionBanner(
              icon: Icons.lock_open,
              title: 'Allow access in $source',
              text: 'G2 Hub only reads steps, heart rate and sleep, and only to show them on your glasses.',
              actionLabel: 'Allow',
              onAction: _busy
                  ? null
                  : () => _run(() async {
                        if (!await svc.requestHealthAccess() && context.mounted) {
                          showMessage(context, 'Access was not allowed. You can allow it later in $source.', ok: false);
                        }
                      }),
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  h.importNote.isNotEmpty
                      ? h.importNote
                      : h.importedAt == null
                      ? 'Not imported yet.'
                      : 'Imported ${_ago(h.importedAt!)} · refreshes every 15 minutes while the glasses are connected',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: h.importNote.isNotEmpty ? Theme.of(context).colorScheme.error : null),
                ),
              ),
              TextButton.icon(
                onPressed: _busy || !svc.healthAccess ? null : () => _run(svc.importHealth),
                icon: const Icon(Icons.sync),
                label: const Text('Import now'),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final k in healthFields.keys)
              SizedBox(
                width: 150,
                child: imported.contains(k)
                    ? InputDecorator(
                        decoration: InputDecoration(labelText: HealthCard.labels[k], helperText: 'from $source'),
                        child: Text(h.values[k]?.toString() ?? '—'),
                      )
                    : CommitField(
                        initial: h.values[k]?.toString() ?? '',
                        label: HealthCard.labels[k],
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          if (v.trim().isEmpty) return null;
                          try {
                            cleanHealth({k: v});
                            return null;
                          } catch (e) {
                            return friendlyError(e);
                          }
                        },
                        onChanged: (v) {
                          if (v.trim().isEmpty) {
                            h.values.remove(k);
                          } else {
                            h.values[k] = cleanHealth({k: v})[k]!;
                          }
                          hub.changed('health');
                        },
                      ),
              ),
          ],
        ),
      ],
    );
  }

  static String _ago(int at) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(at * 1000));
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    return '${d.inHours} h ago';
  }
}

// ── dashboard layout (Beta) ──────────────────────────────────────────────────────────────────
class LayoutCard extends StatelessWidget {
  const LayoutCard({super.key});
  static const _names = {widgetNews: 'News', widgetSchedule: 'Calendar', widgetStock: 'Stocks', widgetQuicklist: 'Tasks', widgetHealth: 'Health'};
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final l = hub.data.layout;
    final missing = _names.keys.where((k) => !l.order.contains(k)).toList();
    return SectionCard(
      icon: Icons.view_carousel_outlined,
      title: 'Widget order',
      beta: true,
      sync: 'layout',
      subtitle: 'The order of the widgets on your dashboard. Off = the glasses\' default order.',
      children: [
        SwitchListTile(
          title: const Text('Use my order'),
          value: l.custom,
          onChanged: (v) {
            l.custom = v;
            hub.changed('layout');
          },
        ),
        if (l.custom) ...[
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            onReorderItem: (a, b) {
              l.order.insert(b, l.order.removeAt(a));
              hub.changed('layout');
            },
            children: [
              for (final (i, id) in l.order.indexed)
                ListTile(
                  key: ValueKey('w$i-$id'),
                  leading: const Icon(Icons.drag_handle),
                  title: Text(_names[id] ?? 'Widget $id'),
                  trailing: IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: l.order.length <= 1
                        ? null
                        : () {
                            l.order.removeAt(i);
                            hub.changed('layout');
                          },
                  ),
                ),
            ],
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final k in missing)
                ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: Text(_names[k]!),
                  onPressed: () {
                    l.order.add(k);
                    hub.changed('layout');
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }
}

// ── profiles ──────────────────────────────────────────────────────────────────────────────────
class ProfilesCard extends StatelessWidget {
  const ProfilesCard({super.key});

  Future<void> _rule(BuildContext context, HubController hub, [int? index]) async {
    // Edit a copy: the saved rules change only when the edited set is valid.
    final rules = [...hub.data.schedule.rules];
    final r = index == null ? <String, Object?>{'profile': hub.data.profiles.keys.first, 'start': '09:00', 'end': '17:00'} : {...rules[index]};
    var profile = r['profile'] as String;
    var start = TimeOfDay(hour: prof.minutesOf(r['start']) ~/ 60, minute: prof.minutesOf(r['start']) % 60);
    var end = TimeOfDay(hour: prof.minutesOf(r['end']) ~/ 60, minute: prof.minutesOf(r['end']) % 60);
    final days = {...((r['days'] as List?)?.cast<int>() ?? const <int>[])};
    String hm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Switch profile automatically'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: hub.data.profiles.containsKey(profile) ? profile : hub.data.profiles.keys.first,
                decoration: const InputDecoration(labelText: 'Profile'),
                items: [for (final n in hub.data.profiles.keys) DropdownMenuItem(value: n, child: Text(n))],
                onChanged: (v) => profile = v ?? profile,
              ),
              ListTile(
                title: const Text('From'),
                trailing: Text(hm(start)),
                onTap: () async {
                  final t = await showTimePicker(context: ctx, initialTime: start);
                  if (t != null) setD(() => start = t);
                },
              ),
              ListTile(
                title: const Text('Until'),
                trailing: Text(hm(end)),
                onTap: () async {
                  final t = await showTimePicker(context: ctx, initialTime: end);
                  if (t != null) setD(() => end = t);
                },
              ),
              Wrap(
                spacing: 4,
                children: [
                  for (final (i, d) in const ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'].indexed)
                    FilterChip(label: Text(d), selected: days.contains(i), onSelected: (v) => setD(() => v ? days.add(i) : days.remove(i))),
                ],
              ),
              const Text('No days selected = every day.'),
            ],
          ),
          actions: [
            if (index != null)
              TextButton(
                onPressed: () {
                  rules.removeAt(index);
                  Navigator.pop(ctx, null);
                },
                child: const Text('Delete'),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok == true) {
      final rule = {'profile': profile, 'start': hm(start), 'end': hm(end), if (days.isNotEmpty) 'days': (days.toList()..sort())};
      if (index == null) {
        rules.add(rule);
      } else {
        rules[index] = rule;
      }
    } else if (ok == false) {
      return; // cancelled (null = deleted)
    }
    try {
      hub.services.setSchedule(hub.data.schedule.enabled, rules);
    } on prof.ProfileError catch (e) {
      if (context.mounted) showMessage(context, e.message, ok: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final d = hub.data;
    final svc = hub.services;
    return SectionCard(
      icon: Icons.layers_outlined,
      title: 'Profiles',
      subtitle: 'Save this pair\'s widgets, menu and settings as "Work", "Home"… and switch with one tap or on a schedule.',
      children: [
        if (d.profiles.isEmpty) const EmptyState(text: 'No profiles yet.', icon: Icons.layers_outlined),
        for (final n in (d.profiles.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))))
          ListTile(
            leading: Icon(d.activeProfile == n ? Icons.radio_button_checked : Icons.radio_button_off),
            title: Text(n),
            subtitle: Text(d.activeProfile == n ? 'Active' : 'Tap to use'),
            onTap: () {
              svc.applyProfile(n);
              showMessage(context, 'Profile "$n" applied');
            },
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'save') svc.saveProfile(n);
                if (v == 'delete') svc.deleteProfile(n);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'save', child: Text('Replace with current setup')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ),
        OutlinedButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Save current setup as a profile'),
          onPressed: () async {
            final c = TextEditingController();
            final name = await showDialog<String>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Profile name'),
                content: TextField(
                  controller: c,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Work'),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
                ],
              ),
            );
            if (name == null) return;
            try {
              final clean = prof.cleanName(name);
              if (d.profiles.containsKey(clean) && context.mounted) {
                final yes = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text('Replace "$clean"?'),
                    content: const Text('A profile with this name exists. Replace it with the current setup?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Replace')),
                    ],
                  ),
                );
                if (yes != true) return;
              }
              svc.saveProfile(name);
            } on prof.ProfileError catch (e) {
              if (context.mounted) showMessage(context, e.message, ok: false);
            }
          },
        ),
        if (d.profiles.isNotEmpty) ...[
          const Divider(),
          SwitchListTile(
            title: const Text('Switch on a schedule'),
            value: d.schedule.enabled,
            onChanged: (v) => svc.setSchedule(v, d.schedule.rules),
          ),
          for (final (i, r) in d.schedule.rules.indexed)
            ListTile(
              dense: true,
              leading: const Icon(Icons.schedule),
              title: Text('${r['profile']}  ${r['start']}–${r['end']}'),
              subtitle: Text(
                (r['days'] as List?)?.isNotEmpty == true
                    ? (r['days'] as List).map((x) => const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][x as int]).join(', ')
                    : 'Every day',
              ),
              onTap: () => _rule(context, hub, i),
            ),
          TextButton.icon(onPressed: () => _rule(context, hub), icon: const Icon(Icons.add_alarm), label: const Text('Add a time')),
        ],
      ],
    );
  }
}
