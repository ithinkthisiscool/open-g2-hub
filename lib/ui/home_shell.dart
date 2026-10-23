import 'package:flutter/material.dart';

import '../hub/glasses_session.dart';
import '../hub/hub_controller.dart';
import '../protocol/sids.dart';
import 'app_scope.dart';
import 'apps_screen.dart';
import 'common.dart';
import 'dashboard_screen.dart';
import 'dev_screens.dart';
import 'glasses_screen.dart';
import 'report_problem_screen.dart';
import 'settings_screen.dart';
import 'tiles.dart';

/// Home / Dashboard / Apps / Glasses / Settings, like the redesigned PC hub.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.initialTab = 0});
  final int initialTab;
  @override
  State<HomeShell> createState() => HomeShellState();
}

class HomeShellState extends State<HomeShell> {
  late int _tab = widget.initialTab;
  void go(int tab) => setState(() => _tab = tab);

  @override
  Widget build(BuildContext context) {
    const pages = [HomeScreen(), DashboardScreen(), AppsScreen(), GlassesScreen(), SettingsScreen()];
    return Scaffold(
      body: SafeArea(child: pages[_tab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: go,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.grid_view_outlined), selectedIcon: Icon(Icons.grid_view), label: 'Dashboard'),
          NavigationDestination(icon: Icon(Icons.apps_outlined), selectedIcon: Icon(Icons.apps), label: 'Apps'),
          NavigationDestination(icon: Icon(Icons.visibility_outlined), selectedIcon: Icon(Icons.visibility), label: 'Glasses'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

void goTab(BuildContext context, int tab) => context.findAncestorStateOfType<HomeShellState>()?.go(tab);

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final ui = hub.data.ui;
    final cards = <Widget>[];
    for (final c in ui.homeCards) {
      switch (c) {
        case 'glasses':
          cards.add(const _GlassesHero());
        case 'quick':
          cards.add(const QuickControls());
        case 'sync':
          cards.add(const _SyncCard());
        case 'dashboard':
          final t = dashboardTiles(context);
          if (t.isNotEmpty) cards.addAll([const TileHeading('On your dashboard'), TileGrid(tiles: t)]);
        case 'apps':
          final t = appTiles(context);
          if (t.isNotEmpty) cards.addAll([const TileHeading('Apps'), TileGrid(tiles: t)]);
        case 'log':
          if (ui.devMode) {
            cards.add(
              const SectionCard(
                icon: Icons.terminal,
                title: 'Log',
                children: [SizedBox(height: 280, child: LogView())],
              ),
            );
          }
      }
    }
    if (cards.isEmpty) cards.add(const EmptyState(text: 'Home is empty. Choose its cards in Settings → Home & features.', icon: Icons.dashboard_customize_outlined));
    return PageList(title: 'Home', children: cards);
  }
}

class _GlassesHero extends StatelessWidget {
  const _GlassesHero();
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final g = hub.glasses;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final pair = hub.data.activePair;
    if (hub.data.glasses == null) {
      return SectionCard(
        icon: Icons.visibility_outlined,
        title: 'Your glasses',
        subtitle: 'No glasses yet. Find them to get started.',
        children: [
          FilledButton.icon(
            onPressed: () => openSection(context, 'Device', devicePage),
            icon: const Icon(Icons.bluetooth_searching),
            label: const Text('Find my glasses'),
          ),
        ],
      );
    }
    final handedOff = hub.data.handedOff && hub.status != LinkStatus.connected;
    final state = handedOff
        ? 'With the official Even app'
        : switch (hub.status) {
            LinkStatus.connected => g?.worn == true ? 'Connected · Worn' : 'Connected',
            LinkStatus.connecting => 'Connecting…',
            _ => 'Not connected',
          };
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.visibility, size: 56, color: cs.primary),
            Text('Your glasses', style: t.labelMedium),
            Text(pair?.name ?? 'Even G2', style: t.headlineSmall),
            const SizedBox(height: 6),
            Chip(
              avatar: Icon(Icons.circle, size: 10, color: hub.status == LinkStatus.connected ? Colors.green : cs.outline),
              label: Text(state),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _Meter('Glasses', g?.battery, g?.charging == true)),
                const SizedBox(width: 12),
                Expanded(child: _Meter('Case', g?.caseBattery, false)),
              ],
            ),
            const SizedBox(height: 8),
            Text('Software ${g?.rightVersion ?? pair?.firmware ?? '—'}', style: t.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (handedOff)
                  FilledButton.icon(onPressed: hub.takeBack, icon: const Icon(Icons.swap_horiz), label: const Text('Take back'))
                else if (hub.status == LinkStatus.connected)
                  OutlinedButton(onPressed: () => hub.features?.refreshStatus(), child: const Text('Refresh'))
                else if (hub.status != LinkStatus.connecting)
                  FilledButton(onPressed: hub.connectByUser, child: const Text('Connect')),
                OutlinedButton(onPressed: () => openSection(context, 'Device', devicePage), child: const Text('Manage glasses')),
              ],
            ),
            if (!handedOff && connectionTroubled(hub)) const ReportProblemButton(label: 'Connection trouble? Report a problem'),
          ],
        ),
      ),
    );
  }
}

class _Meter extends StatelessWidget {
  const _Meter(this.label, this.value, this.charging);
  final String label;
  final int? value;
  final bool charging;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label, style: t.labelLarge, overflow: TextOverflow.ellipsis),
              ),
              Text(value == null ? '—' : '$value%${charging ? '⚡' : ''}', style: t.titleMedium),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: (value ?? 0) / 100,
            color: (value ?? 100) <= 20 ? Colors.orange : Colors.green,
            borderRadius: BorderRadius.circular(4),
          ),
        ],
      ),
    );
  }
}

/// Toggle tiles that change the glasses right away (and are remembered for this pair).
class QuickControls extends StatelessWidget {
  const QuickControls({super.key});
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final s = hub.data.settings;
    final tiles = <Widget>[];
    for (final id in hub.data.ui.quickTiles) {
      switch (id) {
        case 'silent':
          tiles.add(
            _Tile(Icons.dark_mode_outlined, 'Silent', s.silentMode == true, () {
              s.silentMode = !(s.silentMode ?? false);
              hub.changed('settings');
            }),
          );
        case 'auto_brightness':
          tiles.add(
            _Tile(Icons.brightness_auto, 'Auto brightness', s.autoBrightness == true, () {
              s.autoBrightness = !(s.autoBrightness ?? true);
              hub.changed('settings');
            }),
          );
        case 'head_up':
          tiles.add(
            _Tile(Icons.north, 'Look up for dashboard', s.headUp == true, () {
              s.headUp = !(s.headUp ?? true);
              hub.changed('settings');
            }),
          );
        case 'wear_detection':
          tiles.add(
            _Tile(Icons.face, 'Only when worn', s.wearDetection == true, () {
              s.wearDetection = !(s.wearDetection ?? true);
              hub.changed('settings');
            }),
          );
        case 'notifications':
          final n = hub.data.notifications;
          tiles.add(
            _Tile(Icons.notifications_outlined, 'Notifications', n.enabled, () {
              n.enabled = !n.enabled;
              hub.save();
              final svc = hub.services.notifications;
              if (n.enabled && svc.supported && !svc.accessGranted) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(
                    content: const Text('Allow notification access so G2 Hub can forward them: find "G2 Hub" in the list and switch it on.'),
                    duration: const Duration(seconds: 8),
                    action: SnackBarAction(label: 'Open', onPressed: svc.openAccessSettings),
                  ));
              }
            }),
          );
        case 'even_app':
          if (hub.data.glasses != null) {
            tiles.add(
              _Tile(Icons.swap_horiz, 'Even app', hub.data.handedOff, () async {
                final off = !hub.data.handedOff;
                if (off) {
                  await hub.handOff();
                } else {
                  await hub.takeBack();
                }
                if (context.mounted) showMessage(context, off ? 'Glasses released for the Even app. Tap again to take them back.' : 'Taking the glasses back…');
              }, onLabel: 'Handed off', offLabel: 'This app'),
            );
          }
        case 'teleprompter':
          tiles.add(_Tile(Icons.subject, 'Teleprompter', hub.features?.currentApp == 'teleprompter', () => openApp(context, 'teleprompter')));
        case 'navigation':
          tiles.add(_Tile(Icons.navigation_outlined, 'Navigation', hub.features?.currentApp == 'navigation', () => openApp(context, 'navigation')));
      }
    }
    return SectionCard(
      icon: Icons.tune,
      title: 'Quick controls',
      sync: 'settings',
      subtitle: 'Change these on your glasses right away. They are remembered for this pair.',
      children: [
        LayoutBuilder(
          builder: (context, c) => GridView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: tileColumns(c.maxWidth),
              mainAxisExtent: 64 * (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 2.0),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            children: tiles,
          ),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.icon, this.label, this.on, this.onTap, {this.onLabel = 'On', this.offLabel = 'Off'});
  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;
  final String onLabel, offLabel;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // One switch for screen readers: "Silent, on" instead of an icon and two loose texts.
    return Semantics(
      button: true,
      toggled: on,
      label: label,
      value: on ? onLabel : offLabel,
      onTap: onTap,
      excludeSemantics: true,
      child: _tile(cs),
    );
  }

  Widget _tile(ColorScheme cs) {
    return Material(
      color: on ? cs.primary : cs.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(icon, color: on ? cs.onPrimary : cs.onSurface),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: on ? cs.onPrimary : cs.onSurface, fontWeight: FontWeight.w600),
                    ),
                    Text(on ? onLabel : offLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: on ? cs.onPrimary : cs.onSurfaceVariant, fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SyncCard extends StatelessWidget {
  const _SyncCard();
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final sync = hub.services.sync;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final pending = sync.sections.where((s) => sync.isDirty(s.key)).length;
        final text = !sync.connected
            ? (pending == 0
                  ? 'Everything is saved. It goes to your glasses when they connect.'
                  : '$pending change(s) will sync when your glasses connect.')
            : sync.busy || pending > 0
            ? 'Syncing your changes…'
            : 'Your glasses are up to date.';
        return SectionCard(
          icon: sync.connected && pending == 0 ? Icons.cloud_done_outlined : Icons.cloud_sync_outlined,
          title: 'Sync',
          subtitle: '$text Weather, news, calendar and stocks refresh by themselves.',
          children: const [],
        );
      },
    );
  }
}

/// The current foreground app as a short label (Developer details).
String foregroundLabel(GlassesStatus? g) => g?.foregroundApp == null ? '—' : (g!.foregroundApp == 0 ? 'Dashboard' : sidName(g.foregroundApp!));
