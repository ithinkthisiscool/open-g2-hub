import 'package:flutter/material.dart';

import '../hub/hub_controller.dart';
import 'ai/even_ai_screen.dart';
import 'ai/live_translate_screen.dart';
import 'app_pages.dart';
import 'app_scope.dart';
import 'common.dart';
import 'tiles.dart';

/// Full-screen apps on the glasses (the hub's Apps page).
class AppEntry {
  const AppEntry(this.id, this.title, this.subtitle, this.icon, {this.beta = false, this.feature});
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final bool beta;

  /// Settings → Features key that hides it (defaults to [id]).
  final String? feature;
}

const List<AppEntry> appEntries = [
  AppEntry('even_ai', 'Even AI', 'Ask anything with "Hey Even"', Icons.auto_awesome_outlined),
  AppEntry('live_translate', 'Live translate', 'Conversations, translated on your lenses', Icons.record_voice_over_outlined),
  AppEntry('translate', 'Translate text', 'Show two lines on the Translate screen', Icons.translate),
  AppEntry('teleprompter', 'Teleprompter', 'Your script, hands-free', Icons.subject),
  AppEntry('navigation', 'Navigation', 'Turn-by-turn directions', Icons.navigation_outlined),
  AppEntry('evenhub', 'EvenHub apps', 'Install third-party apps', Icons.extension_outlined, beta: true),
  AppEntry('custom_widgets', 'Custom widgets', 'Graphs, numbers and charts', Icons.show_chart, beta: true),
];

List<AppEntry> visibleApps(HubController hub) => [
  for (final a in appEntries)
    if (hub.data.ui.feature(a.feature ?? a.id) && (!a.beta || hub.data.ui.beta)) a,
];

void openApp(BuildContext context, String id) {
  final a = appEntries.firstWhere((x) => x.id == id);
  final Widget page = switch (id) {
    'even_ai' => const EvenAiScreen(),
    'live_translate' => const LiveTranslateScreen(),
    'translate' => const TranslateTextPage(),
    'teleprompter' => const TeleprompterPage(),
    'navigation' => const NavigationPage(),
    'evenhub' => const EvenHubPage(),
    _ => const CustomWidgetsPage(),
  };
  openPage(context, a.title, page);
}

class AppsScreen extends StatelessWidget {
  const AppsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final tiles = appTiles(context);
    return PageList(
      title: 'Apps',
      subtitle: 'Full-screen apps on your glasses.',
      children: [
        if (tiles.isEmpty) const EmptyState(text: 'All apps are hidden. Turn them on in Settings → Home screen & features.'),
        TileGrid(tiles: tiles),
        if (!hub.data.ui.beta)
          Text('More apps (EvenHub, custom widgets) appear with Beta features in Settings.', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// The short status of an app tile.
String appStatus(HubController hub, AppEntry a) {
  if (hub.features?.currentApp == a.id) return 'Running on your glasses';
  return switch (a.id) {
    'even_ai' => 'Say "Hey Even"',
    'live_translate' => 'Speech, translated',
    'translate' => 'Two lines of text',
    'teleprompter' => hub.data.teleprompterScript.trim().isEmpty ? 'No script yet' : '${hub.data.teleprompter.scripts.length} saved · script ready',
    'navigation' => hub.services.nav.route != null ? 'Navigating to ${hub.services.nav.route!.to}' : '${hub.data.nav.favorites.length} favorite(s)',
    'evenhub' => '${hub.services.registry?.list().length ?? 0} installed',
    'custom_widgets' => hub.data.customWidgets.isEmpty ? 'None yet' : '${hub.data.customWidgets.length} widget(s)',
    _ => a.subtitle,
  };
}

List<Widget> appTiles(BuildContext context) {
  final hub = AppScope.of(context);
  return [
    for (final a in visibleApps(hub))
      FeatureTile(
        icon: a.icon,
        title: a.title,
        beta: a.beta,
        active: hub.features?.currentApp == a.id || (a.id == 'navigation' && hub.services.nav.route != null),
        status: appStatus(hub, a),
        onTap: () => openApp(context, a.id),
      ),
  ];
}
