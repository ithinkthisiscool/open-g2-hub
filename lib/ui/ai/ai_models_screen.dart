/// Settings → AI models: model profiles (LLM + speech), which engine each feature uses
/// (Assistant / Translation / Speech, each with an optional fallback), on-device language
/// packs, and export / import of the non-secret settings. Everything applies immediately.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ai/config/ai_config.dart';
import '../../ai/config/ai_store.dart';
import '../../ai/config/secret_store.dart';
import '../../ai/engines.dart';
import '../../ai/providers/anthropic.dart';
import '../../ai/providers/gemini.dart';
import '../../ai/providers/translation.dart';
import '../../ai/local/local_catalog.dart';
import 'ai_scope.dart';
import 'on_device_ai_screen.dart';
import 'profile_editors.dart';

class AiModelsScreen extends StatelessWidget {
  const AiModelsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ai = AiScope.of(context);
    final s = ai.settings;
    final cs = Theme.of(context).colorScheme;

    Widget problem(String? p) => p == null
        ? const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green, size: 18),
                SizedBox(width: 6),
                Text('Ready'),
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: cs.error, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(p, style: TextStyle(color: cs.error)),
                ),
              ],
            ),
          );

    DropdownButton<String?> llmPick(String? value, ValueChanged<String?> on, {bool allowNone = false}) => DropdownButton<String?>(
      value: s.llmById(value) == null ? (allowNone ? null : s.llmProfiles.firstOrNull?.id) : value,
      items: [
        if (allowNone) const DropdownMenuItem(value: null, child: Text('None')),
        for (final p in s.llmProfiles) DropdownMenuItem(value: p.id, child: Text(p.name)),
      ],
      onChanged: on,
    );

    DropdownButton<String?> sttPick(String? value, ValueChanged<String?> on, {bool allowNone = false}) => DropdownButton<String?>(
      value: s.sttById(value) == null ? (allowNone ? null : s.sttProfiles.firstOrNull?.id) : value,
      items: [
        if (allowNone) const DropdownMenuItem(value: null, child: Text('None')),
        for (final p in s.sttProfiles) DropdownMenuItem(value: p.id, child: Text(p.name)),
      ],
      onChanged: on,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI models'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) => v == 'export' ? _export(context) : _import(context),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'export', child: Text('Export settings (no keys)')),
              PopupMenuItem(value: 'import', child: Text('Import settings')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              'The phone calls the providers directly with your own keys. Keys stay in this phone\'s keystore '
              'and are never exported or logged. Each feature can use a different model.',
            ),
          ),
          Card(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: ListTile(
              leading: const Icon(Icons.phone_android),
              title: const Text('On this phone (offline)'),
              subtitle: Text(s.localProfile == null
                  ? 'Run a small AI model and speech recognition on the phone: no keys, no internet'
                  : 'Using ${catalogById(s.localProfile!.model)?.label ?? 'a custom model'} · manage models'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OnDeviceAiScreen())),
            ),
          ),
          // ── features ──
          const SectionTitle('Assistant (Even AI)'),
          ListTile(title: const Text('Model'), trailing: llmPick(s.assistantProfileId, (v) => ai.update((s) => s.assistantProfileId = v))),
          ListTile(
            title: const Text('Fallback'),
            subtitle: const Text('Used if the main model fails or is not set up'),
            trailing: llmPick(s.assistantFallbackProfileId, (v) => ai.update((s) => s.assistantFallbackProfileId = v), allowNone: true),
          ),
          problem(ai.assistantProblem),

          const SectionTitle('Translation'),
          ListTile(
            title: const Text('Engine'),
            trailing: SegmentedButton<TranslationEngineKind>(
              segments: const [
                ButtonSegment(value: TranslationEngineKind.llm, label: Text('AI model')),
                ButtonSegment(value: TranslationEngineKind.mlkit, label: Text('On-device')),
              ],
              selected: {s.translationEngine},
              onSelectionChanged: (v) => ai.update((s) => s.translationEngine = v.first),
            ),
          ),
          ListTile(
            title: Text(s.translationEngine == TranslationEngineKind.mlkit ? 'Cloud model (fallback)' : 'Model'),
            trailing: llmPick(s.translationProfileId, (v) => ai.update((s) => s.translationProfileId = v)),
          ),
          if (s.translationEngine == TranslationEngineKind.llm)
            ListTile(
              title: const Text('Fallback'),
              subtitle: const Text('Used if the model fails, is not set up, or (on this phone) is too slow'),
              trailing: llmPick(s.translationFallbackProfileId, (v) => ai.update((s) => s.translationFallbackProfileId = v), allowNone: true),
            ),
          if (s.translationEngine == TranslationEngineKind.mlkit) ...[
            SwitchListTile(
              title: const Text('Fall back to the cloud model'),
              subtitle: const Text('When a language pack is missing or on-device translation fails'),
              value: s.translationCloudFallback,
              onChanged: (v) => ai.update((s) => s.translationCloudFallback = v),
            ),
            ListTile(
              leading: const Icon(Icons.download_for_offline_outlined),
              title: const Text('On-device language packs'),
              subtitle: const Text('Google ML Kit, about 30 MB per language, downloaded on demand'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LanguagePacksScreen())),
            ),
          ],
          problem(ai.translationProblem),

          const SectionTitle('Speech to text'),
          ListTile(title: const Text('Engine'), trailing: sttPick(s.sttProfileId, (v) => ai.update((s) => s.sttProfileId = v))),
          ListTile(
            title: const Text('Fallback'),
            trailing: sttPick(s.sttFallbackProfileId, (v) => ai.update((s) => s.sttFallbackProfileId = v), allowNone: true),
          ),
          problem(ai.speechProblem),

          // ── profiles ──
          SectionTitle(
            'Model profiles',
            trailing: TextButton.icon(icon: const Icon(Icons.add), label: const Text('Add'), onPressed: () => _addLlm(context)),
          ),
          for (final p in s.llmProfiles)
            ListTile(
              leading: Icon(switch (p.provider) {
                LlmProvider.anthropic => Icons.auto_awesome,
                LlmProvider.gemini => Icons.diamond_outlined,
                LlmProvider.openai => Icons.hub_outlined,
                LlmProvider.local => Icons.phone_android,
              }),
              title: Text(p.name),
              subtitle: Text(
                '${llmProviderLabels[p.provider]} · ${p.provider == LlmProvider.local ? (catalogById(p.model)?.label ?? 'custom model') : p.model}'
                '${p.provider != LlmProvider.openai && !ai.hasKey(llmKeyName(p.id)) ? ' · no key' : ''}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LlmProfileScreen(profileId: p.id))),
            ),
          SectionTitle(
            'Speech profiles',
            trailing: TextButton.icon(icon: const Icon(Icons.add), label: const Text('Add'), onPressed: () => _addStt(context)),
          ),
          for (final p in s.sttProfiles)
            ListTile(
              leading: const Icon(Icons.mic_none),
              title: Text(p.name),
              subtitle: Text(
                '${sttProviderLabels[p.provider]}${p.model.isEmpty ? '' : ' · ${p.model}'}'
                '${p.provider == SttProvider.deepgram && !ai.hasKey(sttKeyName(p.id)) ? ' · no key' : ''}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SttProfileScreen(profileId: p.id))),
            ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Default Claude model: Haiku 5.5 at low effort — the fastest current Claude model, so answers '
              'reach the glasses quickly. Pick Sonnet 5.5 or Opus 5.5 for harder questions.',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addLlm(BuildContext context) async {
    final ai = AiScope.of(context);
    final kind = await showDialog<LlmProvider>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Add a model'),
        children: [
          for (final e in llmProviderLabels.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, e.key),
              child: Padding(padding: const EdgeInsets.all(8), child: Text(e.value)),
            ),
        ],
      ),
    );
    if (kind == null) return;
    if (kind == LlmProvider.local) {
      if (context.mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => const OnDeviceAiScreen()));
      return;
    }
    final p = LlmProfile(
      name: llmProviderLabels[kind]!.split(' ').first,
      provider: kind,
      model: switch (kind) {
        LlmProvider.anthropic => defaultClaudeModel,
        LlmProvider.gemini => defaultGeminiModel,
        LlmProvider.openai || LlmProvider.local => '',
      },
      effort: kind == LlmProvider.anthropic ? 'low' : null,
    );
    await ai.update((s) => s.llmProfiles.add(p));
    if (context.mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => LlmProfileScreen(profileId: p.id)));
  }

  Future<void> _addStt(BuildContext context) async {
    final ai = AiScope.of(context);
    final kind = await showDialog<SttProvider>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Add speech-to-text'),
        children: [
          for (final e in sttProviderLabels.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, e.key),
              child: Padding(padding: const EdgeInsets.all(8), child: Text(e.value)),
            ),
        ],
      ),
    );
    if (kind == null) return;
    final p = SttProfile(name: sttProviderLabels[kind]!.split(' (').first, provider: kind, model: kind == SttProvider.whisper ? 'whisper-1' : '');
    await ai.update((s) => s.sttProfiles.add(p));
    if (context.mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => SttProfileScreen(profileId: p.id)));
  }

  Future<void> _export(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: exportSettings(AiScope.of(context).settings)));
    if (context.mounted) snack(context, 'AI settings copied to the clipboard (API keys are not included)');
  }

  Future<void> _import(BuildContext context) async {
    final ai = AiScope.of(context);
    final c = TextEditingController(text: (await Clipboard.getData('text/plain'))?.text ?? '');
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Import AI settings'),
        content: TextField(
          controller: c,
          maxLines: 8,
          decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Paste exported settings'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Import')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ai.replaceSettings(importSettings(c.text));
      await ai.refreshKeys();
      if (context.mounted) snack(context, 'Imported. Keys already on this phone are kept; add any missing ones.');
    } catch (e) {
      if (context.mounted) snack(context, 'Not a G2 Hub AI settings export', error: true);
    }
  }
}

/// ML Kit language packs: download / delete, Wi-Fi only by default.
class LanguagePacksScreen extends StatefulWidget {
  const LanguagePacksScreen({super.key});
  @override
  State<LanguagePacksScreen> createState() => _LanguagePacksScreenState();
}

class _LanguagePacksScreenState extends State<LanguagePacksScreen> {
  final Map<String, ModelStatus> _status = {};
  List<LocalModel> _models = [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_models.isEmpty) _load();
  }

  Future<void> _load() async {
    final ml = AiScope.of(context).engines.mlKit;
    final models = await ml.available();
    models.sort((a, b) => a.label.compareTo(b.label));
    final pinned = translateLanguages.keys.toSet();
    models.sort((a, b) => (pinned.contains(a.languages!.first) ? 0 : 1).compareTo(pinned.contains(b.languages!.first) ? 0 : 1));
    if (!mounted) return;
    setState(() => _models = models);
    for (final m in models) {
      try {
        final st = await ml.status(m.id);
        if (mounted) setState(() => _status[m.id] = st);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final ai = AiScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('On-device language packs')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Download on Wi-Fi only'),
            value: ai.settings.wifiOnlyDownloads,
            onChanged: (v) => ai.update((s) => s.wifiOnlyDownloads = v),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Both languages of a pair must be downloaded. English is always available.'),
          ),
          for (final m in _models)
            ListTile(
              title: Text(m.label),
              subtitle: Text(switch (_status[m.id]?.state) {
                ModelState.ready => 'Downloaded',
                ModelState.downloading => 'Downloading…',
                ModelState.failed => _status[m.id]?.error ?? 'Failed',
                _ => 'About 30 MB',
              }),
              trailing: switch (_status[m.id]?.state) {
                ModelState.ready => IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await ai.engines.mlKit.delete(m.id);
                    setState(() => _status[m.id] = const ModelStatus(ModelState.notDownloaded));
                  },
                ),
                ModelState.downloading => const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                _ => IconButton(
                  icon: const Icon(Icons.download),
                  onPressed: () async {
                    await for (final st in ai.engines.mlKit.download(m.id, wifiOnly: ai.settings.wifiOnlyDownloads)) {
                      if (mounted) setState(() => _status[m.id] = st);
                    }
                  },
                ),
              },
            ),
        ],
      ),
    );
  }
}
