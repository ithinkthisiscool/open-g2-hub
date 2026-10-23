/// Apps → Live translate: languages, conversation mode (phone or glasses mic; Start/Stop is
/// a genuine user action) and hands-free mode (each wake gesture translates; applies at once
/// and switches itself off when Translate is closed on the glasses).
library;

import 'package:flutter/material.dart';

import '../../ai/providers/translation.dart';
import '../../hub/translate_live.dart';
import 'ai_models_screen.dart';
import 'ai_scope.dart';

class LiveTranslateScreen extends StatefulWidget {
  const LiveTranslateScreen({super.key});
  @override
  State<LiveTranslateScreen> createState() => _LiveTranslateScreenState();
}

class _LiveTranslateScreenState extends State<LiveTranslateScreen> {
  bool _busy = false;

  Widget _lang(String value, ValueChanged<String> on, String label) {
    final items = {...translateLanguages.keys, value};
    return Expanded(
      child: DropdownButtonFormField<String>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        items: [for (final k in items) DropdownMenuItem(value: k, child: Text(langName(k)))],
        onChanged: (v) => on(v!),
      ),
    );
  }

  Future<void> _toggle() async {
    final ai = AiScope.of(context);
    setState(() => _busy = true);
    try {
      if (ai.live.running) {
        await ai.stopLive();
      } else {
        await ai.startLive(ai.settings.translateSrc, ai.settings.translateDst, ai.settings.liveSource);
      }
    } on MicUnavailable catch (e) {
      if (mounted) snack(context, e.message, error: true);
    } catch (e) {
      if (mounted) snack(context, '$e', error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final ai = AiScope.of(context);
    final s = ai.settings;
    final live = ai.live;
    final cs = Theme.of(context).colorScheme;
    final problem = ai.translationProblem ?? ai.speechProblem;
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              _lang(s.translateSrc, (v) => ai.update((s) => s.translateSrc = v), 'I hear'),
              IconButton(
                icon: const Icon(Icons.swap_horiz),
                tooltip: 'Swap',
                onPressed: live.running
                    ? null
                    : () => ai.update((s) {
                        final t = s.translateSrc;
                        s.translateSrc = s.translateDst;
                        s.translateDst = t;
                      }),
              ),
              _lang(s.translateDst, (v) => ai.update((s) => s.translateDst = v), 'Show in'),
            ],
          ),
        ),
        if (problem != null)
          ListTile(
            leading: Icon(Icons.info_outline, color: cs.error),
            title: Text(problem, style: TextStyle(color: cs.error)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AiModelsScreen())),
          ),
        const SectionTitle('Conversation'),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('Listens continuously and shows each sentence with its translation on the glasses\' Translate screen.'),
        ),
        ListTile(
          title: const Text('Microphone'),
          trailing: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'phone', icon: Icon(Icons.smartphone), label: Text('Phone')),
              ButtonSegment(value: 'glasses', icon: Icon(Icons.visibility), label: Text('Glasses')),
            ],
            selected: {s.liveSource},
            onSelectionChanged: live.running ? null : (v) => ai.update((s) => s.liveSource = v.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: FilledButton.icon(
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(live.running ? Icons.stop : Icons.mic),
            label: Text(live.running ? 'Stop translating' : 'Start translating'),
            onPressed: _busy || (!live.running && s.liveSource == 'glasses' && !ai.connected) ? null : _toggle,
          ),
        ),
        if (!live.running && s.liveSource == 'glasses' && !ai.connected)
          const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Connect the glasses to use their microphone.')),
        if (live.running)
          ListTile(
            leading: Icon(live.listeningSpeech ? Icons.graphic_eq : Icons.hearing, color: live.listeningSpeech ? Colors.green : null),
            title: Text(live.listeningSpeech ? 'Hearing speech…' : 'Listening (${live.sourceName} mic)'),
            subtitle: Text(
              '${live.utterances} sentence(s)${live.rearms > 0 ? ' · mic re-armed ${live.rearms}×' : ''}'
              '${live.lastPushError.isNotEmpty ? ' · ${live.lastPushError}' : ''}',
            ),
          ),
        if (live.lastError.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(live.lastError, style: TextStyle(color: cs.error)),
          ),
        ListTile(
          title: const Text('Stop after silence'),
          subtitle: const Text('Saves battery if you forget to stop'),
          trailing: DropdownButton<int>(
            value: const [0, 2, 5, 10, 20, 30].contains(s.liveIdleStopMin) ? s.liveIdleStopMin : 10,
            items: [
              for (final m in const [2, 5, 10, 20, 30, 0]) DropdownMenuItem(value: m, child: Text(m == 0 ? 'Never' : '$m min')),
            ],
            onChanged: (v) => ai.update((s) => s.liveIdleStopMin = v ?? 10),
          ),
        ),
        for (final l in live.lines.reversed.take(30)) ListTile(dense: true, title: Text(l.translated), subtitle: Text(l.original)),
        const SectionTitle('Hands-free'),
        SwitchListTile(
          title: const Text('Translate with the wake gesture'),
          subtitle: const Text(
            'Each "Hey Even" translates what you say next instead of asking the assistant. '
            'Turns itself off when you close Translate on the glasses.',
          ),
          value: s.translateHandsFree,
          onChanged: (v) => ai.update((s) => s.translateHandsFree = v),
        ),
      ],
    );
  }
}
