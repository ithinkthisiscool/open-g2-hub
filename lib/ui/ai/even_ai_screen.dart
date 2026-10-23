/// Apps → Even AI: what the wake gesture does, live status of the current turn, a typed
/// "Try it", voice shortcuts and the history log. No send buttons: settings apply at once and
/// the wake gesture on the glasses does the rest.
library;

import 'package:flutter/material.dart';

import '../../ai/assistant/tools.dart';
import '../../ai/assistant/voice_shortcuts.dart';
import '../../ai/audio/silero_vad.dart';
import '../../ai/config/ai_config.dart';
import '../../hub/even_ai.dart';
import 'ai_models_screen.dart';
import 'ai_scope.dart';
import 'profile_editors.dart';

class EvenAiScreen extends StatelessWidget {
  const EvenAiScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ai = AiScope.of(context);
    final s = ai.settings;
    final c = ai.evenAi;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final setup = s.mode == EvenAiMode.assistant
        ? (ai.assistantProblem ?? (s.listen ? ai.speechProblem : null))
        : (s.listen && s.mode != EvenAiMode.off && s.mode != EvenAiMode.open ? ai.speechProblem : null);

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Card(
          margin: const EdgeInsets.all(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(ai.connected ? Icons.record_voice_over : Icons.link_off, color: ai.connected ? Colors.green : cs.outline),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        !ai.connected
                            ? 'Glasses not connected'
                            : s.translateHandsFree
                            ? 'Wake gesture translates (${s.translateSrc} → ${s.translateDst})'
                            : s.mode == EvenAiMode.off
                            ? 'Even AI is off'
                            : 'Ready — say "Hey Even" or open Even AI on the glasses',
                        style: t.titleMedium,
                      ),
                    ),
                  ],
                ),
                if (c != null && c.phase != AiPhase.idle) ...[
                  const SizedBox(height: 8),
                  Text(_phaseLabel(c.phase), style: t.labelLarge?.copyWith(color: cs.primary)),
                  if (c.question.isNotEmpty) Text('“${c.question}”'),
                  if (c.reply.isNotEmpty && c.phase == AiPhase.answered) Text(c.reply, style: t.bodySmall),
                  if (c.statusMessage.isNotEmpty) Text(c.statusMessage, style: TextStyle(color: cs.error)),
                ],
                if (setup != null) ...[
                  const SizedBox(height: 8),
                  Text(setup, style: TextStyle(color: cs.error)),
                  TextButton.icon(
                    icon: const Icon(Icons.settings_suggest_outlined),
                    label: const Text('Set up AI models'),
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AiModelsScreen())),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SectionTitle('When Even AI wakes'),
        RadioGroup<EvenAiMode>(
          groupValue: s.mode,
          onChanged: (v) => ai.update((s) => s.mode = v!),
          child: Column(
            children: [for (final m in EvenAiMode.values) RadioListTile<EvenAiMode>(value: m, title: Text(evenAiModeLabels[m]!), dense: true)],
          ),
        ),
        if (s.mode == EvenAiMode.autoReply)
          LiveTextField(value: s.cannedReply, label: 'Auto-reply text', maxLines: 3, onChanged: (v) => ai.update((s) => s.cannedReply = v)),
        if (s.mode == EvenAiMode.assistant || s.mode == EvenAiMode.autoReply) ...[
          SwitchListTile(
            title: const Text('Listen to the question'),
            subtitle: Text(s.vadEngine == 'silero'
                ? 'Uses the glasses microphone; listening stops ${(s.vadSilenceMs / 1000).toStringAsFixed(1)} s after you stop talking'
                : 'Uses the glasses microphone; listening stops ~1.2 s after you stop talking'),
            value: s.listen,
            onChanged: (v) => ai.update((s) => s.listen = v),
          ),
          if (s.listen)
            ListTile(
              title: Text('Listen at most ${s.listenSeconds} s'),
              subtitle: Slider(
                value: s.listenSeconds.toDouble(),
                min: 2,
                max: 30,
                divisions: 28,
                onChanged: (v) => ai.update((s) => s.listenSeconds = v.round()),
              ),
            ),
          SwitchListTile(
            title: const Text('Show my question on the glasses'),
            value: s.showQuestion,
            onChanged: (v) => ai.update((s) => s.showQuestion = v),
          ),
          SwitchListTile(
            title: const Text('Close the answer after reading time'),
            subtitle: const Text('Saves battery; scrolling on the glasses gives you more time'),
            value: s.autoCloseReply,
            onChanged: (v) => ai.update((s) => s.autoCloseReply = v),
          ),
        ],
        if (s.mode == EvenAiMode.assistant) ...[
          SwitchListTile(
            title: const Text('Let the assistant use the glasses'),
            subtitle: const Text('Tasks, calendar, news, weather, brightness, silent mode, display'),
            value: s.tools,
            onChanged: (v) => ai.update((s) => s.tools = v),
          ),
          ListTile(
            leading: const Icon(Icons.settings_suggest_outlined),
            title: const Text('AI models'),
            subtitle: Text(s.llmById(s.assistantProfileId)?.name ?? '—'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AiModelsScreen())),
          ),
        ],
        SwitchListTile(
          title: const Text('Voice shortcuts'),
          subtitle: const Text('“Hide display”, “brightness up”, “silent mode on”… run instantly without the AI'),
          value: s.voiceShortcuts,
          onChanged: (v) => ai.update((s) => s.voiceShortcuts = v),
        ),
        if (s.voiceShortcuts)
          ListTile(
            title: const Text('Shortcut phrases'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ShortcutsScreen())),
          ),
        const _SpeechDetection(),
        const SectionTitle('Try it'),
        const _TryIt(),
        SectionTitle(
          'History',
          trailing: ai.history.isEmpty ? null : TextButton(onPressed: () => _confirmClear(context), child: const Text('Clear')),
        ),
        if (ai.history.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No questions yet')),
        for (final e in ai.history.reversed.take(100)) _HistoryTile(e),
      ],
    );
  }

  static String _phaseLabel(AiPhase p) => switch (p) {
    AiPhase.open => 'Even AI open',
    AiPhase.listening => 'Listening…',
    AiPhase.transcribing => 'Transcribing…',
    AiPhase.heard => 'Heard',
    AiPhase.thinking => 'Thinking…',
    AiPhase.answered => 'Answered',
    AiPhase.error => 'Error',
    AiPhase.idle => '',
  };

  Future<void> _confirmClear(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Clear the history?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Clear')),
        ],
      ),
    );
    if (yes == true && context.mounted) await AiScope.of(context).clearHistory();
  }
}

/// Advanced: which voice-activity detector ends a question / cuts translate utterances, its
/// sensitivity and the pause length. Shared by Even AI and live translate.
class _SpeechDetection extends StatelessWidget {
  const _SpeechDetection();
  @override
  Widget build(BuildContext context) {
    final ai = AiScope.of(context);
    final s = ai.settings;
    final silero = s.vadEngine == 'silero';
    final status = !silero
        ? 'Energy detector'
        : ai.vad.unavailable == null
            ? 'Silero VAD $sileroVadRelease'
            : 'Energy detector (Silero VAD $sileroVadRelease unavailable: ${ai.vad.unavailable})';
    return ExpansionTile(
      leading: const Icon(Icons.graphic_eq),
      title: const Text('Advanced: speech detection'),
      subtitle: Text(status, maxLines: 2, overflow: TextOverflow.ellipsis),
      childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Decides when you have finished speaking (Even AI) and where one sentence ends (live translate).'),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'silero', label: Text('Silero VAD')),
            ButtonSegment(value: 'energy', label: Text('Energy (simple)')),
          ],
          selected: {s.vadEngine},
          onSelectionChanged: (v) => ai.update((s) => s.vadEngine = v.first),
        ),
        if (silero) ...[
          const SizedBox(height: 12),
          const Text('Sensitivity'),
          const SizedBox(height: 4),
          SegmentedButton<VadSensitivity>(
            segments: const [
              ButtonSegment(value: VadSensitivity.low, label: Text('Low')),
              ButtonSegment(value: VadSensitivity.normal, label: Text('Normal')),
              ButtonSegment(value: VadSensitivity.high, label: Text('High')),
            ],
            selected: {s.vadSensitivity},
            onSelectionChanged: (v) => ai.update((s) => s.vadSensitivity = v.first),
          ),
          const Text('Low for noisy places (only clear speech counts), High for quiet voices.', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Text('Pause that ends what you say: ${(s.vadSilenceMs / 1000).toStringAsFixed(2)} s'),
          Slider(
            value: s.vadSilenceMs.clamp(500, 1500).toDouble(),
            min: 500,
            max: 1500,
            divisions: 20,
            label: '${s.vadSilenceMs} ms',
            onChanged: (v) => ai.update((s) => s.vadSilenceMs = v.round()),
          ),
        ],
        Text(
          'Silero VAD $sileroVadRelease (MIT licence, snakers4/silero-vad) runs on this phone; no audio leaves it '
          'for speech detection. If it cannot run, the simple energy detector is used.',
          style: const TextStyle(fontSize: 12),
        ),
        TextButton(onPressed: () => showLicensePage(context: context, applicationName: 'G2 Hub'), child: const Text('Open-source licences')),
      ],
    );
  }
}

class _TryIt extends StatefulWidget {
  const _TryIt();
  @override
  State<_TryIt> createState() => _TryItState();
}

class _TryItState extends State<_TryIt> {
  final _q = TextEditingController();
  bool _busy = false;
  String? _answer;
  bool _err = false;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    final ai = AiScope.of(context);
    setState(() => _busy = true);
    try {
      _answer = await ai.tryIt(_q.text);
      _err = false;
    } catch (e) {
      _answer = describeEngineError(e);
      _err = true;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _q,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _busy ? null : _ask(),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: 'Type a question to test your model and prompt',
              suffixIcon: IconButton(
                icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
                onPressed: _busy ? null : _ask,
              ),
            ),
          ),
          if (_answer != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_answer!, style: TextStyle(color: _err ? Theme.of(context).colorScheme.error : null)),
            ),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('Answers here are not shown on the glasses; tools still act on your real data.', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile(this.e);
  final AiHistoryEntry e;
  @override
  Widget build(BuildContext context) {
    final t = e.at;
    String two(int v) => v.toString().padLeft(2, '0');
    final when = '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
    final icon = switch (e.source) {
      'typed' => Icons.keyboard_alt_outlined,
      'shortcut' => Icons.bolt,
      'translate' || 'conversation' => Icons.translate,
      _ => Icons.mic_none,
    };
    return ExpansionTile(
      leading: Icon(icon),
      title: Text(e.question.isEmpty ? '(nothing heard)' : e.question, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(e.error != null ? '$when · ${e.error}' : '$when · ${e.reply}', maxLines: 1, overflow: TextOverflow.ellipsis),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (e.reply.isNotEmpty) SelectableText(e.reply),
        if (e.actions.isNotEmpty) Text('Actions: ${e.actions.join(', ')}', style: Theme.of(context).textTheme.bodySmall),
        Text(
          [
            if (e.model != null) e.model!,
            if (e.audioSeconds != null) '${e.audioSeconds} s audio',
            if (e.confidence != null) '${(e.confidence! * 100).round()}% confidence',
            e.source,
          ].join(' · '),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Built-in voice shortcuts and the user's own phrases.
class ShortcutsScreen extends StatelessWidget {
  const ShortcutsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final ai = AiScope.of(context);
    final custom = ai.settings.customShortcuts;
    return Scaffold(
      appBar: AppBar(title: const Text('Voice shortcuts')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Add phrase'),
        onPressed: () => _add(context),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Say one of these (politeness like “please” or “okay” is fine) and it runs straight away. '
              'Anything else goes to the AI.',
            ),
          ),
          if (custom.isNotEmpty) const SectionTitle('Your phrases'),
          for (final c in custom)
            ListTile(
              title: Text('“${c.phrase}”'),
              subtitle: Text(_actionLabel(c.action, c.args)),
              trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => ai.update((s) => s.customShortcuts.remove(c))),
            ),
          const SectionTitle('Built in'),
          for (final (action, args, phrases) in shortcutList())
            ListTile(title: Text(_actionLabel(action, args)), subtitle: Text(phrases.take(8).map((p) => '“$p”').join(', '))),
        ],
      ),
    );
  }

  static const Map<String, (String, Map<String, Object?>)> _choices = {
    'Hide the display': ('close_display', {}),
    'Show the dashboard': ('show_dashboard', {}),
    'Show the weather': ('show_weather', {}),
    'Brightness up': ('adjust_brightness', {'delta': brightnessStep}),
    'Brightness down': ('adjust_brightness', {'delta': -brightnessStep}),
    'Automatic brightness': ('set_brightness', {'auto': true}),
    'Silent mode on': ('set_silent_mode', {'on': true}),
    'Silent mode off': ('set_silent_mode', {'on': false}),
    'Refresh the news': ('refresh_news', {}),
    'Read my tasks': ('list_tasks', {}),
    'Read my calendar': ('list_calendar', {}),
  };

  static String _actionLabel(String action, Map<String, Object?> args) {
    for (final e in _choices.entries) {
      if (e.value.$1 == action && e.value.$2.toString() == args.toString()) return e.key;
    }
    return args.isEmpty ? action : '$action $args';
  }

  Future<void> _add(BuildContext context) async {
    final ai = AiScope.of(context);
    final phrase = TextEditingController();
    var choice = _choices.keys.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('New voice shortcut'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: phrase,
                decoration: const InputDecoration(labelText: 'Phrase', hintText: 'e.g. lights out'),
              ),
              const SizedBox(height: 12),
              DropdownButton<String>(
                isExpanded: true,
                value: choice,
                items: [for (final k in _choices.keys) DropdownMenuItem(value: k, child: Text(k))],
                onChanged: (v) => set(() => choice = v!),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true || normalize(phrase.text).isEmpty) return;
    final (action, args) = _choices[choice]!;
    assert(AssistantTools.names.contains(action));
    await ai.update((s) => s.customShortcuts.add(CustomShortcut(phrase.text.trim(), action, args)));
  }
}
