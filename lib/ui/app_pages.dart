/// App pages under Apps: Translate text, Teleprompter, Navigation, EvenHub apps, Custom widgets.
/// Buttons here start or control an app on the glasses (genuine actions); settings save as you
/// change them.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../hub/features.dart' show PushResult;
import '../hub/hub_controller.dart';
import '../hub/models.dart';
import '../protocol/navigation.dart' as nav;
import '../protocol/teleprompter.dart' as tp;
import '../services/data_services.dart';
import '../services/evenhub_service.dart' show declaresLocation;
import 'app_scope.dart';
import 'common.dart';

// ── Translate (typed text on the native Translate screen) ─────────────────────────────────────
class TranslateTextPage extends StatefulWidget {
  const TranslateTextPage({super.key});
  @override
  State<TranslateTextPage> createState() => _TranslateTextPageState();
}

class _TranslateTextPageState extends State<TranslateTextPage> {
  final _srcLang = TextEditingController(text: 'EN');
  final _dstLang = TextEditingController(text: 'ES');
  final _src = TextEditingController();
  final _dst = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Shows two lines in the glasses\' Translate screen: the original and the translation. '
          'For speech, use Live translate.',
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _srcLang,
                decoration: const InputDecoration(labelText: 'From'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _dstLang,
                decoration: const InputDecoration(labelText: 'To'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _src,
          decoration: const InputDecoration(labelText: 'Original text'),
          maxLines: 3,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _dst,
          decoration: const InputDecoration(labelText: 'Translation'),
          maxLines: 3,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ActionButton(
              label: 'Show on glasses',
              icon: Icons.translate,
              onPressed: () async {
                if (_src.text.trim().isEmpty && _dst.text.trim().isEmpty) {
                  return PushResult(false, 'Type the original text or the translation first');
                }
                final f = hub.features!;
                if (f.currentApp != 'translate') {
                  final r = await f.translateOpen(_srcLang.text, _dstLang.text);
                  if (!r.ok) return r;
                }
                return f.translateText(_src.text, _dst.text);
              },
            ),
            ActionButton(label: 'Close', icon: Icons.close, outlined: true, onPressed: () async => hub.features?.closeApp()),
          ],
        ),
        const SizedBox(height: 8),
        Text('Decoded from the official app; not yet confirmed on real glasses.', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

// ── Teleprompter ──────────────────────────────────────────────────────────────────────────────
class TeleprompterPage extends StatefulWidget {
  const TeleprompterPage({super.key});
  @override
  State<TeleprompterPage> createState() => _TeleprompterPageState();
}

class _TeleprompterPageState extends State<TeleprompterPage> {
  TextEditingController? _text;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _text?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final prefs = hub.data.teleprompter;
    _text ??= TextEditingController(text: hub.data.teleprompterScript);
    final pages = tp.paginate(_text!.text, charsPerLine: prefs.charsPerLine);
    final (np, nl) = tp.totals(pages);
    final f = hub.features;
    final running = f?.currentApp == 'teleprompter';
    final pos = f?.prompter;
    void save() => hub.save();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (running && pos != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('On your glasses · page ${pos.page + 1} of ${pos.totalPages}${pos.paused ? ' · paused' : ''}'),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: pos.totalPages == 0 ? 0 : (pos.page + 1) / pos.totalPages),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      IconButton.filledTonal(
                        onPressed: pos.page > 0 ? () => f!.teleprompterJump(pos.page - 1) : null,
                        icon: const Icon(Icons.skip_previous),
                      ),
                      IconButton.filled(
                        onPressed: () => pos.paused ? f!.teleprompterResume() : f!.teleprompterPause(),
                        icon: Icon(pos.paused ? Icons.play_arrow : Icons.pause),
                      ),
                      IconButton.filledTonal(
                        onPressed: pos.page + 1 < pos.totalPages ? () => f!.teleprompterJump(pos.page + 1) : null,
                        icon: const Icon(Icons.skip_next),
                      ),
                      OutlinedButton.icon(onPressed: () => f!.closeApp(), icon: const Icon(Icons.stop), label: const Text('Stop')),
                    ],
                  ),
                ],
              ),
            ),
          ),
        Row(
          children: [
            Expanded(child: Text('Script', style: Theme.of(context).textTheme.titleMedium)),
            IconButton(
              tooltip: 'Open a text file',
              icon: const Icon(Icons.folder_open),
              onPressed: () async {
                final String t;
                try {
                  final r = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['txt', 'md']);
                  final path = r.isEmpty ? null : r.first.path;
                  if (path == null) return;
                  t = utf8.decode(await File(path).readAsBytes(), allowMalformed: true);
                } catch (e) {
                  if (context.mounted) showMessage(context, 'Could not open the file: ${friendlyError(e)}', ok: false);
                  return;
                }
                setState(() => _text!.text = t);
                hub.data.teleprompterScript = t;
                save();
              },
            ),
            IconButton(
              tooltip: 'Save to library',
              icon: const Icon(Icons.bookmark_add_outlined),
              onPressed: () async {
                final name = await _ask(context, 'Name this script', _text!.text.split('\n').first.trim());
                if (name == null || name.trim().isEmpty) return;
                prefs.scripts.add(Script('${DateTime.now().millisecondsSinceEpoch}', name.trim(), _text!.text));
                save();
                setState(() {});
              },
            ),
          ],
        ),
        TextField(
          controller: _text,
          maxLines: 10,
          minLines: 6,
          decoration: const InputDecoration(hintText: 'Paste or type your script'),
          onChanged: (v) {
            hub.data.teleprompterScript = v;
            save();
            setState(() {});
          },
        ),
        const SizedBox(height: 4),
        Text('$np page(s), $nl line(s) of up to ${prefs.charsPerLine} characters'),
        if (prefs.scripts.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Library (also offered when you open Teleprompt on the glasses)', style: Theme.of(context).textTheme.labelLarge),
          for (final s in prefs.scripts)
            ListTile(
              dense: true,
              leading: const Icon(Icons.description_outlined),
              title: Text(s.name),
              subtitle: Text(s.text.replaceAll('\n', ' '), maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => setState(() {
                _text!.text = s.text;
                hub.data.teleprompterScript = s.text;
                save();
              }),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => setState(() {
                  prefs.scripts.remove(s);
                  save();
                }),
              ),
            ),
        ],
        const Divider(height: 24),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: tp.modeManual, label: Text('Scroll by touch')),
            ButtonSegment(value: tp.modeAuto, label: Text('Auto scroll')),
          ],
          selected: {prefs.mode == tp.modeAuto ? tp.modeAuto : tp.modeManual},
          onSelectionChanged: (s) => setState(() {
            prefs.mode = s.first;
            save();
          }),
        ),
        if (prefs.mode == tp.modeAuto)
          ListTile(
            title: Text('Speed: one line every ${(prefs.intervalMs / 1000).toStringAsFixed(1)} s'),
            subtitle: Slider(
              value: prefs.intervalMs.toDouble().clamp(500, 10000),
              min: 500,
              max: 10000,
              divisions: 19,
              onChanged: (v) => setState(() {
                prefs.intervalMs = v.round();
                save();
              }),
            ),
          ),
        ListTile(
          title: Text('Line width: ${prefs.charsPerLine} characters'),
          subtitle: Slider(
            value: prefs.charsPerLine.toDouble().clamp(20, 36),
            min: 20,
            max: 36,
            divisions: 16,
            onChanged: (v) => setState(() {
              prefs.charsPerLine = v.round();
              save();
            }),
          ),
        ),
        ListTile(
          title: const Text('Countdown before it starts'),
          trailing: DropdownButton<int>(
            value: const [0, 3, 5, 10].contains(prefs.countdown) ? prefs.countdown : 0,
            items: const [
              DropdownMenuItem(value: 0, child: Text('None')),
              DropdownMenuItem(value: 3, child: Text('3 s')),
              DropdownMenuItem(value: 5, child: Text('5 s')),
              DropdownMenuItem(value: 10, child: Text('10 s')),
            ],
            onChanged: (v) => setState(() {
              prefs.countdown = v ?? 0;
              save();
            }),
          ),
        ),
        const SizedBox(height: 8),
        ActionButton(
          label: running ? 'Restart on glasses' : 'Start on glasses',
          onPressed: () async => _text!.text.trim().isEmpty
              ? PushResult(false, 'Type or open a script first')
              : hub.features!.teleprompterStart(
            _text!.text,
            mode: prefs.mode,
            scrollIntervalMs: prefs.mode == tp.modeAuto ? prefs.intervalMs : 0,
            charsPerLine: prefs.charsPerLine,
            countdownSeconds: prefs.countdown,
          ),
        ),
        const SizedBox(height: 8),
        Text('Decoded from the official app; not yet confirmed on real glasses.', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

Future<String?> _ask(BuildContext context, String title, [String initial = '']) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('OK')),
      ],
    ),
  );
}

// ── Navigation ────────────────────────────────────────────────────────────────────────────────
class NavigationPage extends StatefulWidget {
  const NavigationPage({super.key});
  @override
  State<NavigationPage> createState() => _NavigationPageState();
}

class _NavigationPageState extends State<NavigationPage> {
  final _to = TextEditingController();
  final _from = TextEditingController();
  String _dir = 'TURN_RIGHT';
  final _dist = TextEditingController(text: '200 m');
  final _road = TextEditingController();
  bool? _gps;

  @override
  void initState() {
    super.initState();
    LocationService.granted().then((v) {
      if (mounted) setState(() => _gps = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final svc = hub.services.nav;
    final prefs = hub.data.nav;
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) {
        final rt = svc.route;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (rt != null)
              SectionCard(
                icon: Icons.navigation,
                title: 'On your way',
                subtitle: 'To ${rt.to}',
                children: [
                  for (var i = 0; i < rt.steps.length; i++)
                    ListTile(
                      dense: true,
                      selected: i == rt.index,
                      leading: Icon(i < rt.index ? Icons.check : (i == rt.index ? Icons.arrow_forward : Icons.circle_outlined), size: 18),
                      title: Text(
                        '${nav.direction.keys.contains(_dirName(rt.steps[i].maneuver)) ? _pretty(_dirName(rt.steps[i].maneuver)) : rt.steps[i].maneuver}'
                        '${rt.steps[i].road.isNotEmpty ? ' onto ${rt.steps[i].road}' : ''}',
                      ),
                    ),
                  if (svc.tracker?.toNext != null) Text('Next turn in ${svc.tracker!.toNext!.round()} m'),
                  Wrap(
                    spacing: 8,
                    children: [
                      ActionButton(label: 'Next turn', icon: Icons.skip_next, outlined: true, onPressed: svc.next),
                      ActionButton(label: 'Stop', icon: Icons.stop, outlined: true, onPressed: () async => svc.stop()),
                    ],
                  ),
                ],
              ),
            SectionCard(
              icon: Icons.directions,
              title: 'Directions',
              subtitle: 'The route starts where you are (GPS) and moves on by itself as you go.',
              children: [
                if (_gps == false)
                  ListTile(
                    leading: const Icon(Icons.location_off),
                    title: const Text('Allow location for live turn-by-turn'),
                    subtitle: const Text('Without it, type a start and move on with "Next turn".'),
                    trailing: TextButton(
                      onPressed: () async {
                        final ok = await ensureLocation(context, why: 'turn-by-turn directions');
                        if (mounted) setState(() => _gps = ok);
                      },
                      child: const Text('Allow'),
                    ),
                  ),
                TextField(
                  controller: _to,
                  decoration: const InputDecoration(labelText: 'Where to?', hintText: 'Address, place or "lat,lon"'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _from,
                  decoration: const InputDecoration(labelText: 'From (empty = my location)'),
                ),
                SwitchListTile(
                  title: const Text('Advance turns automatically (GPS)'),
                  value: prefs.autoAdvance,
                  onChanged: (v) {
                    prefs.autoAdvance = v;
                    hub.save();
                  },
                ),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: nav.methodWalking, icon: Icon(Icons.directions_walk), label: Text('Walk')),
                    ButtonSegment(value: nav.methodCycling, icon: Icon(Icons.directions_bike), label: Text('Bike')),
                  ],
                  selected: {prefs.method},
                  onSelectionChanged: (s) {
                    prefs.method = s.first;
                    hub.save();
                  },
                ),
                const SizedBox(height: 8),
                if (svc.status != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(svc.status!)),
                Wrap(
                  spacing: 8,
                  children: [
                    ActionButton(
                      label: 'Start navigation',
                      icon: Icons.navigation,
                      onPressed: () async =>
                          _to.text.trim().isEmpty ? PushResult(false, 'Type where you want to go first') : svc.start(_to.text, from: _from.text),
                    ),
                    TextButton.icon(
                      onPressed: _to.text.trim().isEmpty
                          ? null
                          : () async {
                              final name = await _ask(context, 'Save as favorite', _to.text.trim());
                              if (name == null || name.trim().isEmpty) return;
                              prefs.favorites.add(NavFavorite(name.trim(), _to.text.trim()));
                              unawaited(hub.save());
                              setState(() {});
                            },
                      icon: const Icon(Icons.star_outline),
                      label: const Text('Save as favorite'),
                    ),
                  ],
                ),
                Text(
                  'Places go to nominatim.openstreetmap.org and router.project-osrm.org (free public services).',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            SectionCard(
              icon: Icons.star_outline,
              title: 'Favorites',
              subtitle: 'Also offered when you open Navigate on your glasses.',
              children: [
                if (prefs.favorites.isEmpty) const EmptyState(text: 'No favorites yet. Type a place above and save it.'),
                for (final fav in prefs.favorites)
                  ListTile(
                    leading: const Icon(Icons.place_outlined),
                    title: Text(fav.name),
                    subtitle: Text(fav.query, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => setState(() => _to.text = fav.query),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => setState(() {
                        prefs.favorites.remove(fav);
                        hub.save();
                      }),
                    ),
                  ),
              ],
            ),
            SectionCard(
              icon: Icons.turn_right,
              title: 'Send a single turn',
              children: [
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _dir,
                  decoration: const InputDecoration(labelText: 'Arrow'),
                  items: [for (final d in nav.direction.keys) DropdownMenuItem(value: d, child: Text(_pretty(d)))],
                  onChanged: (v) => setState(() => _dir = v ?? _dir),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _dist,
                        decoration: const InputDecoration(labelText: 'Distance'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _road,
                        decoration: const InputDecoration(labelText: 'Road'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ActionButton(
                  label: 'Show turn',
                  icon: Icons.send,
                  onPressed: () => svc.singleTurn(_dir, distance: _dist.text, road: _road.text),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  static String _dirName(String maneuver) {
    final i = maneuver.indexOf(':');
    final mod = i < 0 ? '' : maneuver.substring(i + 1);
    if (maneuver.startsWith('depart')) return 'DEPART';
    if (maneuver.startsWith('arrive')) return 'ARRIVE';
    return const {'left': 'TURN_LEFT', 'right': 'TURN_RIGHT', 'slight left': 'TURN_SLIGHT_LEFT', 'slight right': 'TURN_SLIGHT_RIGHT'}[mod] ??
        'STRAIGHT';
  }

  static String _pretty(String d) {
    final s = d.toLowerCase().replaceAll('_', ' ').replaceAll(' ccw', ' (counter-clockwise)').replaceAll(' cw', ' (clockwise)');
    return s.isEmpty ? d : s[0].toUpperCase() + s.substring(1);
  }
}

// ── EvenHub apps ──────────────────────────────────────────────────────────────────────────────
class EvenHubPage extends StatefulWidget {
  const EvenHubPage({super.key});
  @override
  State<EvenHubPage> createState() => _EvenHubPageState();
}

class _EvenHubPageState extends State<EvenHubPage> {
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final reg = hub.services.registry;
    final rt = hub.services.evenhub;
    if (reg == null || rt == null) return const Center(child: Text('EvenHub apps are not available on this device.'));
    final apps = reg.list();
    final inMenu = hub.data.evenhubMenu;
    return ListenableBuilder(
      listenable: rt,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'EvenHub apps are small web apps. The phone runs them and draws their pages on your glasses. '
            'Apps you put in the menu appear on the glasses next to the built-in ones.',
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Install an .ehpk package'),
            onPressed: () async {
              final r = await FilePicker.pickFiles(type: FileType.any);
              final path = r.isEmpty ? null : r.first.path;
              if (path == null) return;
              try {
                final e = reg.install(await File(path).readAsBytes(), label: path.split('/').last);
                final pid = e['package_id'] as String;
                if (!inMenu.contains(pid)) inMenu.add(pid);
                hub.changed('menu');
                if (context.mounted) showMessage(context, 'Installed ${e['name']} — added to your glasses menu');
                setState(() {});
              } catch (err) {
                if (context.mounted) showMessage(context, friendlyError(err), ok: false);
              }
            },
          ),
          if (rt.running)
            Card(
              child: ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: Text('Running: ${rt.current!['name']}'),
                trailing: TextButton(onPressed: () => rt.stop(closePage: true), child: const Text('Stop')),
              ),
            ),
          const SizedBox(height: 8),
          if (apps.isEmpty) const EmptyState(text: 'No apps installed yet.', icon: Icons.extension_outlined),
          for (final a in apps)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${a['name']}  ${a['version']}', style: Theme.of(context).textTheme.titleMedium),
                    Text('${a['package_id']} · ${a['kind']}', style: Theme.of(context).textTheme.bodySmall),
                    if ((a['permissions'] as List?)?.isNotEmpty == true)
                      Text(
                        'Uses: ${(a['permissions'] as List).map((p) => (p as Map)['name']).join(', ')}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (declaresLocation(a)) const _AppLocationRow(),
                    if (hub.data.ui.devMode && (a['problems'] as List?)?.isNotEmpty == true)
                      Text('Manifest notes: ${(a['problems'] as List).join('; ')}', style: Theme.of(context).textTheme.bodySmall),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('In the glasses menu'),
                      value: inMenu.contains(a['package_id']),
                      onChanged: (v) {
                        if (v) {
                          if (hub.data.menu.length + inMenu.length >= 10) {
                            showMessage(context, 'The menu holds 10 items. Remove one first.', ok: false);
                            return;
                          }
                          inMenu.add(a['package_id'] as String);
                        } else {
                          inMenu.remove(a['package_id']);
                        }
                        hub.changed('menu');
                        setState(() {});
                      },
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        ActionButton(label: 'Open on glasses', onPressed: () => rt.launch(a['package_id'] as String)),
                        TextButton(
                          onPressed: () async {
                            await rt.uninstall(a['package_id'] as String);
                            inMenu.remove(a['package_id']);
                            hub.changed('menu');
                            if (mounted) setState(() {});
                          },
                          child: const Text('Uninstall'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// For an app that declares the `location` permission: whether G2 Hub may use the location
/// (apps run hidden and cannot ask themselves) and the button that asks.
class _AppLocationRow extends StatefulWidget {
  const _AppLocationRow();
  @override
  State<_AppLocationRow> createState() => _AppLocationRowState();
}

class _AppLocationRowState extends State<_AppLocationRow> {
  LocationAccess? _access;

  @override
  void initState() {
    super.initState();
    LocationService.access().then((a) {
      if (mounted) setState(() => _access = a);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ok = _access == LocationAccess.granted;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(ok ? Icons.location_on_outlined : Icons.location_off_outlined),
      title: Text(ok ? 'Location: allowed' : 'Location: not allowed yet'),
      subtitle: const Text('This app asks for your location. It gets it only while you allow location for G2 Hub.'),
      trailing: ok || _access == null
          ? null
          : TextButton(
              onPressed: () async {
                final granted = await ensureLocation(context, why: 'glasses apps');
                if (mounted) setState(() => _access = granted ? LocationAccess.granted : _access);
              },
              child: const Text('Allow'),
            ),
    );
  }
}

// ── Custom widgets ────────────────────────────────────────────────────────────────────────────
class CustomWidgetsPage extends StatefulWidget {
  const CustomWidgetsPage({super.key});
  @override
  State<CustomWidgetsPage> createState() => _CustomWidgetsPageState();
}

class _CustomWidgetsPageState extends State<CustomWidgetsPage> {
  Future<void> _edit(HubController hub, [CustomWidgetSpec? w]) async {
    final spec = w ?? CustomWidgetSpec(id: '${DateTime.now().millisecondsSinceEpoch}', title: 'My graph');
    final c = {
      for (final k in ['title', 'values', 'url', 'unit', 'value', 'label', 'symbol'])
        k: TextEditingController(text: (spec.toJson()[k] ?? '').toString()),
    };
    var type = spec.type;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(w == null ? 'New widget' : 'Edit widget'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'graph', label: Text('Graph')),
                    ButtonSegment(value: 'metric', label: Text('Number')),
                    ButtonSegment(value: 'stock', label: Text('Stock')),
                  ],
                  selected: {type},
                  onSelectionChanged: (s) => setD(() => type = s.first),
                ),
                if (type != 'stock')
                  TextField(
                    controller: c['title'],
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                if (type == 'graph') ...[
                  TextField(
                    controller: c['values'],
                    decoration: const InputDecoration(labelText: 'Numbers', hintText: '1, 4, 2, 8'),
                  ),
                  TextField(
                    controller: c['url'],
                    decoration: const InputDecoration(labelText: 'Or a data URL (JSON or CSV)'),
                  ),
                  TextField(
                    controller: c['unit'],
                    decoration: const InputDecoration(labelText: 'Unit'),
                  ),
                ],
                if (type == 'metric') ...[
                  TextField(
                    controller: c['value'],
                    decoration: const InputDecoration(labelText: 'Value'),
                  ),
                  TextField(
                    controller: c['label'],
                    decoration: const InputDecoration(labelText: 'Label'),
                  ),
                ],
                if (type == 'stock')
                  TextField(
                    controller: c['symbol'],
                    decoration: const InputDecoration(labelText: 'Symbol', hintText: 'AAPL'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    spec
      ..type = type
      ..title = c['title']!.text
      ..values = c['values']!.text
      ..url = c['url']!.text.trim()
      ..unit = c['unit']!.text
      ..value = c['value']!.text
      ..label = c['label']!.text
      ..symbol = c['symbol']!.text.trim();
    if (w == null) hub.data.customWidgets.add(spec);
    await hub.save();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final list = hub.data.customWidgets;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Draw a graph, a big number or a stock chart as a picture on your glasses (experimental: '
          'pictures are not yet confirmed on real glasses).',
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(onPressed: () => _edit(hub), icon: const Icon(Icons.add), label: const Text('New widget')),
        if (list.isEmpty) const EmptyState(text: 'No widgets yet.', icon: Icons.show_chart),
        for (final w in list)
          Card(
            child: ListTile(
              title: Text(w.type == 'stock' ? 'Stock ${w.symbol}' : w.title),
              subtitle: Text(
                w.type == 'graph'
                    ? (w.url.isNotEmpty ? 'From ${Uri.tryParse(w.url)?.host ?? w.url}' : w.values)
                    : (w.type == 'metric' ? w.value : 'Today\'s chart'),
              ),
              onTap: () => _edit(hub, w),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Show on glasses',
                    icon: const Icon(Icons.visibility),
                    onPressed: hub.status != LinkStatus.connected
                        ? null
                        : () async {
                            final r = await hub.services.pushCustomWidget(w);
                            if (context.mounted) showMessage(context, r.message, ok: r.ok);
                          },
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      list.remove(w);
                      hub.save();
                      setState(() {});
                    },
                  ),
                ],
              ),
            ),
          ),
        if (hub.features?.holdHeartbeat == true)
          TextButton(onPressed: () => setState(() => hub.features?.releaseEvenHub()), child: const Text('Back to the dashboard on the glasses')),
      ],
    );
  }
}
