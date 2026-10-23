/// On-device AI: owns the model store, the (single) loaded LLM, and the speech models.
///
///  * The LLM is loaded lazily on the first request and unloaded after [idleUnload] without
///    use, on Android memory pressure, or when another model is chosen. One model at a time.
///  * Generation runs in llamadart's worker isolate; [LocalAi] only coordinates it.
///  * [stopForBackground] cancels a generation when the app is backgrounded, unless a
///    conversation (glasses Even AI turn, live translate) is active.
///  * [lastRun] keeps tokens/s, prompt speed and load time for the Developer view.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../engines.dart';
import '../providers/llm.dart';
import 'llm_runtime.dart';
import 'local_catalog.dart';
import 'local_stt.dart';
import 'model_store.dart';

class LocalRunStats {
  const LocalRunStats({required this.model, required this.result, this.loadTime});
  final String model;
  final LocalGenResult result;
  final Duration? loadTime;

  String describe() {
    final r = result;
    return '$model: ${r.completionTokens} tokens at ${r.tokensPerSecond.toStringAsFixed(1)} tok/s, '
        'prompt ${r.promptTokens} tokens at ${r.promptTokensPerSecond.toStringAsFixed(0)} tok/s, '
        'first token after ${r.timeToFirstToken?.inMilliseconds ?? '-'} ms'
        '${loadTime == null ? '' : ', model load ${loadTime!.inMilliseconds} ms'}';
  }
}

class LocalAi extends ChangeNotifier {
  LocalAi({
    required this.store,
    LocalLlmRuntime Function()? runtime,
    Future<int?> Function()? ram,
    this.idleUnload = const Duration(minutes: 5),
  })  : _newRuntime = runtime ?? LlamaDartRuntime.new,
        _ram = ram ?? deviceRamBytes;

  final LocalModelStore store;
  final LocalLlmRuntime Function() _newRuntime;
  final Future<int?> Function() _ram;
  Duration idleUnload;

  LocalLlmRuntime? _rt;
  String? _loadedId;
  Future<void>? _loading;
  Timer? _idle;
  Duration? _pendingLoadTime;

  LocalRunStats? lastRun;
  String? lastError;

  String? get loadedModelId => _loadedId;
  bool get generating => _rt?.generating ?? false;
  bool get loading => _loading != null;

  Future<int?> deviceRam() => _ram();

  /// Readable reason [m] cannot run here (not downloaded, too little RAM), or null.
  Future<String?> problem(LocalModelSpec m) async {
    if (!await store.isReady(m.id)) return '${m.label} is not downloaded yet (AI models → On this phone)';
    return ramProblem(LocalModel(id: m.id, label: m.label, sizeBytes: m.sizeBytes, minRamBytes: m.minRamBytes), ram: _ram);
  }

  /// Load [m] if it is not the loaded model (serialised; one model at a time).
  Future<void> ensureLoaded(LocalModelSpec m, {int contextSize = 2048}) async {
    while (_loading != null) {
      await _loading;
    }
    if (_loadedId == m.id && _rt?.loadedPath != null) return;
    final p = await problem(m);
    if (p != null) throw EngineUnavailable(p);
    final c = Completer<void>();
    _loading = c.future;
    notifyListeners();
    final sw = Stopwatch()..start();
    try {
      final rt = _rt ??= _newRuntime();
      await rt.load(await store.pathOf(m.id, m.main), contextSize: contextSize);
      _loadedId = m.id;
      _pendingLoadTime = sw.elapsed;
      lastError = null;
    } catch (e) {
      _loadedId = null;
      lastError = '$e';
      rethrow;
    } finally {
      _loading = null;
      c.complete();
      notifyListeners();
    }
  }

  /// One generation at a time: a request for another model (e.g. translation on model A
  /// while the assistant runs model B) waits for the running one instead of loading over it
  /// (which would tear the running generation down). [abandoned]: the caller gave up while
  /// waiting / loading (first-token timeout): the generation is then not started.
  Future<LocalGenResult> generate(LocalModelSpec m, LocalGenRequest r, {bool Function()? abandoned, void Function()? onStart}) async {
    final prev = _queue;
    final mine = Completer<void>();
    _queue = mine.future;
    _busy++;
    try {
      if (prev != null) await prev;
      if (abandoned?.call() ?? false) throw AiError('cancelled before it started');
      await ensureLoaded(m);
      if (abandoned?.call() ?? false) throw AiError('cancelled before it started');
      _idle?.cancel();
      notifyListeners();
      onStart?.call();
      final res = await _rt!.generate(r);
      lastRun = LocalRunStats(model: m.label, result: res, loadTime: _pendingLoadTime);
      _pendingLoadTime = null;
      return res;
    } finally {
      _busy--;
      if (identical(_queue, mine.future)) _queue = null;
      mine.complete();
      _armIdle();
      notifyListeners();
    }
  }

  /// The last queued generation (null = none running or waiting).
  Future<void>? _queue;
  int _busy = 0;

  void cancel() => _rt?.cancel();

  void _armIdle() {
    _idle?.cancel();
    if (idleUnload > Duration.zero) _idle = Timer(idleUnload, () => unload(reason: 'idle'));
  }

  Future<void> unload({String reason = ''}) async {
    _idle?.cancel();
    final rt = _rt;
    if (rt == null || rt.generating || _loading != null || _busy > 0) return;
    _loadedId = null;
    await rt.unload();
    notifyListeners();
  }

  /// The model [id] is being deleted: stop a generation that uses it, then unload it (an
  /// [unload] alone is skipped while generating, which kept a deleted model in RAM).
  Future<void> release(String id) async {
    if (_loadedId != id) return;
    if (generating) cancel();
    final q = _queue;
    if (q != null) await q;
    if (_loadedId == id) await unload(reason: 'deleted');
  }

  /// Android onTrimMemory / Flutter didHaveMemoryPressure: free the model unless it is busy.
  Future<void> onMemoryPressure() => unload(reason: 'low memory');

  /// The app went to the background: stop a generation nobody is waiting for. Returns true
  /// if one was stopped.
  bool stopForBackground({required bool conversationActive}) {
    if (!generating || conversationActive) return false;
    cancel();
    return true;
  }

  // ── speech ─────────────────────────────────────────────────────────────────────────────
  /// The offline speech engine for model [id], or null if it is not downloaded.
  Future<SttEngine?> stt(String id) async {
    final m = await store.spec(id) ?? catalogById(id);
    if (m == null || m.kind != LocalKind.stt || !await store.isReady(m.id)) return null;
    String path(String suffix) => m.files.firstWhere((f) => f.name.endsWith(suffix)).name;
    final dir = await store.dirOf(m.id);
    return SherpaWhisperStt(
      WhisperFiles(encoder: '$dir/${path('encoder.int8.onnx')}', decoder: '$dir/${path('decoder.int8.onnx')}', tokens: '$dir/${path('tokens.txt')}'),
      label: m.label,
    );
  }

  @override
  void dispose() {
    _idle?.cancel();
    unawaited(_rt?.dispose());
    super.dispose();
  }
}

// ── the LlmEngine ───────────────────────────────────────────────────────────────────────
/// Glasses tools offered to a local model when tools are on: a short list keeps the prompt
/// small (phones process about 20–150 prompt tokens/s, and every tool costs ~40 tokens).
const Set<String> localToolNames = {
  'add_task', 'list_tasks', 'set_task_done', 'add_calendar_event', 'list_calendar', //
  'get_weather', 'set_brightness', 'set_silent_mode', 'close_display',
};

/// Compact assistant prompt for small models (the cloud prompt is ~110 tokens and talks
/// about tools the local model may not have).
String localSystemPrompt({required bool tools}) =>
    'You are a voice assistant on smart glasses. Answer in one or two short sentences, plain text, '
    'no lists, markdown or emoji. If you are not sure, say so briefly.'
    '${tools ? ' Use a tool only when the user asks to change tasks, calendar, brightness or silent mode.' : ''}';

class LocalLlmEngine extends LlmEngine {
  LocalLlmEngine(
    this.ai,
    this.model, {
    this.tools = false,
    this.maxTokensCap = 200,
    this.firstTokenTimeout,
    this.temperature = 0.4,
  });

  final LocalAi ai;
  final LocalModelSpec model;

  /// Offer (grammar-constrained) tool calls. Only honoured for [LocalModelSpec.toolsCapable]
  /// or custom models; small models misuse tools, so this is off by default.
  final bool tools;

  /// Replies are shown on the glasses: cap the length (and the wait).
  final int maxTokensCap;

  /// No first token within this time → cancel and throw (so a cloud fallback answers).
  final Duration? firstTokenTimeout;
  final double temperature;

  bool get _toolsOn => tools && (model.toolsCapable || model.custom);

  @override
  EngineCaps get caps => EngineCaps(offline: true, streaming: true, toolCalling: _toolsOn);

  /// [LlmRequest] → local chat messages (tool results become `tool` turns).
  static List<LocalMessage> messagesFor(LlmRequest r) => [
        LocalMessage(LocalRole.system, r.system),
        for (final t in r.messages)
          ...switch (t.role) {
            TurnRole.user => [LocalMessage(LocalRole.user, t.text)],
            TurnRole.assistant => [LocalMessage(LocalRole.assistant, t.text, toolCalls: t.toolCalls)],
            TurnRole.toolResults => [
                for (final x in t.results) LocalMessage(LocalRole.tool, x.content, toolCallId: x.callId, toolName: x.name)
              ],
          },
      ];

  static final RegExp _think = RegExp(r'<think>[\s\S]*?(</think>|$)');

  @override
  Future<LlmResponse> complete(LlmRequest request) async {
    final offered = _toolsOn ? request.tools.where((t) => localToolNames.contains(t.name)).toList() : const <ToolSpec>[];
    var gotToken = false;
    var tooSlow = false;
    var started = false;
    Timer? slow;
    final timeout = firstTokenTimeout;
    LocalGenResult r;
    final timedOut = Completer<LocalGenResult?>();
    try {
      final gen = ai.generate(
        model,
        LocalGenRequest(
          messages: messagesFor(request),
          tools: offered,
          maxTokens: request.maxTokens.clamp(16, maxTokensCap),
          temperature: request.temperature ?? temperature,
          onDelta: (d) {
            gotToken = true;
            if (!tooSlow) request.onDelta?.call(d);
          },
        ),
        abandoned: () => tooSlow,
        onStart: () => started = true,
      );
      if (timeout == null) {
        r = await gen;
      } else {
        // The timeout counts from the request, so it also covers waiting for another
        // generation and loading the model: the fallback answers on time either way.
        slow = Timer(timeout, () {
          if (!gotToken) {
            tooSlow = true;
            // Only stop OUR generation; while we still wait in the queue, the running one
            // belongs to another request.
            if (started) ai.cancel();
            if (!timedOut.isCompleted) timedOut.complete(null);
          }
        });
        final first = await Future.any<LocalGenResult?>([gen, timedOut.future]);
        if (first == null) {
          unawaited(gen.then((_) {}, onError: (Object _) {}));
          throw AiError('The on-device model was too slow (no answer after ${timeout.inSeconds} s)', retryable: true);
        }
        r = first;
      }
    } on AiError {
      rethrow;
    } catch (e) {
      throw AiError('On-device model failed: $e');
    } finally {
      slow?.cancel();
    }
    if (tooSlow && r.text.trim().isEmpty && r.toolCalls.isEmpty) {
      throw AiError('The on-device model was too slow (no answer after ${timeout!.inSeconds} s)', retryable: true);
    }
    final text = r.text.replaceAll(_think, '').trim();
    return LlmResponse(
      text: text,
      toolCalls: r.toolCalls,
      stopReason: r.finishReason,
      model: model.label,
    );
  }

  @override
  Future<List<ModelInfo>> listModels() async => [for (final m in await ai.store.specs(kind: LocalKind.llm)) ModelInfo(m.id, m.label)];

  @override
  Future<String> testConnection() async {
    final sw = Stopwatch()..start();
    final r = await complete(LlmRequest(system: 'Reply with the single word OK.', messages: [ChatTurn.user('Reply OK.')], maxTokens: 8));
    return 'OK — ${model.label} replied "${r.text.split('\n').first}" in ${sw.elapsedMilliseconds} ms (including loading)';
  }
}
