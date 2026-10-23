/// Google Gemini (Generative Language API):
///   POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
///   GET  .../v1beta/models        header x-goog-api-key
///
/// Function calling via `functionDeclarations`. The model's `content` is echoed back
/// unchanged on the next turn (it can carry thought signatures that must be returned).
library;

import 'package:http/http.dart' as http;

import '../engines.dart';
import 'http_util.dart';
import 'llm.dart';

const String geminiBaseUrl = 'https://generativelanguage.googleapis.com/v1beta';
const String defaultGeminiModel = 'gemini-2.5-flash';

class GeminiEngine extends LlmEngine {
  GeminiEngine({required this.apiKey, required this.model, String? baseUrl, http.Client? client, Sleep? sleep})
      : baseUrl = (baseUrl == null || baseUrl.trim().isEmpty) ? geminiBaseUrl : baseUrl.trim(),
        _http = HttpJson(client ?? http.Client(), provider: 'Gemini', sleep: sleep);

  final String apiKey;
  final String model;
  final String baseUrl;
  final HttpJson _http;

  @override
  EngineCaps get caps => const EngineCaps(toolCalling: true);

  Map<String, String> get headers => {'x-goog-api-key': apiKey};

  String get _modelPath => model.startsWith('models/') ? model : 'models/$model';

  /// Gemini's schema dialect is an OpenAPI subset: drop keys it rejects.
  static Object? _schema(Object? s) {
    if (s is Map) {
      return {
        for (final e in s.entries)
          if (!const {'additionalProperties', '\$schema', 'default'}.contains(e.key)) e.key.toString(): _schema(e.value)
      };
    }
    if (s is List) return s.map(_schema).toList();
    return s;
  }

  Map<String, Object?> buildBody(LlmRequest r) {
    final names = <String, String>{};
    for (final m in r.messages) {
      for (final c in m.toolCalls) {
        names[c.id] = c.name;
      }
    }
    return {
      if (r.system.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': r.system}
          ]
        },
      'contents': [for (final m in r.messages) _content(m)],
      if (r.tools.isNotEmpty)
        'tools': [
          {
            'functionDeclarations': [
              for (final t in r.tools)
                {'name': t.name, 'description': t.description, if (t.hasParams) 'parameters': _schema(t.schema)}
            ]
          }
        ],
      'generationConfig': {
        'maxOutputTokens': r.maxTokens,
        if (r.temperature != null) 'temperature': r.temperature,
      },
    };
  }

  Map<String, Object?> _content(ChatTurn m) {
    switch (m.role) {
      case TurnRole.user:
        return {
          'role': 'user',
          'parts': [
            {'text': m.text}
          ]
        };
      case TurnRole.assistant:
        final raw = m.raw;
        if (raw is Map) return raw.cast<String, Object?>();
        return {
          'role': 'model',
          'parts': [
            if (m.text.isNotEmpty) {'text': m.text},
            for (final c in m.toolCalls)
              {
                'functionCall': {'name': c.name, 'args': c.args}
              },
          ]
        };
      case TurnRole.toolResults:
        return {
          'role': 'user',
          'parts': [
            for (final r in m.results)
              {
                'functionResponse': {
                  'name': r.name,
                  'response': r.isError ? {'error': r.content} : {'content': r.content},
                }
              }
          ]
        };
    }
  }

  @override
  Future<LlmResponse> complete(LlmRequest request) async {
    final j = await _http.postJson(Uri.parse('$baseUrl/$_modelPath:generateContent'), headers, buildBody(request));
    return parseOrFail('Gemini', () => parseResponse(j, model));
  }

  static LlmResponse parseResponse(Map<String, Object?> j, [String model = '']) {
    final block = ((j['promptFeedback'] as Map?) ?? const {})['blockReason'];
    final cands = j['candidates'] as List? ?? const [];
    if (cands.isEmpty) {
      if (block != null) {
        return LlmResponse(text: "Sorry, I can't help with that.", stopReason: block.toString(), refused: true, model: model);
      }
      throw AiError('Gemini: reply had no candidates');
    }
    final cand = (cands.first as Map).cast<String, Object?>();
    final finish = (cand['finishReason'] ?? '').toString();
    final content = ((cand['content'] as Map?) ?? const {}).cast<String, Object?>();
    final parts = [for (final p in (content['parts'] as List? ?? const [])) (p as Map).cast<String, Object?>()];
    final text = parts.where((p) => p['text'] != null && p['thought'] != true).map((p) => p['text']).join('').trim();
    final calls = <ToolCall>[];
    for (final p in parts) {
      final fc = p['functionCall'];
      if (fc is Map) {
        calls.add(ToolCall((fc['id'] ?? 'gemini_${calls.length}').toString(), fc['name'].toString(),
            ((fc['args'] as Map?) ?? const {}).cast<String, Object?>()));
      }
    }
    final refused = const {'SAFETY', 'PROHIBITED_CONTENT', 'BLOCKLIST', 'SPII'}.contains(finish) && text.isEmpty;
    return LlmResponse(
      text: refused ? "Sorry, I can't help with that." : text,
      toolCalls: calls,
      stopReason: finish,
      model: (j['modelVersion'] ?? model).toString(),
      raw: content.isEmpty ? null : {...content, 'role': 'model'},
      refused: refused,
    );
  }

  @override
  Future<List<ModelInfo>> listModels() async {
    final j = await _http.getJson(Uri.parse('$baseUrl/models?pageSize=200'), headers);
    return parseOrFail('Gemini', () => [
      for (final m in (j['models'] as List? ?? const []))
        if (m is Map && ((m['supportedGenerationMethods'] as List?) ?? const []).contains('generateContent'))
          ModelInfo(m['name'].toString().replaceFirst('models/', ''), (m['displayName'] ?? '').toString())
    ]);
  }
}
