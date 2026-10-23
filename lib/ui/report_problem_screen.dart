/// Report a problem: an optional description, a few choices, then a PREVIEW of exactly the text
/// that will be shared, then Share (Android share sheet) or Save to file. Nothing is uploaded.
/// Entry points: Settings → Help, Developer mode, and connection-error places (scan screen,
/// Connection card).
library;

import 'package:flutter/material.dart';

import '../hub/hub_controller.dart';
import '../services/diagnostics_platform.dart';
import '../services/diagnostics_report.dart';
import 'ai/ai_scope.dart';
import 'app_scope.dart';
import 'common.dart';
import 'settings_screen.dart' show appVersion;

/// Opens [ReportProblemScreen].
class ReportProblemButton extends StatelessWidget {
  const ReportProblemButton({super.key, this.label = 'Report a problem'});
  final String label;
  @override
  Widget build(BuildContext context) => TextButton.icon(
        icon: const Icon(Icons.bug_report_outlined),
        label: Text(label),
        onPressed: () => openReportProblem(context),
      );
}

void openReportProblem(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ReportProblemScreen()));

/// True when the last connection attempt failed or the link dropped (and it is not connected).
bool connectionTroubled(HubController hub) {
  if (hub.status == LinkStatus.connected || hub.connectionHistory.isEmpty) return false;
  final last = hub.connectionHistory.last.event;
  return last == 'connect_failed' || last == 'link_lost' || last == 'retry_scheduled';
}

class ReportProblemScreen extends StatefulWidget {
  const ReportProblemScreen({super.key, this.sink, this.facts});

  /// Where the report goes (tests pass a fake).
  final ReportSink? sink;

  /// Platform facts (tests pass fixed ones).
  final Future<PlatformFacts> Function()? facts;

  @override
  State<ReportProblemScreen> createState() => _ReportProblemScreenState();
}

class _ReportProblemScreenState extends State<ReportProblemScreen> {
  final _desc = TextEditingController();
  bool _anonymise = true;
  int _frames = 200;
  bool _busy = false;

  static const frameChoices = [0, 50, 100, 200, 400];

  @override
  void dispose() {
    _desc.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final hub = AppScope.of(context, listen: false);
      final ai = context.getInheritedWidgetOfExactType<AiScope>()?.notifier;
      final facts = await (widget.facts ?? gatherPlatformFacts)();
      final bundle = await buildDiagnosticsReport(
        hub: hub,
        ai: ai,
        facts: facts,
        description: _desc.text,
        options: ReportOptions(anonymiseLens: _anonymise, maxFrames: _frames),
        appVersion: appVersion,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ReportPreviewScreen(bundle: bundle, sink: widget.sink ?? const PlatformReportSink())),
      );
    } catch (e) {
      if (mounted) showMessage(context, 'Could not build the report: ${friendlyError(e)}', ok: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final t = Theme.of(context).textTheme;
    final buffered = hub.services.wire.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Report a problem')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Makes one file with diagnostics for the developer: app and phone details, the connection '
              'history, the log, recent Bluetooth frames and sync state. Personal details are removed first. '
              'Nothing is sent by itself: you see the whole file, then share or save it.',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('report-description'),
              controller: _desc,
              minLines: 3,
              maxLines: 8,
              maxLength: 2000,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Describe what happened (optional)',
                hintText: 'What did you do, what did you expect, what happened instead?',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Hide lens addresses and serial'),
              subtitle: const Text('Shown as lens-R, lens-L and serial'),
              value: _anonymise,
              onChanged: (v) => setState(() => _anonymise = v),
            ),
            Row(
              children: [
                const Expanded(child: Text('Recent Bluetooth frames')),
                DropdownButton<int>(
                  key: const Key('report-frames'),
                  value: _frames,
                  items: [for (final n in frameChoices) DropdownMenuItem(value: n, child: Text(n == 0 ? 'None' : 'Last $n'))],
                  onChanged: (v) => setState(() => _frames = v ?? _frames),
                ),
              ],
            ),
            Text(
              hub.data.ui.devMode
                  ? '$buffered frame(s) recorded so far.'
                  : 'Frames are recorded only while Developer mode is on (Settings → Beta & Developer).',
              style: t.bodySmall,
            ),
            const SizedBox(height: 12),
            const ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.only(bottom: 8),
              title: Text('What is in the report'),
              expandedAlignment: Alignment.centerLeft,
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Included: app version, Android version and phone model, Bluetooth adapter details, '
                  'permission states, connection history, the app log, recent frames (header fields; '
                  'message bytes only for services that carry no text), sync state, Even AI and translate '
                  'state changes, on-device model speed, settings as on/off and counts, recent app errors.\n\n'
                  'Never included: API keys (only whether one is set), calendar links, event / task / news '
                  'titles, teleprompter text, your location or city, notification content and app names, '
                  'AI questions, answers and transcripts, EvenHub app data, names you gave things.',
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('report-preview-button'),
              onPressed: _busy ? null : _preview,
              icon: _busy
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.preview_outlined),
              label: const Text('Preview report'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows exactly [bundle.text]; Share / Save hand over that same text.
class ReportPreviewScreen extends StatefulWidget {
  const ReportPreviewScreen({super.key, required this.bundle, required this.sink});
  final DiagnosticsBundle bundle;
  final ReportSink sink;
  @override
  State<ReportPreviewScreen> createState() => _ReportPreviewScreenState();
}

class _ReportPreviewScreenState extends State<ReportPreviewScreen> {
  bool _busy = false;

  Future<void> _run(Future<bool> Function(DiagnosticsBundle) job, String done, String failed) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await job(widget.bundle);
      if (mounted && done.isNotEmpty && ok) showMessage(context, done);
      if (mounted && !ok && failed.isNotEmpty) showMessage(context, failed, ok: false);
    } catch (e) {
      if (mounted) showMessage(context, friendlyError(e), ok: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.bundle;
    final kb = (b.text.length / 1024).toStringAsFixed(1);
    return Scaffold(
      appBar: AppBar(title: const Text('Preview')),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('This is the whole file that will be shared: ${b.fileName} ($kb KB).'),
            ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(8),
                  child: SelectableText(
                    b.text,
                    key: const Key('report-preview'),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _run(widget.sink.save, 'Report saved', ''),
                      icon: const Icon(Icons.save_alt),
                      label: const Text('Save to file'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : () => _run(widget.sink.share, '', 'Sharing is not available on this device; use Save to file'),
                      icon: const Icon(Icons.share),
                      label: const Text('Share'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
