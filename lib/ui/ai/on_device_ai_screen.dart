/// AI models → On this phone: download / delete the on-device chat and speech models, see
/// each model's licence, size and RAM need, pick which features use them, add a custom GGUF,
/// and (Developer mode) see tokens/s of the last run.
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../ai/config/ai_config.dart';
import '../../ai/engines.dart';
import '../../ai/local/device_info.dart';
import '../../ai/local/local_ai.dart';
import '../../ai/local/local_catalog.dart';
import 'ai_scope.dart';

class OnDeviceAiScreen extends StatefulWidget {
  const OnDeviceAiScreen({super.key});
  @override
  State<OnDeviceAiScreen> createState() => _OnDeviceAiScreenState();
}

class _OnDeviceAiScreenState extends State<OnDeviceAiScreen> {
  final Map<String, ModelStatus> _status = {};
  List<LocalModelSpec> _llms = [];
  List<LocalModelSpec> _stts = [];
  int? _ram;
  int? _free;
  int _used = 0;
  StreamSubscription<String>? _sub;
  bool _started = false;

  LocalAi? get _local => AiScope.of(context).local;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final l = _local;
    if (l == null) return;
    _sub = l.store.changes.stream.listen((id) => _refreshOne(id));
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final l = _local!;
    final llms = await l.store.specs(kind: LocalKind.llm);
    final stts = await l.store.specs(kind: LocalKind.stt);
    final ram = await l.deviceRam();
    final dir = await l.store.rootDir;
    final free = await freeDiskBytes(dir.path);
    final used = await l.store.usedBytes();
    if (!mounted) return;
    setState(() {
      _llms = llms;
      _stts = stts;
      _ram = ram;
      _free = free;
      _used = used;
    });
    for (final m in [...llms, ...stts]) {
      await _refreshOne(m.id);
    }
  }

  Future<void> _refreshOne(String id) async {
    final l = _local;
    if (l == null) return;
    final st = await l.store.status(id);
    if (mounted) setState(() => _status[id] = st);
  }

  Future<void> _download(LocalModelSpec m) async {
    final ai = AiScope.of(context);
    final l = ai.local!;
    final need = m.minRamBytes;
    if (_ram != null && need > 0 && _ram! < need) {
      final go = await _confirm('${m.label} needs about ${formatBytes(need)} of RAM; this phone has ${formatBytes(_ram!)}. '
          'It will probably not load. Download anyway?');
      if (!go) return;
    }
    await for (final st in l.store.download(m.id, wifiOnly: ai.settings.wifiOnlyDownloads)) {
      if (!mounted) return;
      setState(() => _status[m.id] = st);
      if (st.state == ModelState.failed) snack(context, st.error ?? 'Download failed', error: true);
      if (st.state == ModelState.ready) {
        snack(context, '${m.label} downloaded and verified (SHA-256)');
        await ai.refreshLocal();
        await _autoUse(m);
      }
    }
    _used = await l.store.usedBytes();
    if (mounted) setState(() {});
  }

  /// First model downloaded: start using it straight away (no extra setup step).
  Future<void> _autoUse(LocalModelSpec m) async {
    final ai = AiScope.of(context);
    if (m.kind == LocalKind.llm && ai.settings.localProfile == null) {
      await ai.useLocalModel(m.id);
    }
    if (m.kind == LocalKind.stt && !ai.settings.sttProfiles.any((p) => p.provider == SttProvider.onDevice)) {
      await ai.update((s) => s.sttProfiles.add(SttProfile(name: 'On this phone', provider: SttProvider.onDevice, model: m.id)));
    }
  }

  Future<void> _delete(LocalModelSpec m) async {
    final ok = await _confirm('Delete ${m.label} (${formatBytes(m.sizeBytes)}) from this phone?');
    if (!ok || !mounted) return;
    final ai = AiScope.of(context);
    await ai.local!.release(m.id);
    await ai.local!.store.delete(m.id);
    await ai.refreshLocal();
    await _load();
  }

  Future<bool> _confirm(String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('OK')),
          ],
        ),
      ) ??
      false;

  // ── using a model ──────────────────────────────────────────────────────────────────────
  Future<void> _useLlm(LocalModelSpec m, {required bool assistant, required bool translation}) async {
    final ai = AiScope.of(context);
    final cloud = ai.settings.llmProfiles.where((p) => p.provider != LlmProvider.local).firstOrNull;
    final p = await ai.useLocalModel(m.id, forAssistant: assistant, forTranslation: translation);
    // Keep a configured cloud model as the fallback, if there is none yet.
    if (cloud != null) {
      await ai.update((s) {
        if (assistant && s.assistantFallbackProfileId == null) s.assistantFallbackProfileId = cloud.id;
        if (translation && s.translationFallbackProfileId == null) s.translationFallbackProfileId = cloud.id;
      });
    }
    if (mounted) snack(context, '${p.name} now uses ${m.label}');
  }

  Future<void> _useStt(LocalModelSpec m) async {
    final ai = AiScope.of(context);
    await ai.update((s) {
      var p = s.sttProfiles.where((x) => x.provider == SttProvider.onDevice).firstOrNull;
      if (p == null) {
        p = SttProfile(name: 'On this phone', provider: SttProvider.onDevice, model: m.id);
        s.sttProfiles.add(p);
      } else {
        p.model = m.id;
      }
      if (s.sttProfileId != p.id) {
        s.sttFallbackProfileId ??= s.sttProfileId; // the previous engine becomes the fallback
        s.sttProfileId = p.id;
      }
    });
    await ai.refreshLocal();
    if (mounted) snack(context, 'Speech recognition now runs on this phone (${m.label})');
  }

  // ── custom models ─────────────────────────────────────────────────────────────────────
  Future<void> _addFile() async {
    final ai = AiScope.of(context);
    final r = await FilePicker.pickFiles(type: FileType.any);
    final path = r.isEmpty ? null : r.first.path;
    if (path == null || !mounted) return;
    snack(context, 'Importing (copying and checksumming)…');
    try {
      final m = await ai.local!.store.importFile(path);
      await ai.refreshLocal();
      if (mounted) snack(context, 'Added ${m.label}');
      await _load();
    } catch (e) {
      if (mounted) snack(context, '$e', error: true);
    }
  }

  Future<void> _addUrl() async {
    final ai = AiScope.of(context);
    final url = TextEditingController();
    final name = TextEditingController();
    final sha = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Add a GGUF model by URL'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: url, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'URL of a .gguf file')),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Name (optional)')),
              TextField(
                controller: sha,
                decoration: const InputDecoration(
                  labelText: 'SHA-256 (optional)',
                  helperText: 'Read automatically for huggingface.co links',
                ),
              ),
              const SizedBox(height: 8),
              const Text('Check the model\'s licence yourself. Instruct/chat models of 0.5–4B parameters in Q4 work best.'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final m = await ai.local!.store.addUrl(url.text, label: name.text, sha256Hex: sha.text);
      await _load();
      if (mounted) unawaited(_download(m));
    } catch (e) {
      if (mounted) snack(context, '$e', error: true);
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final ai = AiScope.of(context);
    final l = ai.local;
    final s = ai.settings;
    if (l == null) {
      return Scaffold(appBar: AppBar(title: const Text('On this phone')), body: const Center(child: Text('Not available in this build')));
    }
    final rec = recommendLlm(_ram);
    final local = s.localProfile;
    final dev = ai.hub.data.ui.devMode;
    final assistantLocal = s.llmById(s.assistantProfileId)?.provider == LlmProvider.local;
    final translationLocal =
        s.translationEngine == TranslationEngineKind.llm && s.llmById(s.translationProfileId)?.provider == LlmProvider.local;
    return Scaffold(
      appBar: AppBar(title: const Text('On this phone')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              'Run Even AI and translation without internet or keys. Models are downloaded once '
              '(never bundled in the app), checked against their published SHA-256, and stay on this phone.\n\n'
              'This phone: ${_ram == null ? 'RAM unknown' : '${formatBytes(_ram!)} RAM'}'
              '${_free == null ? '' : ' · ${formatBytes(_free!)} free storage'} · models use ${formatBytes(_used)}.',
            ),
          ),
          SwitchListTile(
            title: const Text('Download on Wi-Fi only'),
            value: s.wifiOnlyDownloads,
            onChanged: (v) => ai.update((s) => s.wifiOnlyDownloads = v),
          ),

          // ── chat models ──
          SectionTitle(
            'Chat models',
            trailing: PopupMenuButton<String>(
              icon: const Icon(Icons.add),
              tooltip: 'Add a custom GGUF',
              onSelected: (v) => v == 'file' ? _addFile() : _addUrl(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'file', child: Text('Custom GGUF from a file')),
                PopupMenuItem(value: 'url', child: Text('Custom GGUF from a URL')),
              ],
            ),
          ),
          for (final m in _llms)
            _ModelCard(
              spec: m,
              status: _status[m.id],
              recommended: m.id == rec.id,
              ramTooLow: _ram != null && m.minRamBytes > 0 && _ram! < m.minRamBytes,
              inUse: local?.model == m.id,
              loaded: l.loadedModelId == m.id,
              onDownload: () => _download(m),
              onPause: () => l.store.cancel(m.id),
              onDelete: () => _delete(m),
              actions: [
                TextButton(
                  onPressed: () => _useLlm(m, assistant: true, translation: false),
                  child: Text(local?.model == m.id && assistantLocal ? 'Assistant ✓' : 'Use for Assistant'),
                ),
                TextButton(
                  onPressed: () => _useLlm(m, assistant: false, translation: true),
                  child: Text(local?.model == m.id && translationLocal ? 'Translation ✓' : 'Use for Translation'),
                ),
              ],
            ),

          // ── behaviour ──
          if (local != null) ...[
            const SectionTitle('On-device answers'),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Small models answer without the glasses tools (they handle them poorly). Voice shortcuts still '
                'work: "add buy milk to my list", "brightness 30", "silent mode on", "close" run directly.',
              ),
            ),
            ListTile(
              title: const Text('Reply length'),
              subtitle: const Text('Short replies suit the glasses and arrive sooner'),
              trailing: DropdownButton<int>(
                value: const [96, 160, 256, 400].contains(local.maxTokens) ? local.maxTokens : 160,
                items: const [
                  DropdownMenuItem(value: 96, child: Text('Very short')),
                  DropdownMenuItem(value: 160, child: Text('Short')),
                  DropdownMenuItem(value: 256, child: Text('Medium')),
                  DropdownMenuItem(value: 400, child: Text('Long')),
                ],
                onChanged: (v) => ai.update((_) => local.maxTokens = v ?? 160),
              ),
            ),
            SwitchListTile(
              title: const Text('Glasses tools (experimental)'),
              subtitle: Text((catalogById(local.model)?.toolsCapable ?? true)
                  ? 'Let the model change tasks, calendar, brightness… with grammar-constrained tool calls. '
                      'Slower (longer prompt) and less reliable than in the cloud.'
                  : 'Not offered for this model: it is too small to use tools reliably.'),
              value: local.toolsEnabled,
              onChanged: (catalogById(local.model)?.toolsCapable ?? true) ? (v) => ai.update((_) => local.toolsEnabled = v) : null,
            ),
            ListTile(
              title: const Text('Too slow? Use the fallback after'),
              subtitle: const Text('Only when a fallback model is set (AI models → Fallback)'),
              trailing: DropdownButton<int>(
                value: const [0, 10, 25, 60].contains(s.localSlowSec) ? s.localSlowSec : 25,
                items: const [
                  DropdownMenuItem(value: 10, child: Text('10 s')),
                  DropdownMenuItem(value: 25, child: Text('25 s')),
                  DropdownMenuItem(value: 60, child: Text('60 s')),
                  DropdownMenuItem(value: 0, child: Text('Never')),
                ],
                onChanged: (v) => ai.update((s) => s.localSlowSec = v ?? 25),
              ),
            ),
            ListTile(
              title: const Text('Free memory when idle after'),
              subtitle: const Text('The model reloads on the next question (a few seconds)'),
              trailing: DropdownButton<int>(
                value: const [1, 5, 15, 0].contains(s.localIdleUnloadMin) ? s.localIdleUnloadMin : 5,
                items: const [
                  DropdownMenuItem(value: 1, child: Text('1 min')),
                  DropdownMenuItem(value: 5, child: Text('5 min')),
                  DropdownMenuItem(value: 15, child: Text('15 min')),
                  DropdownMenuItem(value: 0, child: Text('Never')),
                ],
                onChanged: (v) => ai.update((s) => s.localIdleUnloadMin = v ?? 5),
              ),
            ),
          ],

          // ── speech ──
          const SectionTitle('Speech recognition (offline)'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Turns the glasses\' microphone audio into text on the phone, so Even AI works fully offline.'),
          ),
          for (final m in _stts)
            _ModelCard(
              spec: m,
              status: _status[m.id],
              recommended: m.id == recommendStt(_ram).id,
              ramTooLow: false,
              inUse: s.sttById(s.sttProfileId)?.provider == SttProvider.onDevice && s.sttById(s.sttProfileId)?.model == m.id,
              loaded: false,
              onDownload: () => _download(m),
              onPause: () => l.store.cancel(m.id),
              onDelete: () => _delete(m),
              actions: [TextButton(onPressed: () => _useStt(m), child: const Text('Use for speech'))],
            ),

          if (dev) ...[
            const SectionTitle('Developer'),
            ListTile(
              title: Text(l.loadedModelId == null ? 'No model loaded' : 'Loaded: ${l.loadedModelId}'),
              subtitle: Text(l.lastRun?.describe() ?? 'No on-device generation yet'),
              trailing: TextButton(onPressed: l.loadedModelId == null ? null : () => l.unload(), child: const Text('Unload')),
            ),
            if (l.lastError != null) ListTile(title: const Text('Last error'), subtitle: Text(l.lastError!)),
          ],
        ],
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.spec,
    required this.status,
    required this.recommended,
    required this.ramTooLow,
    required this.inUse,
    required this.loaded,
    required this.onDownload,
    required this.onPause,
    required this.onDelete,
    required this.actions,
  });
  final LocalModelSpec spec;
  final ModelStatus? status;
  final bool recommended;
  final bool ramTooLow;
  final bool inUse;
  final bool loaded;
  final VoidCallback onDownload;
  final VoidCallback onPause;
  final VoidCallback onDelete;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = status?.state;
    final m = spec;
    final facts = [
      if (m.params.isNotEmpty) m.params,
      formatBytes(m.sizeBytes),
      if (m.minRamBytes > 0) 'needs ${formatBytes(m.minRamBytes)} RAM',
      'licence ${m.licence}',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(m.label, style: Theme.of(context).textTheme.titleMedium)),
                if (recommended) Chip(label: const Text('Recommended'), visualDensity: VisualDensity.compact, backgroundColor: cs.secondaryContainer),
                if (inUse) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.check_circle, color: Colors.green, size: 20)),
              ],
            ),
            Text(facts, style: Theme.of(context).textTheme.bodySmall),
            if (m.summary.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(m.summary)),
            if (m.speed.isNotEmpty) Text('Speed on phones: ${m.speed} (estimate)', style: Theme.of(context).textTheme.bodySmall),
            if (m.licenceUrl.isNotEmpty) SelectableText(m.licenceUrl, style: Theme.of(context).textTheme.bodySmall),
            if (ramTooLow) Text('This phone has less RAM than this model needs.', style: TextStyle(color: cs.error)),
            if (loaded) Text('Loaded in memory', style: TextStyle(color: cs.primary)),
            if (st == ModelState.downloading)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: LinearProgressIndicator(value: (status?.progress ?? 0) > 0 ? status!.progress : null),
              ),
            if (st == ModelState.failed && status?.error != null) Text(status!.error!, style: TextStyle(color: cs.error)),
            Wrap(
              alignment: WrapAlignment.end,
              children: switch (st) {
                ModelState.ready => [
                    ...actions,
                    IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Delete', onPressed: onDelete),
                  ],
                ModelState.downloading => [
                    Text('${((status?.progress ?? 0) * 100).toStringAsFixed(0)}%'),
                    TextButton(onPressed: onPause, child: const Text('Pause')),
                  ],
                _ => [
                    if ((status?.progress ?? 0) > 0) IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Delete partial download', onPressed: onDelete),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.download),
                      label: Text((status?.progress ?? 0) > 0
                          ? 'Resume (${((status?.progress ?? 0) * 100).toStringAsFixed(0)}%)'
                          : 'Download ${formatBytes(m.sizeBytes)}'),
                      onPressed: onDownload,
                    ),
                  ],
              },
            ),
          ],
        ),
      ),
    );
  }
}
