/// Glasses: your pairs (find, switch, rename, forget, setup guide), device info, display and
/// behaviour, the glasses menu, notifications and (Beta) the watchface. Settings apply to the
/// glasses as you change them and are remembered for this pair.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../hub/hub_controller.dart';
import '../logic/notification_filter.dart';
import '../protocol/menu.dart' as menu;
import '../protocol/settings.dart' as st;
import '../protocol/watchface.dart' as wf;
import 'app_scope.dart';
import 'common.dart';
import 'home_shell.dart';
import 'report_problem_screen.dart';
import 'scan_screen.dart';
import 'setup_guide.dart';
import 'tile_status.dart';
import 'tiles.dart';

class GlassesScreen extends StatelessWidget {
  const GlassesScreen({super.key});
  @override
  Widget build(BuildContext context) => PageList(
    title: 'Glasses',
    subtitle: 'Your pairs, display, menu and notifications.',
    children: [TileGrid(tiles: glassesTiles(context))],
  );
}

/// The device page: pairs, live info, the hand-off to the official app and the connection.
const List<Widget> devicePage = [HandoffCard(), MyGlassesCard(), DeviceInfoCard(), ConnectionCard()];

List<Widget> glassesTiles(BuildContext context) {
  final hub = AppScope.of(context);
  final d = hub.data;
  final g = hub.glasses;
  final notif = hub.services.notifications;
  final device = d.glasses == null
      ? 'No glasses yet'
      : d.handedOff
      ? 'With the Even app'
      : switch (hub.status) {
          LinkStatus.connected => g?.battery != null ? 'Connected · ${g!.battery}%' : 'Connected',
          LinkStatus.connecting => 'Connecting…',
          _ => 'Not connected',
        };
  return [
    FeatureTile(
      icon: Icons.visibility_outlined,
      title: 'Device',
      status: device,
      active: hub.status == LinkStatus.connected,
      attention: d.glasses == null,
      onTap: () => openSection(context, 'Device', devicePage),
    ),
    FeatureTile(
      icon: Icons.light_mode_outlined,
      title: 'Display',
      status: displayStatus(d.settings),
      onTap: () => openSection(context, 'Display and behaviour', const [DisplayCard()]),
    ),
    FeatureTile(
      icon: Icons.apps,
      title: 'Menu',
      status: menuStatus(d.menu.length + hub.services.menuApps().length),
      onTap: () => openSection(context, 'Menu', const [MenuCard()]),
    ),
    if (d.ui.feature('notifications'))
      FeatureTile(
        icon: Icons.notifications_outlined,
        title: 'Notifications',
        status: notificationsStatus(d.notifications, supported: notif.supported, access: notif.accessGranted),
        active: d.notifications.enabled,
        attention: d.notifications.enabled && notif.supported && !notif.accessGranted,
        onTap: () => openSection(context, 'Notifications', const [NotificationsCard()]),
      ),
    if (d.ui.beta && d.ui.feature('watchface'))
      FeatureTile(
        icon: Icons.watch_outlined,
        title: 'Watchface',
        beta: true,
        status: d.watchface.style == 3 ? 'Date + temperature' : 'Extras beside the clock',
        onTap: () => openSection(context, 'Watchface', const [WatchfaceCard()]),
      ),
    FeatureTile(
      icon: Icons.swap_horiz,
      title: 'Official Even app',
      status: handoffStatus(d),
      active: d.handedOff,
      onTap: () => openSection(context, 'Device', devicePage),
    ),
  ];
}

/// "Use the official Even app": let go of the glasses so the official app can connect, and take
/// them back later. Purely releases / re-acquires this app's own Bluetooth connection.
class HandoffCard extends StatefulWidget {
  const HandoffCard({super.key});
  @override
  State<HandoffCard> createState() => _HandoffCardState();
}

class _HandoffCardState extends State<HandoffCard> {
  bool _busy = false;

  Future<void> _set(bool off) async {
    if (_busy) return;
    final hub = AppScope.of(context);
    setState(() => _busy = true);
    try {
      if (off) {
        await hub.handOff();
      } else {
        await hub.takeBack();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) {
      showMessage(context, off ? 'Glasses released. Open the Even app now.' : 'Taking the glasses back…');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final off = hub.data.handedOff;
    final cs = Theme.of(context).colorScheme;
    return SectionCard(
      icon: Icons.swap_horiz,
      title: 'Use the official Even app',
      subtitle:
          'Lets go of the glasses so the official Even app can use them (its Even AI, updates…) without '
          'uninstalling this app. Your changes wait here and are sent when you take the glasses back.',
      children: [
        if (hub.data.glasses == null) const EmptyState(text: 'Pair your glasses first.', icon: Icons.bluetooth_searching),
        if (hub.data.glasses != null) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Hand the glasses to the Even app'),
            subtitle: Text(off ? 'This app stays away until you take them back' : 'Off: this app keeps the glasses connected'),
            value: off,
            onChanged: _busy ? null : _set,
          ),
          if (off)
            Material(
              color: cs.tertiaryContainer,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: _busy ? null : () => _set(false),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Icon(Icons.swap_horiz, color: cs.onTertiaryContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Handed off to the Even app — tap to take back',
                          style: TextStyle(color: cs.onTertiaryContainer, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (_busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          AdvancedSection(
            title: 'How it works',
            children: [
              Text(
                '1. Turn this on: the app disconnects both lenses and stops reconnecting (also after a restart).\n'
                '2. Open the official Even app; it finds the glasses within a few seconds.\n'
                '3. When you are done, close the Even app (force-stop it, or turn off its Bluetooth access) and tap '
                '"Take back" here. Everything you changed meanwhile is sent to the glasses.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Connecting automatically and restoring on connect (moved here from Settings).
class ConnectionCard extends StatelessWidget {
  const ConnectionCard({super.key});
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    return SectionCard(
      icon: Icons.bluetooth_connected,
      title: 'Connection',
      children: [
        if (connectionTroubled(hub)) ...[
          Text(
            'The last connection attempt did not work. If it keeps happening, send a problem report.',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const Align(alignment: Alignment.centerLeft, child: ReportProblemButton()),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Connect automatically'),
          subtitle: const Text('On start, and reconnect when the link drops'),
          value: hub.data.autoConnect,
          onChanged: (v) {
            hub.data.autoConnect = v;
            hub.save();
            if (v && hub.status == LinkStatus.disconnected) hub.connect();
          },
        ),
        AdvancedSection(
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Restore everything on connect'),
              subtitle: const Text('Settings, weather, menu, tasks, calendar and news go to the glasses every time they connect'),
              value: hub.data.restoreOnConnect,
              onChanged: (v) {
                hub.data.restoreOnConnect = v;
                hub.save();
              },
            ),
          ],
        ),
      ],
    );
  }
}

class MyGlassesCard extends StatelessWidget {
  const MyGlassesCard({super.key});

  Future<String?> _rename(BuildContext context, String current) {
    final c = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Rename'),
          content: TextField(
            controller: c,
            autofocus: true,
            maxLength: 40,
            decoration: InputDecoration(errorText: c.text.trim().isEmpty ? 'Type a name' : null),
            onChanged: (_) => setD(() {}),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: c.text.trim().isEmpty ? null : () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final active = hub.data.glasses?.pairId;
    return SectionCard(
      icon: Icons.visibility_outlined,
      title: 'My glasses',
      subtitle: 'Each pair keeps its own menu, widgets, settings and profiles, restored automatically when it connects.',
      children: [
        if (hub.data.pairs.isEmpty) const EmptyState(text: 'No glasses yet.', icon: Icons.bluetooth_searching),
        for (final p in hub.data.pairs)
          Card(
            color: Theme.of(context).colorScheme.surface,
            child: ListTile(
              leading: const Icon(Icons.visibility),
              title: Row(
                children: [
                  Flexible(child: Text(p.name)),
                  if (p.glasses.pairId == active) const BetaBadge(label: 'In use'),
                ],
              ),
              subtitle: Text(
                p.glasses.pairId == active
                    ? switch (hub.status) {
                        LinkStatus.connected => 'Connected',
                        LinkStatus.connecting => 'Connecting…',
                        _ => 'Not connected',
                      }
                    : (p.lastSeen == null
                          ? 'Saved'
                          : 'Last connected ${DateTime.fromMillisecondsSinceEpoch(p.lastSeen! * 1000).toString().substring(0, 16)}'),
              ),
              trailing: PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'rename') {
                    final n = await _rename(context, p.name);
                    if (n != null) await hub.services.renamePair(p.glasses.pairId, n);
                  } else if (v == 'use') {
                    await hub.disconnect();
                    await hub.services.switchPair(p.glasses);
                    unawaited(hub.connectByUser());
                  } else if (v == 'forget') {
                    if (!context.mounted) return;
                    final yes = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: Text('Forget ${p.name}?'),
                        content: const Text('The app forgets this pair and its settings. The Bluetooth bond stays in Android settings.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Forget')),
                        ],
                      ),
                    );
                    if (yes != true) return;
                    if (p.glasses.pairId == active) {
                      await hub.forgetGlasses();
                    } else {
                      await hub.services.forgetPair(p.glasses.pairId);
                    }
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                  if (p.glasses.pairId != active) const PopupMenuItem(value: 'use', child: Text('Use these glasses')),
                  const PopupMenuItem(value: 'forget', child: Text('Forget')),
                ],
              ),
            ),
          ),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.bluetooth_searching),
              label: const Text('Find glasses'),
              onPressed: () async {
                final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const ScanScreen()));
                if (ok == true) unawaited(hub.connectByUser());
              },
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.assistant_navigation),
              label: const Text('Setup guide'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SetupGuide())),
            ),
          ],
        ),
      ],
    );
  }
}

class DeviceInfoCard extends StatelessWidget {
  const DeviceInfoCard({super.key});
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final g = hub.glasses;
    final p = hub.data.glasses;
    Widget row(String k, String? v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(k)),
          Text(v ?? '—', style: Theme.of(context).textTheme.titleSmall),
        ],
      ),
    );
    String batt(int? b, bool? ch) => b == null ? '—' : '$b%${ch == true ? ' (charging)' : ''}';
    return SectionCard(
      icon: Icons.info_outline,
      title: 'About these glasses',
      trailing: hub.status == LinkStatus.connected
          ? IconButton(onPressed: () => hub.features?.refreshStatus(), icon: const Icon(Icons.refresh))
          : null,
      children: [
        row('Glasses battery', batt(g?.battery, g?.charging)),
        row('Case battery', g?.caseBattery == null ? '—' : '${g!.caseBattery}%'),
        row('Worn', g?.worn == null ? '—' : (g!.worn! ? 'Yes' : 'No')),
        row('Software', g?.rightVersion ?? hub.data.activePair?.firmware),
        if (g?.leftVersion != null && g?.leftVersion != g?.rightVersion) row('Left lens software', g?.leftVersion),
        row('Serial', p?.serial),
        if (hub.data.ui.devMode) ...[
          row('Pair id', p?.pairId),
          row('Right lens', p?.rightId),
          row('Left lens', p?.leftId),
          row('On screen', foregroundLabel(g)),
          row('Screen-off time (read back)', g?.displayTimeout?.toString()),
        ],
      ],
    );
  }
}

class DisplayCard extends StatelessWidget {
  const DisplayCard({super.key});
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final g = hub.data.settings;
    void changed() => hub.changed('settings');
    return SectionCard(
      icon: Icons.light_mode_outlined,
      title: 'Display and behaviour',
      sync: 'settings',
      subtitle: 'Saved for this pair and applied every time it connects.',
      children: [
        SwitchListTile(
          title: const Text('Auto brightness'),
          value: g.autoBrightness ?? true,
          onChanged: (v) {
            g.autoBrightness = v;
            changed();
          },
        ),
        ListTile(
          title: Text('Brightness ${g.brightness ?? 25}'),
          subtitle: Slider(
            value: (g.brightness ?? 25).clamp(st.brightnessMin, st.brightnessMax).toDouble(),
            min: st.brightnessMin.toDouble(),
            max: st.brightnessMax.toDouble(),
            divisions: st.brightnessMax - st.brightnessMin,
            label: '${g.brightness ?? 25}',
            onChanged: g.autoBrightness == true
                ? null
                : (v) {
                    g.brightness = v.round();
                    changed();
                  },
          ),
        ),
        SwitchListTile(
          title: const Text('Silent mode (do not disturb)'),
          value: g.silentMode ?? false,
          onChanged: (v) {
            g.silentMode = v;
            changed();
          },
        ),
        SwitchListTile(
          title: const Text('Turn the display on only when worn'),
          value: g.wearDetection ?? true,
          onChanged: (v) {
            g.wearDetection = v;
            changed();
          },
        ),
        SwitchListTile(
          title: const Text('Look up to show the dashboard'),
          value: g.headUp ?? true,
          onChanged: (v) {
            g.headUp = v;
            changed();
          },
        ),
        AdvancedSection(
          children: [
            ListTile(
              title: const Text('Screen turns off after'),
              trailing: DropdownButton<int>(
                value: const [3, 5, 10, 15, 30, 0].contains(g.displayTimeout) ? g.displayTimeout : 10,
                items: const [
                  DropdownMenuItem(value: 3, child: Text('3 s')),
                  DropdownMenuItem(value: 5, child: Text('5 s')),
                  DropdownMenuItem(value: 10, child: Text('10 s')),
                  DropdownMenuItem(value: 15, child: Text('15 s')),
                  DropdownMenuItem(value: 30, child: Text('30 s')),
                  DropdownMenuItem(value: 0, child: Text('Never')),
                ],
                onChanged: (v) {
                  g.displayTimeout = v;
                  changed();
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: DropdownButtonFormField<int>(
                isExpanded: true,
                initialValue: g.language ?? 0,
                decoration: const InputDecoration(labelText: 'Glasses language'),
                items: [for (final e in st.languages.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) {
                  g.language = v;
                  changed();
                },
              ),
            ),
            if (g.headUp != false)
              ListTile(
                title: Text('Head-up angle ${g.headUpAngle ?? 30}°'),
                subtitle: Slider(
                  value: (g.headUpAngle ?? 30).clamp(st.headUpAngleMin, st.headUpAngleMax).toDouble(),
                  min: st.headUpAngleMin.toDouble(),
                  max: st.headUpAngleMax.toDouble(),
                  divisions: 12,
                  onChanged: (v) {
                    g.headUpAngle = v.round();
                    changed();
                  },
                ),
              ),
            const Divider(),
            SwitchListTile(
              title: const Text('24-hour clock'),
              value: g.time24h ?? false,
              onChanged: (v) {
                g.time24h = v;
                changed();
              },
            ),
            SwitchListTile(
              title: const Text('Temperatures in °C'),
              value: g.celsius ?? true,
              onChanged: (v) {
                g.celsius = v;
                changed();
              },
            ),
            SwitchListTile(
              title: const Text('Miles instead of kilometres'),
              value: g.imperial ?? false,
              onChanged: (v) {
                g.imperial = v;
                changed();
              },
            ),
            if (hub.data.ui.beta) ...[
              const Divider(),
              Row(
                children: [
                  ActionButton(label: 'Restart glasses', icon: Icons.restart_alt, outlined: true, onPressed: () => hub.features!.restartGlasses()),
                  const BetaBadge(),
                ],
              ),
              Text('The connection drops and the app reconnects by itself.', style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ],
    );
  }
}

class MenuCard extends StatelessWidget {
  const MenuCard({super.key});
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final ids = hub.data.menu;
    final apps = hub.services.menuApps();
    final others = menu.builtinMenuApps.keys.where((k) => !ids.contains(k)).toList();
    final total = ids.length + apps.length;
    final err = total < menu.menuMinItems || total > menu.menuMaxItems
        ? 'The menu needs ${menu.menuMinItems} to ${menu.menuMaxItems} apps (has $total).'
        : null;
    return SectionCard(
      icon: Icons.apps,
      title: 'Menu',
      sync: 'menu',
      subtitle: "The apps in your glasses' menu, in order. Changes reach your glasses a moment after you stop editing.",
      children: [
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          onReorderItem: (a, b) {
            ids.insert(b, ids.removeAt(a));
            if (err == null) {
              hub.changed('menu');
            } else {
              hub.save();
            }
          },
          children: [
            for (final id in ids)
              ListTile(
                key: ValueKey('menu-$id'),
                leading: const Icon(Icons.drag_handle),
                title: Text(menu.builtinMenuApps[id] ?? 'App $id'),
                trailing: IconButton(
                  tooltip: total <= menu.menuMinItems ? 'The menu needs at least ${menu.menuMinItems} apps' : 'Remove',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: total <= menu.menuMinItems
                      ? null
                      : () {
                          ids.remove(id);
                          hub.changed('menu');
                        },
                ),
              ),
          ],
        ),
        for (final (name, _) in apps)
          ListTile(dense: true, leading: const Icon(Icons.extension_outlined), title: Text(name), subtitle: const Text('EvenHub app')),
        if (others.isNotEmpty)
          Wrap(
            spacing: 8,
            children: [
              for (final id in others)
                ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: Text(menu.builtinMenuApps[id]!),
                  onPressed: total >= menu.menuMaxItems
                      ? null
                      : () {
                          ids.add(id);
                          hub.changed('menu');
                        },
                ),
            ],
          ),
        if (err != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(err, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
      ],
    );
  }
}

class NotificationsCard extends StatefulWidget {
  const NotificationsCard({super.key});
  @override
  State<NotificationsCard> createState() => _NotificationsCardState();
}

class _NotificationsCardState extends State<NotificationsCard> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from Android's "Notification access" page: re-check.
    if (state == AppLifecycleState.resumed) AppScope.of(context).services.notifications.refreshAccess();
  }

  Future<void> _apps(BuildContext context) async {
    final hub = AppScope.of(context);
    final p = hub.data.notifications;
    final installed = await hub.services.notifications.installedApps();
    final all = <String, String>{for (final (pkg, name) in installed) pkg: name, ...p.appNames};
    if (!context.mounted) return;
    openPage(
      context,
      'Apps on your glasses',
      StatefulBuilder(
        builder: (ctx, setS) {
          final entries = all.entries.toList()..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
          return ListView(
            children: [
              SwitchListTile(
                title: const Text('New apps'),
                subtitle: Text(p.newAppsAllowed ? 'Apps not in the list are shown' : 'Only apps switched on below are shown'),
                value: p.newAppsAllowed,
                onChanged: (v) => setS(() {
                  p.newAppsAllowed = v;
                  hub.save();
                }),
              ),
              const Divider(),
              if (entries.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Apps appear here once they post a notification.')),
              for (final e in entries)
                SwitchListTile(
                  title: Text(e.value),
                  subtitle: hub.data.ui.devMode ? Text(e.key) : null,
                  value: p.allows(e.key),
                  onChanged: (v) => setS(() {
                    p.apps[e.key] = v;
                    hub.save();
                  }),
                ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final svc = hub.services.notifications;
    final p = hub.data.notifications;
    void save() {
      hub.save();
      setState(() {});
    }

    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) => SectionCard(
        icon: Icons.notifications_outlined,
        title: 'Notifications',
        sync: 'notifications',
        subtitle: 'Your phone\'s notifications on your glasses, like the official app. Not yet confirmed on real glasses.',
        children: [
          if (svc.supported && !svc.accessGranted)
            Card(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: ListTile(
                leading: const Icon(Icons.lock_open),
                title: const Text('Allow notification access'),
                subtitle: const Text('Android asks once. Find "G2 Hub" in the list and switch it on.'),
                trailing: FilledButton(onPressed: svc.openAccessSettings, child: const Text('Open')),
              ),
            ),
          SwitchListTile(
            title: const Text('Show phone notifications on the glasses'),
            value: p.enabled,
            onChanged: (v) {
              p.enabled = v;
              save();
            },
          ),
          ListTile(
            title: const Text('Which apps'),
            subtitle: Text(p.newAppsAllowed ? 'All apps, except the ones you switch off' : 'Only the apps you choose'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _apps(context),
          ),
          AdvancedSection(
            children: [
              SwitchListTile(
                title: const Text('Show the message text'),
                subtitle: const Text('Off: only "New notification" and the app name'),
                value: p.showContent,
                onChanged: (v) {
                  p.showContent = v;
                  save();
                },
              ),
              SwitchListTile(
                title: const Text('Quiet hours'),
                subtitle: Text('${p.quietStart} – ${p.quietEnd}'),
                value: p.quietHours,
                onChanged: (v) {
                  p.quietHours = v;
                  save();
                },
              ),
              if (p.quietHours)
                Row(
                  children: [
                    for (final which in ['start', 'end'])
                      Expanded(
                        child: TextButton(
                          onPressed: () async {
                            final cur = (which == 'start' ? p.quietStart : p.quietEnd).split(':');
                            final h = cur.length == 2 ? int.tryParse(cur[0]) : null, m = cur.length == 2 ? int.tryParse(cur[1]) : null;
                            final t = await showTimePicker(
                              context: context,
                              initialTime: TimeOfDay(hour: (h ?? (which == 'start' ? 22 : 7)).clamp(0, 23), minute: (m ?? 0).clamp(0, 59)),
                            );
                            if (t == null) return;
                            final s = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
                            if (which == 'start') {
                              p.quietStart = s;
                            } else {
                              p.quietEnd = s;
                            }
                            save();
                          },
                          child: Text(which == 'start' ? 'From ${p.quietStart}' : 'Until ${p.quietEnd}'),
                        ),
                      ),
                  ],
                ),
              ListTile(
                title: const Text('Show each notification for'),
                trailing: DropdownButton<int>(
                  value: const [3, 5, 10, 15].contains(p.displaySeconds) ? p.displaySeconds : 5,
                  items: const [
                    DropdownMenuItem(value: 3, child: Text('3 s')),
                    DropdownMenuItem(value: 5, child: Text('5 s')),
                    DropdownMenuItem(value: 10, child: Text('10 s')),
                    DropdownMenuItem(value: 15, child: Text('15 s')),
                  ],
                  onChanged: (v) {
                    p.displaySeconds = v ?? 5;
                    hub.changed('notifications');
                  },
                ),
              ),
              SwitchListTile(
                title: const Text('Warn on the glasses when their battery is low'),
                value: p.lowBatteryAlerts,
                onChanged: (v) {
                  p.lowBatteryAlerts = v;
                  save();
                },
              ),
            ],
          ),
          ActionButton(
            label: 'Send a test notification',
            icon: Icons.notification_add_outlined,
            outlined: true,
            onPressed: () => svc.sendTest('Hello', 'Hello from your phone.'),
          ),
          if (svc.recent.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Recent', style: Theme.of(context).textTheme.labelLarge),
            for (final e in svc.recent.take(8))
              ListTile(
                dense: true,
                leading: Icon(e.verdict == FilterVerdict.forward ? Icons.visibility : Icons.visibility_off, size: 18),
                title: Text('${e.n.appName.isEmpty ? e.n.package : e.n.appName}: ${e.n.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(e.verdict == FilterVerdict.forward ? (e.result ?? 'sending…') : _why(e.verdict)),
              ),
          ],
        ],
      ),
    );
  }

  static String _why(FilterVerdict v) => switch (v) {
    FilterVerdict.disabled => 'notifications are off',
    FilterVerdict.ownApp => 'from this app',
    FilterVerdict.ongoing => 'ongoing (music, navigation…)',
    FilterVerdict.groupSummary => 'group summary',
    FilterVerdict.empty => 'no text',
    FilterVerdict.blockedApp => 'app switched off',
    FilterVerdict.quietHours => 'quiet hours',
    FilterVerdict.duplicate => 'repeat',
    FilterVerdict.forward => '',
  };
}

class WatchfaceCard extends StatefulWidget {
  const WatchfaceCard({super.key});
  @override
  State<WatchfaceCard> createState() => _WatchfaceCardState();
}

class _WatchfaceCardState extends State<WatchfaceCard> {
  final _confirm = TextEditingController();
  String? _info;

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final w = hub.data.watchface;
    void save() {
      hub.save();
      setState(() {});
    }

    DropdownButton<String> comp(String value, ValueChanged<String> on) => DropdownButton<String>(
      value: wf.components.containsKey(value) ? value : 'none',
      items: [for (final k in wf.components.keys) DropdownMenuItem(value: k, child: Text(k.replaceAll('_', ' ')))],
      onChanged: (v) => on(v ?? 'none'),
    );
    return SectionCard(
      icon: Icons.watch_outlined,
      title: 'Watchface',
      beta: true,
      subtitle:
          'What sits next to the clock on your dashboard. A bad layout can leave the dashboard blank until a good one is applied, '
          'so applying asks you to type UPLOAD.',
      children: [
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 1, label: Text('Extra on each side')),
            ButtonSegment(value: 3, label: Text('Date + temperature')),
          ],
          selected: {w.style == 3 ? 3 : 1},
          onSelectionChanged: (s) {
            w.style = s.first;
            save();
          },
        ),
        ListTile(
          title: const Text('Clock position'),
          trailing: DropdownButton<String>(
            value: wf.positions.containsKey(w.pos) ? w.pos : 'center',
            items: [for (final k in wf.positions.keys) DropdownMenuItem(value: k, child: Text(k))],
            onChanged: (v) {
              w.pos = v ?? 'center';
              save();
            },
          ),
        ),
        if (w.style == 1) ...[
          ListTile(
            title: const Text('Left of the clock'),
            trailing: comp(w.left, (v) {
              w.left = v;
              save();
            }),
          ),
          ListTile(
            title: const Text('Right of the clock'),
            trailing: comp(w.right, (v) {
              w.right = v;
              save();
            }),
          ),
        ] else ...[
          SwitchListTile(
            title: const Text('Show date'),
            value: w.date,
            onChanged: (v) {
              w.date = v;
              save();
            },
          ),
          SwitchListTile(
            title: const Text('Show temperature'),
            value: w.temp,
            onChanged: (v) {
              w.temp = v;
              save();
            },
          ),
        ],
        if (_info != null) Text(_info!),
        TextField(
          controller: _confirm,
          decoration: const InputDecoration(labelText: 'Type UPLOAD to confirm'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            ActionButton(
              label: 'Check current layout',
              outlined: true,
              icon: Icons.search,
              onPressed: () async {
                final i = await hub.features!.watchfaceInfo();
                if (mounted) setState(() => _info = i == null ? 'No reply from the glasses' : 'Glasses have version ${i['version']} (${i['hash']})');
                return null;
              },
            ),
            if (_confirm.text == 'UPLOAD')
              ActionButton(
                label: 'Apply to glasses',
                icon: Icons.upload,
                onPressed: () async {
                  final (ok, steps) = await hub.services.uploadWatchface();
                  if (!mounted) return null;
                  setState(() => _info = steps.join('; '));
                  _confirm.clear();
                  return null;
                },
              ),
          ],
        ),
      ],
    );
  }
}
