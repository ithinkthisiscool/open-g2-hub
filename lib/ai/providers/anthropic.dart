/// Anthropic Claude over raw HTTPS (Dart has no official Anthropic SDK): POST /v1/messages,
/// GET /v1/models. Headers: x-api-key, anthropic-version 2023-06-01.
///
/// Request shape (current models):
///  * no `temperature` / sampling params on current models (they return 400); only sent to
///    older models that still accept them (Haiku 4.5, the 4.6 / 4.5 family);
///  * no `thinking` field: current models run adaptive thinking by default; depth is set with
///    `output_config.effort` (low for voice). Haiku 4.5 does not accept `effort`;
///  * server-side refusal fallback (`fallbacks: "default"`, beta
///    `server-side-fallback-2026-07-01`) on Opus 5.5 / Opus 5 / Fable 5.x / Sonnet 5.5;
///  * the assistant's content blocks (including thinking blocks) are sent back unchanged with
///    tool results; content before a mid-output `fallback` marker is cleaned per the docs;
///  * `stop_reason: "refusal"` is handled before reading content.
/// Non-streaming: voice replies are short and the glasses show the full reply at once.
library;

import 'package:http/http.dart' as http;

import '../engines.dart';
import 'http_util.dart';
import 'llm.dart';

const String anthropicBaseUrl = 'https://api.anthropic.com';
const String anthropicVersion = '2023-06-01';
const String fallbackBeta = 'server-side-fallback-2026-07-01';

/// Default for voice: Claude Haiku 5.5 at low effort. It is the fastest, cheapest current
/// Claude model; with adaptive thinking at `low` it often skips thinking on simple spoken
/// questions, which keeps time-to-answer on the glasses short, and it handles the glasses
/// tools well. Users who want deeper answers can pick Sonnet 5.5 or Opus 5.5.
const String defaultClaudeModel = 'claude-haiku-5-5';

class ClaudeModel {
  const ClaudeModel(this.id, this.label, {this.effort = true, this.sampling = false, this.fallback = false});
  final String id;
  final String label;
  final bool effort;
  final bool sampling;
  final bool fallback;
}

/// Current Claude models offered in the picker (2026-10).
const List<ClaudeModel> claudeModels = [
  ClaudeModel('claude-haiku-5-5', 'Haiku 5.5 — fastest, cheapest (default for voice)'),
  ClaudeModel('claude-sonnet-5-5', 'Sonnet 5.5 — fast and capable', fallback: true),
  ClaudeModel('claude-opus-5-5', 'Opus 5.5 — most capable Opus', fallback: true),
  ClaudeModel('claude-fable-5-1', 'Fable 5.1 — most capable, slowest, priciest', fallback: true),
  ClaudeModel('claude-opus-5', 'Opus 5', fallback: true),
  ClaudeModel('claude-sonnet-5', 'Sonnet 5'),
  ClaudeModel('claude-haiku-4-5', 'Haiku 4.5 (previous generation)', effort: false, sampling: true),
];

ClaudeModel claudeCaps(String id) {
  for (final m in claudeModels) {
    if (m.id == id) return m;
  }
  // Unknown id (e.g. from the models list): infer conservatively.
  final old = RegExp(r'claude-(3|[a-z]+-4-[0-6]\b|[a-z]+-4-[0-6]-|instant)').hasMatch(id) || id.contains('haiku-4-5');
  return ClaudeModel(id, id,
      effort: !(id.contains('haiku-4') || id.contains('-4-5') || id.contains('claude-3')),
      sampling: old,
      fallback: id.startsWith('claude-fable-5') || id.startsWith('claude-opus-5'));
}

class AnthropicEngine extends LlmEngine {
  AnthropicEngine({
    required this.apiKey,
    required this.model,
    String? baseUrl,
    http.Client? client,
    Sleep? sleep,
  })  : baseUrl = (baseUrl == null || baseUrl.trim().isEmpty) ? anthropicBaseUrl : baseUrl.trim(),
        _http = HttpJson(client ?? http.Client(), provider: 'Claude', sleep: sleep);

  final String apiKey;
  final String model;
  final String baseUrl;
  final HttpJson _http;

  @override
  EngineCaps get caps => const EngineCaps(toolCalling: true, streaming: false, offline: false);

  Map<String, String> headers({bool beta = false}) => {
        'x-api-key': apiKey,
        'anthropic-version': anthropicVersion,
        if (beta) 'anthropic-beta': fallbackBeta,
      };

  /// The JSON body for [r] (snapshot-tested).
  Map<String, Object?> buildBody(LlmRequest r) {
    final caps = claudeCaps(model);
    return {
      'model': model,
      'max_tokens': r.maxTokens,
      if (r.system.isNotEmpty) 'system': r.system,
      'messages': [for (final m in r.messages) _message(m)],
      if (r.tools.isNotEmpty)
        'tools': [
          for (final t in r.tools) {'name': t.name, 'description': t.description, 'input_schema': t.schema}
        ],
      if (caps.effort && r.effort != null) 'output_config': {'effort': r.effort},
      if (caps.sampling && r.temperature != null) 'temperature': r.temperature,
      if (caps.fallback) 'fallbacks': 'default',
    };
  }

  Map<String, Object?> _message(ChatTurn m) {
    switch (m.role) {
      case TurnRole.user:
        return {'role': 'user', 'content': m.text};
      case TurnRole.assistant:
        final raw = m.raw;
        if (raw is List) return {'role': 'assistant', 'content': raw};
        return {
          'role': 'assistant',
          'content': [
            if (m.text.isNotEmpty) {'type': 'text', 'text': m.text},
            for (final c in m.toolCalls) {'type': 'tool_use', 'id': c.id, 'name': c.name, 'input': c.args},
          ],
        };
      case TurnRole.toolResults:
        return {
          'role': 'user',
          'content': [
            for (final r in m.results)
              {
                'type': 'tool_result',
                'tool_use_id': r.callId,
                'content': r.content,
                if (r.isError) 'is_error': true,
              }
          ],
        };
    }
  }

  @override
  Future<LlmResponse> complete(LlmRequest request) async {
    final body = buildBody(request);
    final j = await _http.postJson(Uri.parse('$baseUrl/v1/messages'), headers(beta: body.containsKey('fallbacks')), body);
    return parseOrFail('Claude', () => parseResponse(j));
  }

  /// Parse a Messages API reply.
  static LlmResponse parseResponse(Map<String, Object?> j) {
    final stop = (j['stop_reason'] ?? '').toString();
    final modelUsed = (j['model'] ?? '').toString();
    final content = [for (final b in (j['content'] as List? ?? const [])) (b as Map).cast<String, Object?>()];
    if (stop == 'refusal') {
      return LlmResponse(text: "Sorry, I can't help with that.", stopReason: stop, model: modelUsed, refused: true);
    }
    final text = content.where((b) => b['type'] == 'text').map((b) => b['text'].toString()).join(' ').trim();
    final calls = [
      for (final b in content)
        if (b['type'] == 'tool_use')
          ToolCall(b['id'].toString(), b['name'].toString(), ((b['input'] as Map?) ?? const {}).cast<String, Object?>())
    ];
    return LlmResponse(text: text, toolCalls: calls, stopReason: stop, model: modelUsed, raw: echoContent(content));
  }

  /// Content to send back on the next turn. After a mid-output fallback, thinking /
  /// redacted_thinking / tool_use blocks before the last `fallback` marker are dropped (and
  /// the marker itself); everything else is echoed unchanged.
  static List<Map<String, Object?>> echoContent(List<Map<String, Object?>> content) {
    final last = content.lastIndexWhere((b) => b['type'] == 'fallback');
    if (last < 0) return content;
    const drop = {'thinking', 'redacted_thinking', 'tool_use'};
    return [
      for (var i = 0; i < content.length; i++)
        if (content[i]['type'] != 'fallback' && !(i < last && drop.contains(content[i]['type']))) content[i]
    ];
  }

  @override
  Future<List<ModelInfo>> listModels() async {
    final j = await _http.getJson(Uri.parse('$baseUrl/v1/models?limit=100'), headers());
    return parseOrFail('Claude', () => [
          for (final m in (j['data'] as List? ?? const []))
            ModelInfo((m as Map)['id'].toString(), (m['display_name'] ?? '').toString())
        ]);
  }
}
