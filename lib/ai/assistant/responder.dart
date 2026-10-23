/// Rolling assistant conversation with tool calling — port of the hub's ClaudeResponder,
/// provider-agnostic: works with any [LlmEngine]; tools are offered only when the engine can
/// call functions (an on-device model without tool calling still answers, just without tools).
library;

import '../providers/llm.dart';
import 'tools.dart';

typedef ToolRunner = Future<String> Function(String name, Map<String, Object?> args);

class AssistantReply {
  AssistantReply(this.text, {this.model = '', this.actions = const [], this.refused = false});
  final String text;
  final String model;

  /// Tool calls made, e.g. ['add_task(Buy milk)', 'set_brightness(30) FAILED'].
  final List<String> actions;
  final bool refused;
}

class Responder {
  Responder({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  static const int maxToolRounds = 8;
  static const int maxHistory = 20;
  static const Duration idleReset = Duration(minutes: 5);

  final DateTime Function() _clock;
  List<ChatTurn> messages = [];
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  void reset() => messages = [];

  /// Keep the last [maxHistory] turns, starting at a plain user turn (never split a tool
  /// result from its call).
  static List<ChatTurn> trim(List<ChatTurn> m) {
    if (m.length <= maxHistory) return m;
    final tail = m.sublist(m.length - maxHistory);
    final i = tail.indexWhere((t) => t.role == TurnRole.user);
    return i < 0 ? [] : tail.sublist(i);
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
  static const _wd = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  static const _mo = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

  /// "Wednesday 15 October 2026, 14:03 CEST" — the model has no clock.
  static String localNow(DateTime t) =>
      '${_wd[t.weekday - 1]} ${_two(t.day)} ${_mo[t.month - 1]} ${t.year}, ${_two(t.hour)}:${_two(t.minute)} ${t.timeZoneName}';

  Future<AssistantReply> ask(
    String question, {
    required LlmEngine engine,
    required String system,
    int maxTokens = 16000,
    double? temperature,
    String? effort,
    List<ToolSpec> tools = const [],
    ToolRunner? runTool,
    void Function(String delta)? onDelta,
  }) async {
    final now = _clock();
    if (now.difference(_last) > idleReset) messages = [];
    _last = now;
    final useTools = runTool != null && tools.isNotEmpty && engine.caps.toolCalling;
    var convo = [...messages, ChatTurn.user(question)];
    final sys = '$system\n\nCurrent local date and time: ${localNow(now)}.';
    final actions = <String>[];
    var model = '';
    for (var round = 0; round < maxToolRounds; round++) {
      final r = await engine.complete(LlmRequest(
        system: sys,
        messages: convo,
        tools: useTools ? tools : const [],
        maxTokens: maxTokens,
        temperature: temperature,
        effort: effort,
        onDelta: onDelta,
      ));
      model = r.model;
      if (r.refused) return AssistantReply(r.text, model: model, actions: actions, refused: true);
      convo = [...convo, r.toTurn()];
      if (!useTools || r.toolCalls.isEmpty) {
        messages = trim(convo);
        return AssistantReply(r.text, model: model, actions: actions);
      }
      final results = <ToolResult>[];
      for (final call in r.toolCalls) {
        final label = AssistantTools.label(call.name, call.args);
        String out;
        var isError = false;
        if (call.args.containsKey('__invalid_json__')) {
          out = 'Error: the tool arguments were not valid JSON';
          isError = true;
        } else {
          try {
            out = await runTool(call.name, call.args);
          } catch (e) {
            out = 'Error: $e';
            isError = true;
          }
        }
        actions.add(isError ? '$label FAILED' : label);
        results.add(ToolResult(call.id, call.name, out.length > 20000 ? out.substring(0, 20000) : out, isError: isError));
      }
      convo = [...convo, ChatTurn.results(results)];
    }
    messages = [];
    return AssistantReply('Sorry, that took too many steps.', model: model, actions: actions);
  }
}
