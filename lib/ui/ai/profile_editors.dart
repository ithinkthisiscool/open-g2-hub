/// Editors for one LLM profile and one speech-to-text profile. Every change is applied and
/// saved immediately; API keys go straight to the keystore and are only ever shown masked.
library;

import 'package:flutter/material.dart';

import '../../ai/config/ai_config.dart';
import '../../ai/config/secret_store.dart';
import '../../ai/providers/anthropic.dart';
import '../../ai/providers/gemini.dart';
import '../../ai/providers/llm.dart';
import '../../ai/providers/openai_compat.dart';
import '../../ai/local/local_catalog.dart';
import 'ai_scope.dart';
import 'on_device_ai_screen.dart';

const Map<LlmProvider, String> llmProviderLabels = {
  LlmProvider.anthropic: 'Anthropic Claude',
  LlmProvider.openai: 'OpenAI-compatible',
  LlmProvider.gemini: 'Google Gemini',
  LlmProvider.local: 'On this phone (offline)',
};

const Map<SttProvider, String> sttProviderLabels = {
  SttProvider.deepgram: 'Deepgram',
  SttProvider.whisper: 'Whisper (OpenAI-compatible)',
  SttProvider.onDevice: 'On this phone (offline Whisper)',
};

/// Masked key row: shows "sk-ant…1234", lets the user replace or remove the key.
class ApiKeyField extends StatefulWidget {
  const ApiKeyField({super.key, required this.keyName, this.label = 'API key', this.optional = false, this.helper});
  final String keyName;
  final String label;
  final bool optional;
  final String? helper;
  @override
  State<ApiKeyField> createState() => _ApiKeyFieldState();
}

class _ApiKeyFieldState extends State<ApiKeyField> {
  String? _masked;
  bool _has = false;
  bool _editing = false;
  final _c = TextEditingController();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    String? v;
    var failed = false;
    try {
      v = await AiScope.of(context).secrets.read(widget.keyName);
    } catch (_) {
      failed = true; // keystore unavailable: let the user enter the key again
    }
    if (!mounted) return;
    setState(() {
      _has = v != null && v.isNotEmpty;
      _masked = failed ? 'could not be read from the keystore: enter it again' : maskKey(v);
    });
  }

  Future<void> _save() async {
    final v = cleanKey(_c.text) ?? '';
    final ai = AiScope.of(context);
    try {
      await ai.secrets.write(widget.keyName, v);
    } catch (_) {
      // Never show the platform error: it could quote the value.
      if (mounted) snack(context, 'Could not save the key in the phone keystore. Try again.', error: true);
      return;
    }
    _c.clear();
    _editing = false;
    await _load();
    await ai.refreshKeys();
    if (mounted) snack(context, v.isEmpty ? 'Key removed' : 'Key saved on this phone (keystore)');
  }

  @override
  Widget build(BuildContext context) {
    if (_editing || !_has) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: TextField(
          controller: _c,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: '${widget.label}${widget.optional ? ' (optional)' : ''}',
            helperText: widget.helper ?? 'Stored only on this phone, in the Android Keystore / iOS Keychain',
            border: const OutlineInputBorder(),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _obscure = !_obscure)),
                IconButton(icon: const Icon(Icons.check), tooltip: 'Save key', onPressed: _save),
              ],
            ),
          ),
          onSubmitted: (_) => _save(),
        ),
      );
    }
    return ListTile(
      leading: const Icon(Icons.key),
      title: Text(widget.label),
      subtitle: Text(_masked ?? ''),
      trailing: Wrap(
        children: [
          TextButton(onPressed: () => setState(() => _editing = true), child: const Text('Replace')),
          TextButton(
            onPressed: () async {
              _c.clear();
              await _save();
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}

/// "Test connection" with an inline result.
class TestButton extends StatefulWidget {
  const TestButton({super.key, required this.run});
  final Future<String> Function() run;
  @override
  State<TestButton> createState() => _TestButtonState();
}

class _TestButtonState extends State<TestButton> {
  bool _busy = false;
  String? _result;
  bool _ok = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OutlinedButton.icon(
            icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.wifi_tethering),
            label: const Text('Test connection'),
            onPressed: _busy
                ? null
                : () async {
                    setState(() => _busy = true);
                    try {
                      final r = await widget.run();
                      _ok = true;
                      _result = r;
                    } catch (e) {
                      _ok = false;
                      _result = '$e';
                    }
                    if (mounted) setState(() => _busy = false);
                  },
          ),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(_ok ? Icons.check_circle : Icons.error, size: 18, color: _ok ? Colors.green : cs.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_result!, style: TextStyle(color: _ok ? null : cs.error)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Text field that saves on every change (debounced by the store write).
class LiveTextField extends StatefulWidget {
  const LiveTextField({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
    this.maxLines = 1,
    this.helper,
    this.hint,
    this.keyboard,
  });
  final String value;
  final ValueChanged<String> onChanged;
  final String label;
  final int maxLines;
  final String? helper;
  final String? hint;
  final TextInputType? keyboard;
  @override
  State<LiveTextField> createState() => _LiveTextFieldState();
}

class _LiveTextFieldState extends State<LiveTextField> {
  late final _c = TextEditingController(text: widget.value);
  @override
  void didUpdateWidget(covariant LiveTextField old) {
    super.didUpdateWidget(old);
    if (widget.value != _c.text && widget.value != old.value) _c.text = widget.value;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: TextField(
      controller: _c,
      maxLines: widget.maxLines,
      minLines: 1,
      keyboardType: widget.keyboard,
      autocorrect: widget.keyboard != TextInputType.url,
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.helper,
        hintText: widget.hint,
        helperMaxLines: 3,
        border: const OutlineInputBorder(),
      ),
      onChanged: widget.onChanged,
    ),
  );
}

// ── LLM profile ──────────────────────────────────────────────────────────────────────────
class LlmProfileScreen extends StatelessWidget {
  const LlmProfileScreen({super.key, required this.profileId});
  final String profileId;

  @override
  Widget build(BuildContext context) {
    final ai = AiScope.of(context);
    final p = ai.settings.llmById(profileId);
    if (p == null) return const Scaffold(body: Center(child: Text('Profile deleted')));
    if (p.provider == LlmProvider.local) return const OnDeviceAiScreen();
    void set(void Function(LlmProfile p) f) => ai.update((_) => f(p));
    final isClaude = p.provider == LlmProvider.anthropic;
    final isOpenAi = p.provider == LlmProvider.openai;
    return Scaffold(
      appBar: AppBar(
        title: Text(p.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete profile',
            onPressed: ai.settings.llmProfiles.length <= 1
                ? null
                : () async {
                    try {
                      await ai.secrets.write(llmKeyName(p.id), null);
                    } catch (_) {/* keystore unavailable: still delete the profile */}
                    await ai.update((s) {
                      s.llmProfiles.removeWhere((x) => x.id == p.id);
                      if (s.assistantProfileId == p.id) s.assistantProfileId = s.llmProfiles.first.id;
                      if (s.translationProfileId == p.id) s.translationProfileId = s.llmProfiles.first.id;
                      if (s.assistantFallbackProfileId == p.id) s.assistantFallbackProfileId = null;
                      if (s.translationFallbackProfileId == p.id) s.translationFallbackProfileId = null;
                    });
                    if (context.mounted) Navigator.pop(context);
                  },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          LiveTextField(value: p.name, label: 'Profile name', onChanged: (v) => set((p) => p.name = v)),
          ListTile(title: const Text('Provider'), trailing: Text(llmProviderLabels[p.provider]!)),
          if (isOpenAi) ...[
            LiveTextField(
              value: p.baseUrl,
              label: 'Base URL',
              keyboard: TextInputType.url,
              helper:
                  'e.g. https://api.openai.com/v1 · https://openrouter.ai/api/v1 · http://192.168.1.10:11434/v1 (Ollama). '
                  'Plain http is only for servers on your own network: prompts travel unencrypted.',
              onChanged: (v) => set((p) => p.baseUrl = v.trim()),
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final (label, url, model) in openAiPresets)
                  ActionChip(
                    label: Text(label),
                    onPressed: () => set((p) {
                      p.baseUrl = url;
                      p.model = model;
                      p.name = label.split(' (').first;
                    }),
                  ),
              ].map((c) => Padding(padding: const EdgeInsets.only(left: 16), child: c)).toList(),
            ),
          ],
          ApiKeyField(
            key: ValueKey('llm-key-${p.id}'),
            keyName: llmKeyName(p.id),
            optional: isOpenAi,
            label: switch (p.provider) {
              LlmProvider.anthropic => 'Anthropic API key',
              LlmProvider.gemini => 'Google AI Studio API key',
              LlmProvider.openai || LlmProvider.local => 'API key',
            },
            helper: isOpenAi ? 'Leave empty for local servers without authentication' : null,
          ),
          _ModelPicker(profile: p),
          const SectionTitle('Answer style'),
          if (isClaude)
            ListTile(
              title: const Text('Effort'),
              subtitle: const Text('How hard the model thinks. Low answers fastest — right for voice.'),
              trailing: DropdownButton<String?>(
                value: p.effort,
                items: const [
                  DropdownMenuItem(value: 'low', child: Text('Low')),
                  DropdownMenuItem(value: 'medium', child: Text('Medium')),
                  DropdownMenuItem(value: 'high', child: Text('High')),
                  DropdownMenuItem(value: null, child: Text('Model default')),
                ],
                onChanged: (v) => set((p) => p.effort = v),
              ),
            ),
          SwitchListTile(
            title: const Text('Custom temperature'),
            subtitle: Text(
              isClaude && !claudeCaps(p.model).sampling
                  ? 'Current Claude models ignore it (not sent)'
                  : p.temperature == null
                  ? 'Provider default'
                  : 'Temperature ${p.temperature!.toStringAsFixed(1)}',
            ),
            value: p.temperature != null,
            onChanged: (v) => set((p) => p.temperature = v ? 0.7 : null),
          ),
          if (p.temperature != null)
            Slider(
              value: p.temperature!.clamp(0, 2),
              min: 0,
              max: 2,
              divisions: 20,
              label: p.temperature!.toStringAsFixed(1),
              onChanged: (v) => set((p) => p.temperature = double.parse(v.toStringAsFixed(1))),
            ),
          ListTile(
            title: const Text('Max output tokens'),
            subtitle: const Text('Includes thinking. Voice answers are short; keep it generous so answers are not cut off.'),
            trailing: DropdownButton<int>(
              value: const [1024, 2048, 4096, 8192, 16000, 32000].contains(p.maxTokens) ? p.maxTokens : 16000,
              items: [
                for (final n in const [1024, 2048, 4096, 8192, 16000, 32000]) DropdownMenuItem(value: n, child: Text('$n')),
              ],
              onChanged: (v) => set((p) => p.maxTokens = v ?? 16000),
            ),
          ),
          SwitchListTile(
            title: const Text('Tools (function calling)'),
            subtitle: const Text(
              'Let the assistant read and change tasks, calendar, news, brightness… Turn off for models or servers without tool support.',
            ),
            value: p.toolsEnabled,
            onChanged: (v) => set((p) => p.toolsEnabled = v),
          ),
          LiveTextField(
            value: p.systemPrompt,
            label: 'Persona / system prompt',
            maxLines: 8,
            hint: 'Empty = the built-in glasses assistant prompt',
            helper: 'Used by the assistant. Translation uses its own fixed prompt.',
            onChanged: (v) => set((p) => p.systemPrompt = v),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => set((p) => p.systemPrompt = defaultSystemPrompt), child: const Text('Start from the default prompt')),
          ),
          TestButton(run: () async => (await ai.engines.llm(p)).testConnection()),
        ],
      ),
    );
  }
}

class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.profile});
  final LlmProfile profile;
  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  bool _busy = false;

  Future<void> _fetch() async {
    final ai = AiScope.of(context);
    setState(() => _busy = true);
    try {
      final models = await (await ai.engines.llm(widget.profile)).listModels();
      if (!mounted) return;
      setState(() => _busy = false);
      if (models.isEmpty) {
        snack(context, 'The endpoint returned no models');
        return;
      }
      final picked = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (c) => DraggableScrollableSheet(
          expand: false,
          builder: (c, sc) => ListView(
            controller: sc,
            children: [
              const ListTile(title: Text('Models from the provider')),
              for (final m in models)
                ListTile(title: Text(m.id), subtitle: m.label.isEmpty ? null : Text(m.label), onTap: () => Navigator.pop(c, m.id)),
            ],
          ),
        ),
      );
      if (picked != null) await ai.update((_) => widget.profile.model = picked);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        snack(context, '$e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ai = AiScope.of(context);
    final p = widget.profile;
    return Column(
      children: [
        if (p.provider == LlmProvider.anthropic)
          ListTile(
            title: const Text('Model'),
            subtitle: Text(claudeModels.where((m) => m.id == p.model).firstOrNull?.label ?? p.model),
            trailing: PopupMenuButton<String>(
              icon: const Icon(Icons.arrow_drop_down),
              onSelected: (v) => ai.update((_) => p.model = v),
              itemBuilder: (_) => [for (final m in claudeModels) PopupMenuItem(value: m.id, child: Text(m.label))],
            ),
          ),
        LiveTextField(
          key: ValueKey('model-${p.id}-${p.model}'),
          value: p.model,
          label: 'Model id',
          hint: p.provider == LlmProvider.gemini ? defaultGeminiModel : null,
          onChanged: (v) => ai.update((_) => p.model = v.trim()),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: TextButton.icon(
              icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.list),
              label: const Text('Fetch model list'),
              onPressed: _busy ? null : _fetch,
            ),
          ),
        ),
      ],
    );
  }
}

// ── speech-to-text profile ──────────────────────────────────────────────────────────────
class SttProfileScreen extends StatelessWidget {
  const SttProfileScreen({super.key, required this.profileId});
  final String profileId;

  @override
  Widget build(BuildContext context) {
    final ai = AiScope.of(context);
    final p = ai.settings.sttById(profileId);
    if (p == null) return const Scaffold(body: Center(child: Text('Profile deleted')));
    void set(void Function(SttProfile p) f) => ai.update((_) => f(p));
    return Scaffold(
      appBar: AppBar(
        title: Text(p.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: ai.settings.sttProfiles.length <= 1
                ? null
                : () async {
                    try {
                      await ai.secrets.write(sttKeyName(p.id), null);
                    } catch (_) {/* keystore unavailable: still delete the profile */}
                    await ai.update((s) {
                      s.sttProfiles.removeWhere((x) => x.id == p.id);
                      if (s.sttProfileId == p.id) s.sttProfileId = s.sttProfiles.first.id;
                      if (s.sttFallbackProfileId == p.id) s.sttFallbackProfileId = null;
                    });
                    if (context.mounted) Navigator.pop(context);
                  },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          LiveTextField(value: p.name, label: 'Profile name', onChanged: (v) => set((p) => p.name = v)),
          ListTile(title: const Text('Provider'), trailing: Text(sttProviderLabels[p.provider]!)),
          if (p.provider == SttProvider.onDevice) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Runs Whisper on this phone (sherpa-onnx): the glasses\' audio never leaves the phone. '
                'Download the model under AI models → On this phone.',
              ),
            ),
            for (final m in sttCatalog)
              ListTile(
                leading: Icon((p.model.isEmpty ? recommendStt(null).id : p.model) == m.id
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                onTap: () => set((p) => p.model = m.id),
                title: Text('${m.label} · ${formatBytes(m.sizeBytes)}'),
                subtitle: Text('${m.summary} Licence ${m.licence}.'),
              ),
            LiveTextField(
              value: p.language,
              label: 'Language',
              hint: 'Empty = automatic (e.g. en, es, de)',
              onChanged: (v) => set((p) => p.language = v.trim().toLowerCase()),
            ),
            ListTile(
              leading: const Icon(Icons.phone_android),
              title: const Text('On this phone: download models'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OnDeviceAiScreen())),
            ),
            TestButton(run: () async => (await ai.engines.stt(p)).testConnection()),
          ],
          if (p.provider == SttProvider.whisper)
            LiveTextField(
              value: p.baseUrl,
              label: 'Base URL',
              keyboard: TextInputType.url,
              helper: 'https://api.openai.com/v1 · https://api.groq.com/openai/v1 · or a local Whisper server',
              onChanged: (v) => set((p) => p.baseUrl = v.trim()),
            ),
          if (p.provider != SttProvider.onDevice) ...[
            ApiKeyField(
              key: ValueKey('stt-key-${p.id}'),
              keyName: sttKeyName(p.id),
              label: p.provider == SttProvider.deepgram ? 'Deepgram API key' : 'API key',
              optional: p.provider == SttProvider.whisper,
            ),
            LiveTextField(
              value: p.model,
              label: 'Model',
              hint: p.provider == SttProvider.deepgram
                  ? 'Deepgram default (e.g. nova-3)'
                  : 'whisper-1 · gpt-4o-mini-transcribe · whisper-large-v3-turbo',
              onChanged: (v) => set((p) => p.model = v.trim()),
            ),
            LiveTextField(
              value: p.language,
              label: 'Language hint',
              hint: 'Empty = automatic (e.g. en, es, de)',
              onChanged: (v) => set((p) => p.language = v.trim().toLowerCase()),
            ),
            TestButton(run: () async => (await ai.engines.stt(p)).testConnection()),
          ],
        ],
      ),
    );
  }
}

/// Throws a readable error for engines that cannot be built yet (missing key etc.).
String describeEngineError(Object e) => e is AiError ? e.message : '$e';
