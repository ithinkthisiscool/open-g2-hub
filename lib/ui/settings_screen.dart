/// Settings: appearance, home screen layout, features, connection, AI models, backup, Beta and
/// Developer switches, about.
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../hub/models.dart';
import 'ai/ai_models_screen.dart';
import 'app_scope.dart';
import 'common.dart';
import 'dev_screens.dart';
import 'glasses_screen.dart' show ConnectionCard, HandoffCard;
import 'report_problem_screen.dart';
import 'theme.dart';
import 'tiles.dart';

const _cardNames = {
  'glasses': 'Your glasses',
  'quick': 'Quick controls',
  'sync': 'Sync status',
  'dashboard': 'On your dashboard',
  'apps': 'App shortcuts',
  'log': 'Log (Developer mode)',
};
const _tileNames = {
  'silent': 'Silent mode',
  'auto_brightness': 'Auto brightness',
  'head_up': 'Look up for dashboard',
  'wear_detection': 'Only when worn',
  'notifications': 'Notifications',
  'teleprompter': 'Teleprompter',
  'navigation': 'Navigation',
  'even_app': 'Official Even app (hand off)',
};
const _featureNames = {
  'calendar': 'Calendar',
  'tasks': 'Tasks',
  'news': 'News',
  'weather': 'Weather',
  'profiles': 'Profiles',
  'notifications': 'Notifications',
  'even_ai': 'Even AI',
  'live_translate': 'Live translate',
  'translate': 'Translate text',
  'teleprompter': 'Teleprompter',
  'navigation': 'Navigation',
  'stocks': 'Stocks (Beta)',
  'health': 'Health (Beta)',
  'evenhub': 'EvenHub apps (Beta)',
  'custom_widgets': 'Custom widgets (Beta)',
  'watchface': 'Watchface (Beta)',
};

const appVersion = '0.3.0';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context) => PageList(title: 'Settings', children: [TileGrid(tiles: settingsTiles(context))]);
}

List<Widget> settingsTiles(BuildContext context) {
  final hub = AppScope.of(context);
  final ui = hub.data.ui;
  return [
    FeatureTile(
      icon: Icons.palette_outlined,
      title: 'Appearance',
      status: themeNames[ui.theme] ?? 'Automatic',
      onTap: () => openSection(context, 'Appearance', const [AppearanceCard()]),
    ),
    FeatureTile(
      icon: Icons.dashboard_customize_outlined,
      title: 'Home & features',
      status: '${ui.homeCards.length} cards · ${ui.features.values.where((v) => !v).length} hidden',
      onTap: () => openSection(context, 'Home screen & features', const [HomeLayoutCard(), FeaturesCard()]),
    ),
    FeatureTile(
      icon: Icons.bluetooth_connected,
      title: 'Connection',
      status: hub.data.handedOff ? 'With the Even app' : (hub.data.autoConnect ? 'Connects automatically' : 'Manual'),
      onTap: () => openSection(context, 'Connection', const [ConnectionCard(), HandoffCard()]),
    ),
    FeatureTile(
      icon: Icons.auto_awesome_outlined,
      title: 'AI models',
      status: 'Models, speech, API keys',
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AiModelsScreen())),
    ),
    FeatureTile(
      icon: Icons.shield_outlined,
      title: 'Privacy & backup',
      status: 'Everything stays on this phone',
      onTap: () => openSection(context, 'Privacy & backup', const [PrivacyCard(), BackupCard()]),
    ),
    FeatureTile(
      icon: Icons.science_outlined,
      title: 'Beta & Developer',
      status: ui.devMode ? 'Developer mode on' : (ui.beta ? 'Beta on' : 'Off'),
      active: ui.beta || ui.devMode,
      onTap: () => openSection(context, 'Beta & Developer', const [BetaDevCard()]),
    ),
    FeatureTile(
      icon: Icons.help_outline,
      title: 'Help',
      status: 'Report a problem',
      onTap: () => openSection(context, 'Help', const [HelpCard()]),
    ),
    FeatureTile(
      icon: Icons.info_outline,
      title: 'About',
      status: 'G2 Hub $appVersion',
      onTap: () => openSection(context, 'About', const [AboutCard()]),
    ),
  ];
}

class AppearanceCard extends StatelessWidget {
  const AppearanceCard({super.key});
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final ui = hub.data.ui;
    return SectionCard(
      icon: Icons.palette_outlined,
      title: 'Appearance',
      children: [
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: themeNames.containsKey(ui.theme) ? ui.theme : 'system',
          decoration: const InputDecoration(labelText: 'Theme'),
          items: [for (final e in themeNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) {
            ui.theme = v ?? 'system';
            hub.save();
          },
        ),
        const SizedBox(height: 12),
        Text('Accent colour', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          children: [
            for (final e in accentColors.entries)
              Tooltip(
                message: e.key,
                child: Semantics(
                  button: true,
                  selected: ui.accent == e.value,
                  label: '${e.key} accent',
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () {
                      ui.accent = e.value;
                      hub.save();
                    },
                    // 48 dp tap target around the 36 dp swatch.
                    child: SizedBox.square(
                      dimension: 48,
                      child: Center(
                        child: CircleAvatar(
                          radius: 18,
                          backgroundColor: Color(e.value),
                          child: ui.accent == e.value ? const Icon(Icons.check, size: 18, color: Colors.white) : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (ui.theme == 'green' || ui.theme == 'amber')
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Retro themes use their own colours.', style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }
}

class HomeLayoutCard extends StatelessWidget {
  const HomeLayoutCard({super.key});
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final ui = hub.data.ui;
    return SectionCard(
      icon: Icons.dashboard_customize_outlined,
      title: 'Home screen',
      subtitle: 'Which cards and quick controls Home shows, and in which order.',
      children: [
        _OrderedToggles(
          all: UiPrefs.allHomeCards,
          names: _cardNames,
          selected: ui.homeCards,
          onChanged: (l) {
            ui.homeCards = l;
            hub.save();
          },
        ),
        AdvancedSection(
          title: 'Quick controls',
          children: [
            _OrderedToggles(
              all: UiPrefs.allQuickTiles,
              names: _tileNames,
              selected: ui.quickTiles,
              onChanged: (l) {
                ui.quickTiles = l;
                hub.save();
              },
            ),
          ],
        ),
      ],
    );
  }
}

class FeaturesCard extends StatelessWidget {
  const FeaturesCard({super.key});
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final ui = hub.data.ui;
    return SectionCard(
      icon: Icons.toggle_on_outlined,
      title: 'Features',
      subtitle: 'Hide what you do not use.',
      children: [
        for (final e in _featureNames.entries)
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(e.value),
            value: ui.feature(e.key),
            onChanged: (v) {
              ui.features[e.key] = v;
              hub.save();
            },
          ),
      ],
    );
  }
}

class PrivacyCard extends StatelessWidget {
  const PrivacyCard({super.key});
  @override
  Widget build(BuildContext context) => const SectionCard(
        icon: Icons.shield_outlined,
        title: 'Privacy',
        children: [
          Text(
            'There is no account and no server of ours. Your settings stay on this phone. Weather (Open-Meteo), news '
            '(RSS + Jina Reader), calendar links, stock quotes (Yahoo Finance) and routes (OpenStreetMap) are fetched '
            'directly from those free services. API keys for AI are kept in the phone\'s secure storage and are never '
            'part of a backup.',
          ),
        ],
      );
}

class BackupCard extends StatefulWidget {
  const BackupCard({super.key});
  @override
  State<BackupCard> createState() => _BackupCardState();
}

class _BackupCardState extends State<BackupCard> {
  bool _busy = false;

  Future<void> _guard(Future<void> Function() job) async {
    if (_busy) return; // a double tap opens one file picker, not two
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      if (mounted) showMessage(context, friendlyError(e), ok: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    return SectionCard(
      icon: Icons.save_alt,
      title: 'Backup',
      subtitle: 'All settings, widgets, profiles and pairs in one file. API keys and private calendar links are never included.',
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.upload_file),
              label: const Text('Save backup'),
              onPressed: _busy
                  ? null
                  : () => _guard(() async {
                        final text = hub.services.exportBackup();
                        final path = await FilePicker.saveFile(
                          dialogTitle: 'Save settings backup',
                          fileName: 'g2hub-settings.json',
                          bytes: utf8.encode(text),
                        );
                        if (context.mounted && path != null) showMessage(context, 'Backup saved');
                      }),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.restore),
              label: const Text('Restore'),
              onPressed: _busy
                  ? null
                  : () => _guard(() async {
                        final r = await FilePicker.pickFiles(type: FileType.any);
                        final path = r.isEmpty ? null : r.first.path;
                        if (path == null || !context.mounted) return;
                        final yes = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Restore this backup?'),
                            content: const Text('It replaces your current settings, widgets, profiles and pairs on this phone.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Restore')),
                            ],
                          ),
                        );
                        if (yes != true) return;
                        await hub.services.importBackup(await File(path).readAsString());
                        if (context.mounted) showMessage(context, 'Settings restored');
                      }),
            ),
          ],
        ),
      ],
    );
  }
}

class BetaDevCard extends StatelessWidget {
  const BetaDevCard({super.key});
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final ui = hub.data.ui;
    return SectionCard(
      icon: Icons.science_outlined,
      title: 'Beta and developer',
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Beta features'),
          subtitle: const Text('Stocks, health, widget order, watchface, EvenHub apps, custom widgets, restart — not yet confirmed on real glasses'),
          value: ui.beta,
          onChanged: (v) {
            ui.beta = v;
            hub.save();
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Developer mode'),
          subtitle: const Text('Protocol log, raw frame inspector, sync details and Force resync'),
          value: ui.devMode,
          onChanged: (v) {
            ui.devMode = v;
            hub.save();
          },
        ),
        if (ui.devMode)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.code),
            title: const Text('Developer'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openPage(context, 'Developer', const DeveloperPage()),
          ),
      ],
    );
  }
}

/// Settings → Help: report a problem (a scrubbed diagnostics file the user previews and shares).
class HelpCard extends StatelessWidget {
  const HelpCard({super.key});
  @override
  Widget build(BuildContext context) => SectionCard(
        icon: Icons.help_outline,
        title: 'Help',
        children: [
          const Text(
            'Something not working? Make a problem report: one file with app, phone and connection '
            'details, the log and recent Bluetooth frames, with your personal details removed. You see '
            'the whole file before you share it; nothing is sent by itself.',
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              icon: const Icon(Icons.bug_report_outlined),
              label: const Text('Report a problem'),
              onPressed: () => openReportProblem(context),
            ),
          ),
        ],
      );
}

class AboutCard extends StatelessWidget {
  const AboutCard({super.key});
  @override
  Widget build(BuildContext context) => SectionCard(
        icon: Icons.info_outline,
        title: 'About',
        children: [
          const Text(
            'G2 Hub for phones · $appVersion\nRuns your Even G2 glasses straight from this phone over Bluetooth. '
            'Open source (MIT). Not affiliated with Even Realities; to use the official Even app, hand the glasses '
            'over in Glasses → Device.',
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => showLicensePage(context: context, applicationName: 'G2 Hub', applicationVersion: appVersion),
              child: const Text('Open-source licences'),
            ),
          ),
        ],
      );
}

/// Reorderable list of toggles: [selected] in order, then the rest switched off.
class _OrderedToggles extends StatelessWidget {
  const _OrderedToggles({required this.all, required this.names, required this.selected, required this.onChanged});
  final List<String> all;
  final Map<String, String> names;
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;
  @override
  Widget build(BuildContext context) {
    final rest = all.where((x) => !selected.contains(x)).toList();
    return Column(
      children: [
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          onReorderItem: (a, b) {
            final l = [...selected];
            l.insert(b, l.removeAt(a));
            onChanged(l);
          },
          children: [
            for (final id in selected)
              SwitchListTile(
                key: ValueKey('on-$id'),
                dense: true,
                secondary: const Icon(Icons.drag_handle),
                title: Text(names[id] ?? id),
                value: true,
                onChanged: (_) => onChanged([...selected]..remove(id)),
              ),
          ],
        ),
        for (final id in rest)
          SwitchListTile(
            dense: true,
            secondary: const SizedBox(width: 24),
            title: Text(names[id] ?? id),
            value: false,
            onChanged: (_) => onChanged([...selected, id]),
          ),
      ],
    );
  }
}
