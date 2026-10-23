/// Developer mode: protocol log/console, raw frame inspector (decoded where the app knows the
/// service), raw send, sync state and Force resync.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../hub/features.dart' show PushResult;
import '../hub/glasses_session.dart';
import '../hub/sync_engine.dart';
import '../protocol/pb.dart';
import '../protocol/sids.dart';
import 'app_scope.dart';
import 'common.dart';
import 'report_problem_screen.dart';

/// The session log (newest first), filterable.
class LogView extends StatefulWidget {
  const LogView({super.key, this.filter = true});
  final bool filter;
  @override
  State<LogView> createState() => _LogViewState();
}

class _LogViewState extends State<LogView> {
  String _q = '';
  LogLevel? _level;
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    final logs = hub.logs.where((l) => (_level == null || l.level == _level) && (_q.isEmpty || l.message.toLowerCase().contains(_q))).toList();
    return Column(
      children: [
        if (widget.filter)
          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(isDense: true, hintText: 'Filter'),
                  onChanged: (v) => setState(() => _q = v.toLowerCase()),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<LogLevel?>(
                value: _level,
                items: [
                  const DropdownMenuItem(value: null, child: Text('All')),
                  for (final l in LogLevel.values) DropdownMenuItem(value: l, child: Text(l.name)),
                ],
                onChanged: (v) => setState(() => _level = v),
              ),
            ],
          ),
        Expanded(
          child: logs.isEmpty
              ? const Center(child: Text('Nothing yet'))
              : ListView.builder(
                  reverse: true,
                  itemCount: logs.length,
                  itemBuilder: (_, i) {
                    final l = logs[logs.length - 1 - i];
                    final c = switch (l.level) {
                      LogLevel.ok => Colors.green,
                      LogLevel.warn => Colors.orange,
                      LogLevel.err => cs.error,
                      LogLevel.info => cs.onSurfaceVariant,
                    };
                    final t = l.at;
                    String two(int v) => v.toString().padLeft(2, '0');
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}  ${l.message}',
                        style: TextStyle(fontSize: 12, color: c, fontFamily: 'monospace'),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Raw frames on the wire (TX/RX), newest first, with a decode on tap.
class FrameInspector extends StatefulWidget {
  const FrameInspector({super.key});
  @override
  State<FrameInspector> createState() => _FrameInspectorState();
}

class _FrameInspectorState extends State<FrameInspector> {
  Timer? _t;
  int? _sid;
  bool _hideHeartbeat = true;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = AppScope.of(context).services;
    final frames = svc.wire
        .where((w) => (_sid == null || w.sid == _sid) && !(_hideHeartbeat && w.sid == sidEvenHub && w.payload.length < 12 && !w.rx))
        .toList()
        .reversed
        .toList();
    final sids = {for (final w in svc.wire) w.sid}.toList()..sort();
    return Column(
      children: [
        Row(
          children: [
            DropdownButton<int?>(
              value: sids.contains(_sid) ? _sid : null,
              items: [
                const DropdownMenuItem(value: null, child: Text('All services')),
                for (final s in sids) DropdownMenuItem(value: s, child: Text(sidName(s))),
              ],
              onChanged: (v) => setState(() => _sid = v),
            ),
            const Spacer(),
            IconButton(
              tooltip: svc.wirePaused ? 'Resume' : 'Pause',
              onPressed: () => setState(() => svc.wirePaused = !svc.wirePaused),
              icon: Icon(svc.wirePaused ? Icons.play_arrow : Icons.pause),
            ),
            IconButton(tooltip: 'Clear', onPressed: () => setState(svc.wire.clear), icon: const Icon(Icons.delete_sweep_outlined)),
          ],
        ),
        SwitchListTile(
          dense: true,
          title: const Text('Hide heartbeats'),
          value: _hideHeartbeat,
          onChanged: (v) => setState(() => _hideHeartbeat = v),
        ),
        Expanded(
          child: frames.isEmpty
              ? const Center(child: Text('No frames yet (connect the glasses).'))
              : ListView.builder(
                  itemCount: frames.length,
                  itemBuilder: (_, i) {
                    final w = frames[i];
                    return ListTile(
                      dense: true,
                      leading: Icon(w.rx ? Icons.south_west : Icons.north_east, size: 16, color: w.rx ? Colors.green : Colors.blue),
                      title: Text(
                        '${sidName(w.sid)} · ${w.side.name} · flag 0x${w.flag.toRadixString(16)} · ${w.payload.length} B',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                      subtitle: Text(
                        hex(w.payload),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                      ),
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text('${w.rx ? 'Received' : 'Sent'} · ${sidName(w.sid)} (0x${w.sid.toRadixString(16)})'),
                          content: SingleChildScrollView(
                            child: SelectableText(describeFrame(w), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// A protobuf field tree of a payload (best effort).
String describeFrame(WireFrame w) {
  final b = StringBuffer('${w.at.toIso8601String()}\nhex: ${hex(w.payload)}\n\n');
  void walk(List<int> pb, String indent, int depth) {
    try {
      for (final f in iterFields(pb)) {
        if (f.wire == 2 && depth < 4) {
          final bytes = f.asBytes;
          b.writeln(
            '$indent${f.number}: (${bytes.length} B) ${hex(bytes.length > 40 ? bytes.sublist(0, 40) : bytes)}${bytes.length > 40 ? '…' : ''}',
          );
          walk(bytes, '$indent  ', depth + 1);
        } else {
          b.writeln('$indent${f.number}: ${f.value is List<int> ? hex(f.value as List<int>) : f.value}');
        }
      }
    } catch (_) {
      /* not protobuf below this level */
    }
  }

  walk(w.payload, '', 0);
  return b.toString();
}

/// Settings → Developer.
class DeveloperPage extends StatefulWidget {
  const DeveloperPage({super.key});
  @override
  State<DeveloperPage> createState() => _DeveloperPageState();
}

class _DeveloperPageState extends State<DeveloperPage> {
  final _sid = TextEditingController(text: '09');
  final _hex = TextEditingController();
  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context);
    final sync = hub.services.sync;
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Sync'),
              Tab(text: 'Log'),
              Tab(text: 'Frames'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                ListenableBuilder(
                  listenable: sync,
                  builder: (context, _) => ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final s in sync.sections)
                        ListTile(
                          dense: true,
                          title: Text(s.label),
                          subtitle: Text('${sync.describe(s.key)}\n${s.key} · ${s.status.name}${s.lastError != null ? ' · ${s.lastError}' : ''}'),
                          isThreeLine: true,
                        ),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: () {
                          sync.resyncAll();
                          showMessage(context, sync.connected ? 'Re-sending everything' : 'Will re-send everything on connect');
                        },
                        icon: const Icon(Icons.sync),
                        label: const Text('Force resync'),
                      ),
                      const Divider(height: 32),
                      Text('Send a raw message (right lens, flag 0x20)', style: Theme.of(context).textTheme.titleSmall),
                      Row(
                        children: [
                          SizedBox(
                            width: 80,
                            child: TextField(
                              controller: _sid,
                              decoration: const InputDecoration(labelText: 'SID hex'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _hex,
                              decoration: const InputDecoration(labelText: 'Protobuf hex'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ActionButton(
                        label: 'Send',
                        icon: Icons.send,
                        outlined: true,
                        onPressed: () async {
                          final sid = int.tryParse(_sid.text.trim(), radix: 16);
                          if (sid == null || sid < 0 || sid > 0xFF) return PushResult(false, 'SID must be one hex byte (00-FF)');
                          final hexText = _hex.text.replaceAll(RegExp(r'\s'), '');
                          if (hexText.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(hexText)) {
                            return PushResult(false, 'Payload must be hex bytes, e.g. 08 01 10 05');
                          }
                          await hub.session!.send(sid, unhex(hexText));
                          return PushResult(true, 'Sent ${hexText.length ~/ 2} byte(s) to SID 0x${sid.toRadixString(16).padLeft(2, '0')}');
                        },
                      ),
                      const SizedBox(height: 8),
                      const Align(alignment: Alignment.centerLeft, child: ReportProblemButton()),
                      const SizedBox(height: 8),
                      Text('Sections: ${SectionStatus.values.map((e) => e.name).join(' / ')}', style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                const Padding(padding: EdgeInsets.all(12), child: LogView()),
                const Padding(padding: EdgeInsets.all(12), child: FrameInspector()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
