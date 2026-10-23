/// The on-device LLM runtime seam. [LlamaDartRuntime] is the real one: llama.cpp through
/// llamadart (MIT), which runs inference in its own worker isolate, so generation never
/// blocks the UI isolate. Tests use a fake implementing [LocalLlmRuntime].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart' as ld;

import '../providers/llm.dart';

enum LocalRole { system, user, assistant, tool }

class LocalMessage {
  const LocalMessage(this.role, this.text, {this.toolCalls = const [], this.toolCallId, this.toolName});
  final LocalRole role;
  final String text;
  final List<ToolCall> toolCalls;
  final String? toolCallId;
  final String? toolName;
}

class LocalGenRequest {
  const LocalGenRequest({
    required this.messages,
    this.tools = const [],
    this.maxTokens = 200,
    this.temperature = 0.4,
    this.onDelta,
  });
  final List<LocalMessage> messages;
  final List<ToolSpec> tools;
  final int maxTokens;
  final double temperature;
  final void Function(String delta)? onDelta;
}

class LocalGenResult {
  const LocalGenResult({
    required this.text,
    this.toolCalls = const [],
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.timeToFirstToken,
    this.duration = Duration.zero,
    this.finishReason = 'stop',
  });
  final String text;
  final List<ToolCall> toolCalls;
  final int promptTokens;
  final int completionTokens;
  final Duration? timeToFirstToken;
  final Duration duration;
  final String finishReason;

  /// Decode speed (tokens after the first one, over the time after the first one).
  double get tokensPerSecond {
    final gen = duration - (timeToFirstToken ?? Duration.zero);
    return gen.inMicroseconds <= 0 ? 0 : completionTokens / (gen.inMicroseconds / 1e6);
  }

  double get promptTokensPerSecond {
    final t = timeToFirstToken;
    return t == null || t.inMicroseconds <= 0 ? 0 : promptTokens / (t.inMicroseconds / 1e6);
  }
}

abstract class LocalLlmRuntime {
  /// Path of the loaded model, or null.
  String? get loadedPath;
  bool get generating;

  Future<void> load(String path, {int contextSize = 2048, int threads = 0});
  Future<void> unload();

  /// One generation. Deltas go to [LocalGenRequest.onDelta] as they are produced.
  Future<LocalGenResult> generate(LocalGenRequest request);

  /// Stop the running generation (it returns with what it has so far).
  void cancel();

  Future<void> dispose();
}

/// Threads for llama.cpp: the big cores. Phones have 8 cores (2–4 big); more threads than
/// big cores makes generation slower, not faster.
int defaultThreads([int? cores]) {
  final n = cores ?? Platform.numberOfProcessors;
  if (n >= 8) return 4;
  return (n / 2).ceil().clamp(1, 4);
}

/// JSON Schema (the glasses tools' simple subset) → llamadart ToolParam. llamadart's
/// grammar then constrains tool-call arguments to this shape (GBNF, lazily activated when
/// the model starts a tool call, so plain answers still stream freely).
ld.ToolDefinition toolDefinition(ToolSpec t) {
  final props = (t.schema['properties'] as Map?)?.cast<String, Object?>() ?? const {};
  final req = {for (final r in (t.schema['required'] as List? ?? const [])) r.toString()};
  ld.ToolParam param(String name, Map<String, Object?> s) {
    final d = s['description']?.toString();
    final r = req.contains(name);
    final e = s['enum'];
    if (e is List) return ld.ToolParam.enumType(name, values: [for (final v in e) '$v'], description: d, required: r);
    return switch (s['type']) {
      'integer' => ld.ToolParam.integer(name, description: d, required: r),
      'number' => ld.ToolParam.number(name, description: d, required: r),
      'boolean' => ld.ToolParam.boolean(name, description: d, required: r),
      _ => ld.ToolParam.string(name, description: d, required: r),
    };
  }

  return ld.ToolDefinition(
    name: t.name,
    description: t.description,
    parameters: [for (final e in props.entries) param(e.key, (e.value as Map?)?.cast<String, Object?>() ?? const {})],
  );
}

class LlamaDartRuntime implements LocalLlmRuntime {
  ld.LlamaEngine? _engine;
  String? _path;
  bool _generating = false;

  @override
  String? get loadedPath => _path;
  @override
  bool get generating => _generating;

  @override
  Future<void> load(String path, {int contextSize = 2048, int threads = 0}) async {
    if (_path == path && _engine != null) return;
    await unload();
    final t = threads > 0 ? threads : defaultThreads();
    final e = ld.LlamaEngine(ld.LlamaBackend());
    try {
      await e.setModel(
        ld.LlamaModel(ld.ModelSource.path(path)),
        params: ld.ModelParams(
          contextSize: contextSize,
          numberOfThreads: t,
          numberOfThreadsBatch: t,
          device: ld.ComputeDevice.cpu,
        ),
      );
    } on ld.LlamaException catch (err) {
      unawaited(e.dispose());
      throw AiError('Could not load the on-device model: ${err.message}');
    } on ArgumentError catch (err) {
      // No native library for this ABI (32-bit ARM) or it failed to load.
      unawaited(e.dispose());
      throw AiError('The on-device AI runtime is not available on this phone ($err)');
    }
    _engine = e;
    _path = path;
  }

  @override
  Future<void> unload() async {
    final e = _engine;
    _engine = null;
    _path = null;
    if (e != null) {
      e.cancelGeneration();
      await e.dispose();
    }
  }

  static ld.LlamaChatMessage _msg(LocalMessage m) {
    switch (m.role) {
      case LocalRole.system:
        return ld.LlamaChatMessage.fromText(role: ld.LlamaChatRole.system, text: m.text);
      case LocalRole.user:
        return ld.LlamaChatMessage.fromText(role: ld.LlamaChatRole.user, text: m.text);
      case LocalRole.assistant:
        if (m.toolCalls.isEmpty) return ld.LlamaChatMessage.fromText(role: ld.LlamaChatRole.assistant, text: m.text);
        return ld.LlamaChatMessage.withContent(role: ld.LlamaChatRole.assistant, content: [
          if (m.text.isNotEmpty) ld.LlamaTextContent(m.text),
          for (final c in m.toolCalls)
            ld.LlamaToolCallContent(id: c.id, name: c.name, arguments: c.args.cast<String, dynamic>(), rawJson: _json(c.args)),
        ]);
      case LocalRole.tool:
        return ld.LlamaChatMessage.withContent(role: ld.LlamaChatRole.tool, content: [
          ld.LlamaToolResultContent(id: m.toolCallId, name: m.toolName ?? 'tool', result: m.text),
        ]);
    }
  }

  static String _json(Map<String, Object?> a) {
    try {
      return jsonEncode(a);
    } catch (_) {
      return '{}';
    }
  }

  @override
  Future<LocalGenResult> generate(LocalGenRequest r) async {
    final e = _engine;
    if (e == null) throw AiError('The on-device model is not loaded');
    if (_generating) throw AiError('The on-device model is busy with another request');
    _generating = true;
    final sw = Stopwatch()..start();
    Duration? first;
    final text = StringBuffer();
    final calls = <ToolCall>[];
    ld.LlamaGenerationUsage? usage;
    var finish = 'stop';
    try {
      final stream = e.create(
        [for (final m in r.messages) _msg(m)],
        params: ld.GenerationParams(maxTokens: r.maxTokens, temp: r.temperature, topP: 0.9, topK: 40, penalty: 1.1),
        tools: r.tools.isEmpty ? null : [for (final t in r.tools) toolDefinition(t)],
        toolChoice: r.tools.isEmpty ? null : ld.ToolChoice.auto,
        enableThinking: false,
      );
      await for (final c in stream) {
        final d = c.text;
        if (d.isNotEmpty) {
          first ??= sw.elapsed;
          text.write(d);
          r.onDelta?.call(d);
        }
        for (final t in c.toolCalls) {
          final f = t.function;
          if (f?.name == null) continue;
          calls.add(ToolCall(t.id ?? 'call_${calls.length}', f!.name!, _args(f.arguments)));
        }
        if (c.usage != null) usage = c.usage;
        final fr = c.finishReason;
        if (fr != null) finish = fr.wireValue;
      }
    } on ld.LlamaException catch (err) {
      if (text.isEmpty) throw AiError('On-device model failed: ${err.message}');
      finish = 'error';
    } finally {
      _generating = false;
    }
    return LocalGenResult(
      text: text.toString(),
      toolCalls: calls,
      promptTokens: usage?.promptTokens ?? 0,
      completionTokens: usage?.completionTokens ?? 0,
      timeToFirstToken: usage?.timeToFirstToken ?? first,
      duration: usage?.duration ?? sw.elapsed,
      finishReason: finish,
    );
  }

  static Map<String, Object?> _args(String? raw) {
    if (raw == null || raw.trim().isEmpty) return {};
    try {
      final v = jsonDecode(raw);
      return v is Map ? v.cast<String, Object?>() : {'__invalid_json__': raw};
    } catch (_) {
      return {'__invalid_json__': raw};
    }
  }

  @override
  void cancel() => _engine?.cancelGeneration();

  @override
  Future<void> dispose() => unload();
}
