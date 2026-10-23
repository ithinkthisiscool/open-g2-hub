/// AiHub: the app-level owner of the AI stack. It follows the HubController's connection
/// (no extra setup step: once a provider key is saved, the glasses' wake gesture just works),
/// owns the AI settings / keys / history, the Even AI loop and live translate, and restores
/// AI-related glasses state after every reconnect (a running glasses-mic conversation
/// translate is re-armed and the Translate screen re-opened).
library;

import 'dart:async';

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../ai/assistant/tools.dart';
import '../ai/audio/glasses_mic.dart';
import '../ai/audio/silero_vad.dart';
import '../ai/audio/vad.dart' show Segmenter, UtteranceSegmenter;
import '../ai/config/ai_config.dart';
import '../ai/config/ai_store.dart';
import '../ai/config/secret_store.dart';
import '../ai/engine_factory.dart';
import '../ai/local/local_ai.dart';
import '../ai/local/local_catalog.dart';
import '../ai/local/model_store.dart';
import '../ai/providers/http_util.dart' show badEndpoint;
import '../protocol/even_ai.dart' as ai;
import '../protocol/evenhub.dart' as eh;
import '../protocol/translate.dart' as tr;
import 'even_ai.dart';
import 'even_ai_tools_host.dart';
import 'features.dart';
import 'glasses_session.dart';
import 'hub_controller.dart';
import 'translate_live.dart';
import 'translate_live_phone_mic.dart';

/// EvenAiLink over a live G2Session (+ the 0x6402 mic subscription).
class SessionEvenAiLink implements EvenAiLink {
  SessionEvenAiLink(this.session, this.mic);
  final G2Session session;
  @override
  final MicLink mic;
  @override
  Stream<RxFrame> get frames => session.frames;
  @override
  int nextMagic() => session.nextMagic();
  @override
  Future<void> send(int sid, Uint8List payload) => session.send(sid, payload);
}

/// The glasses' Translate screen through G2Features (keeps its open/close bookkeeping).
class FeaturesTranslateDisplay implements TranslateDisplay {
  FeaturesTranslateDisplay(this.features);
  final G2Features Function() features;
  @override
  bool get isOpen => features().currentApp == 'translate';
  @override
  Future<void> show(String src, String dst, String original, String translated) async {
    final f = features();
    if (f.currentApp != 'translate') {
      final r = await f.translateOpen(src, dst);
      if (!r.ok) throw StateError(r.message);
    }
    final r = await f.translateText(original, translated);
    if (!r.ok) throw StateError(r.message);
  }

  @override
  Future<void> close() async {
    if (features().currentApp == 'translate') await features().closeApp();
  }
}

/// The app-private directory for on-device model files (never in the APK, not backed up).
Future<Directory> localModelsDir() async => Directory('${(await getApplicationSupportDirectory()).path}/models');

class AiHub extends ChangeNotifier with WidgetsBindingObserver {
  AiHub(this.hub, {AiStore? store, SecretStore? secrets, EngineFactory? engines, LocalAi? local, SileroVad? vad})
      : store = store ?? PrefsAiStore(),
        secrets = secrets ?? SecureSecretStore() {
    this.vad = vad ??
        SileroVad(
          modelPath: () => bundledSileroModel(() async => Directory('${(await getApplicationSupportDirectory()).path}/vad')),
          log: (m) => _log(m, LogLevel.warn),
        );
    this.local = engines?.local ?? local ?? LocalAi(store: LocalModelStore(root: localModelsDir));
    this.engines = engines ?? EngineFactory(this.secrets, local: this.local);
    this.local?.addListener(notifyListeners);
    live = LiveTranslator(
      stt: () => this.engines.speech(settings, onFallback: (m) => _log('Translate: $m', LogLevel.warn)),
      translation: () => this.engines.translation(settings, onFallback: (m) => _log('Translate: $m', LogLevel.warn)),
      display: _ConnectedDisplay(this),
      report: _log,
      idleStop: () => Duration(minutes: settings.liveIdleStopMin),
      segmenter: _segmenter,
    );
    live.addListener(notifyListeners);
  }

  final HubController hub;
  final AiStore store;
  final SecretStore secrets;
  late final EngineFactory engines;
  late final LiveTranslator live;

  /// Silero VAD (bundled model) for Even AI end-of-speech and translate segmentation.
  late final SileroVad vad;

  Future<UtteranceSegmenter> _segmenter() async =>
      settings.vadEngine == 'silero' ? vad.segmenter(settings.translateVad) : Segmenter();

  /// On-device models (lib/ai/local/); null only in tests that build without them.
  late final LocalAi? local;

  AiSettings settings = AiSettings.defaults();
  List<AiHistoryEntry> history = [];
  EvenAiController? evenAi;
  G2Session? _session;
  StreamSubscription<RxFrame>? _trSub;
  bool _loaded = false;

  /// Conversation translate to resume after a reconnect: (src, dst, source).
  (String, String, String)? _resume;

  /// Called by the sync engine (when wired) to push a changed glasses section.
  void Function(String section)? sync;

  bool get loaded => _loaded;

  void _log(String m, LogLevel l) => hub.log(m, l);

  // ── keys (only presence is cached; values stay in the keystore) ─────────────────────
  final Set<String> _keys = {};
  bool hasKey(String keyName) => _keys.contains(keyName);

  /// Re-read which keys exist (after a key was saved or removed).
  Future<void> refreshKeys() async {
    try {
      final all = await secrets.readAll();
      _keys
        ..clear()
        ..addAll(all.keys.where((k) => (all[k] ?? '').isNotEmpty));
    } catch (_) {/* keystore unavailable: treat as no keys */}
    notifyListeners();
  }

  /// What still needs setting up for the assistant / speech (null = ready).
  String? get assistantProblem {
    final p = settings.llmById(settings.assistantProfileId) ?? settings.llmProfiles.firstOrNull;
    if (p == null) return 'Add an AI model';
    return _llmProblem(p);
  }

  /// Cached readiness of on-device models (refreshed by [refreshLocal]).
  final Map<String, String?> _localProblems = {};

  /// Re-check which on-device models are downloaded and fit in RAM.
  Future<void> refreshLocal() async {
    final l = local;
    if (l == null) return;
    for (final m in await l.store.specs()) {
      _localProblems[m.id] = m.kind == LocalKind.llm ? await l.problem(m) : (await l.store.isReady(m.id) ? null : '${m.label} is not downloaded');
    }
    notifyListeners();
  }

  String? _localSttProblem(SttProfile p) {
    if (local == null) return 'On-device speech recognition is not available in this build';
    final id = p.model.isEmpty ? recommendStt(null).id : p.model;
    if (!_localProblems.containsKey(id)) return null; // not checked yet
    return _localProblems[id] == null ? null : 'On-device speech: download a speech model in AI models → On this phone';
  }

  String? _localLlmProblem(LlmProfile p) {
    if (local == null) return '${p.name}: on-device AI is not available in this build';
    if (p.model.isEmpty) return '${p.name}: choose a model in AI models → On this phone';
    if (!_localProblems.containsKey(p.model)) return null; // not checked yet
    return _localProblems[p.model];
  }

  String? _llmProblem(LlmProfile p) => switch (p.provider) {
        LlmProvider.local => _localLlmProblem(p),
        LlmProvider.anthropic when !hasKey(llmKeyName(p.id)) => '${p.name}: add your Anthropic API key',
        LlmProvider.gemini when !hasKey(llmKeyName(p.id)) => '${p.name}: add your Gemini API key',
        LlmProvider.openai when p.baseUrl.trim().isEmpty => '${p.name}: set the endpoint URL',
        LlmProvider.openai when badEndpoint(p.baseUrl) != null => '${p.name}: ${badEndpoint(p.baseUrl)}',
        _ => null,
      };

  String? get speechProblem {
    String? one(SttProfile? p) => p == null
        ? 'Add a speech-to-text profile'
        : switch (p.provider) {
            SttProvider.deepgram when !hasKey(sttKeyName(p.id)) => '${p.name}: add your Deepgram API key',
            SttProvider.whisper when p.baseUrl.trim().isEmpty => '${p.name}: set the Whisper endpoint URL',
            SttProvider.whisper when badEndpoint(p.baseUrl) != null => '${p.name}: ${badEndpoint(p.baseUrl)}',
            SttProvider.onDevice when _localSttProblem(p) != null => _localSttProblem(p),
            _ => null,
          };
    final main = one(settings.sttById(settings.sttProfileId) ?? settings.sttProfiles.firstOrNull);
    if (main == null) return null;
    final fb = settings.sttById(settings.sttFallbackProfileId);
    return fb != null && one(fb) == null ? null : main;
  }

  String? get translationProblem {
    if (settings.translationEngine == TranslationEngineKind.mlkit) return null;
    final p = settings.llmById(settings.translationProfileId) ?? settings.llmById(settings.assistantProfileId);
    return p == null ? 'Choose a translation model' : _llmProblem(p);
  }

  Future<void> load() async {
    registerSileroLicence();
    settings = await store.loadSettings();
    history = await store.loadHistory();
    await refreshKeys();
    _applyLocalSettings();
    WidgetsBinding.instance.addObserver(this);
    unawaited(refreshLocal().catchError((Object _) {}));
    _loaded = true;
    hub.addListener(_onHub);
    _onHub();
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    local?.removeListener(notifyListeners);
    hub.removeListener(_onHub);
    _detach();
    live.removeListener(notifyListeners);
    super.dispose();
  }

  // ── settings ────────────────────────────────────────────────────────────────────────────
  /// Apply + persist immediately (no "save" step anywhere in the UI).
  Future<void> update(void Function(AiSettings s) change) async {
    change(settings);
    _applyLocalSettings();
    notifyListeners();
    await store.saveSettings(settings);
  }

  Future<void> replaceSettings(AiSettings s) async {
    settings = s;
    _applyLocalSettings();
    notifyListeners();
    await store.saveSettings(settings);
  }

  void _applyLocalSettings() => local?.idleUnload = Duration(minutes: settings.localIdleUnloadMin);

  // ── on-device AI: lifecycle, memory, thermal ─────────────────────────────────────────
  /// A conversation the user is in right now: an Even AI turn from the glasses, or live
  /// translate. Background generation is allowed only for these.
  bool get conversationActive => (evenAi?.turnRunning ?? false) || live.running;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      if (local?.stopForBackground(conversationActive: conversationActive) ?? false) {
        _log('On-device AI: stopped generating because the app went to the background', LogLevel.info);
      }
    }
  }

  @override
  void didHaveMemoryPressure() {
    final l = local;
    if (l == null || l.loadedModelId == null) return;
    _log('On-device AI: low memory, unloading the model (it reloads on the next question)', LogLevel.warn);
    unawaited(l.onMemoryPressure());
  }

  /// Make (or update) the "On this phone" profile run [modelId]; returns it.
  Future<LlmProfile> useLocalModel(String modelId, {bool forAssistant = false, bool forTranslation = false}) async {
    var p = settings.localProfile;
    await update((s) {
      if (p == null) {
        p = LlmProfile.local(modelId);
        s.llmProfiles.add(p!);
      } else {
        p!.model = modelId;
      }
      if (forAssistant) s.assistantProfileId = p!.id;
      if (forTranslation) {
        s.translationEngine = TranslationEngineKind.llm;
        s.translationProfileId = p!.id;
      }
    });
    await refreshLocal();
    return p!;
  }

  void addHistory(AiHistoryEntry e) {
    history.add(e);
    if (history.length > PrefsAiStore.maxHistory) history.removeRange(0, history.length - PrefsAiStore.maxHistory);
    notifyListeners();
    store.saveHistory(history);
  }

  Future<void> clearHistory() async {
    history = [];
    notifyListeners();
    await store.saveHistory(history);
  }

  // ── connection following ─────────────────────────────────────────────────────────────
  void _onHub() {
    final s = hub.status == LinkStatus.connected && hub.features != null ? hub.session : null;
    if (identical(s, _session)) return;
    _detach();
    if (s != null) _attach(s);
  }

  void _attach(G2Session s) {
    _session = s;
    final g = hub.data.glasses;
    final mic = g == null ? _NoMic() : UniversalBleMicLink(rightId: g.rightId, leftId: g.leftId);
    evenAi = EvenAiController(
      SessionEvenAiLink(s, mic),
      AiDeps(
        settings: () => settings,
        engines: engines,
        saveSettings: () => store.saveSettings(settings),
        log: _log,
        addHistory: addHistory,
        vad: vad,
      ),
      tools: AssistantTools(HubToolHost(hub, sync: sync)),
      display: FeaturesTranslateDisplay(() => hub.features!),
      micBusy: () => live.running && live.sourceName == 'glasses',
    )..addListener(notifyListeners);
    _trSub = s.frames.where((f) => f.sid == tr.sid).listen(_onTranslateFrame);
    notifyListeners();
    // Reconnect restore: resume a glasses-mic conversation translate (phone-mic translate
    // keeps running across drops; its next line re-opens the Translate screen itself).
    final r = _resume;
    if (r != null && !live.running) {
      _resume = null;
      _log('Resuming live translate after reconnect (${r.$1}>${r.$2}, ${r.$3} mic)', LogLevel.info);
      unawaited(startLive(r.$1, r.$2, r.$3).catchError((Object e) {
        _log('Live translate could not resume: $e', LogLevel.warn);
      }));
    }
  }

  void _detach() {
    _trSub?.cancel();
    _trSub = null;
    final e = evenAi;
    evenAi = null;
    e?.removeListener(notifyListeners);
    e?.dispose();
    if (_session != null && live.running && (hub.data.handedOff || !hub.wantConnected)) {
      // Handed off to the Even app, or disconnected on purpose: the user gave the glasses up, and
      // the disconnect also stops the foreground service the phone mic needs in the background.
      _resume = null;
      unawaited(live.stop(
          reason: hub.data.handedOff ? 'glasses handed off to the Even app' : 'glasses disconnected'));
    } else if (_session != null && live.running && live.sourceName == 'glasses') {
      _resume = (live.src, live.dst, 'glasses');
      unawaited(live.stop(reason: 'glasses disconnected'));
    }
    _session = null;
  }

  void _onTranslateFrame(RxFrame f) {
    final m = tr.decode(f.payload);
    if (m['cmd'] == tr.cmdNotify && m['value'] == tr.tcmdClose) {
      if (onTranslateClosedOnGlasses(settings)) {
        store.saveSettings(settings);
        _log('Hands-free translate OFF: Translate was closed on the glasses, so the wake gesture opens Even AI again',
            LogLevel.info);
        notifyListeners();
      }
      if (live.running) unawaited(live.stop(reason: 'Translate closed on the glasses'));
    }
  }

  bool get connected => _session != null;

  // ── conversation translate ─────────────────────────────────────────────────────────────
  Future<void> startLive(String src, String dst, String source) async {
    if (source == 'glasses') {
      final s = _session;
      final e = evenAi;
      if (s == null || e == null) throw MicUnavailable('Glasses are not connected. Use the phone microphone instead.');
      var enteredByUs = false;
      final link = e.link;
      Future<void> audioCtl(bool on) => s.send(eh.sidEvenHubCh, eh.buildAudioControl(s.nextMagic(), on));
      await live.start(
        GlassesPcmSource(
          link.mic,
          [
            // 1: EvenHub audio control (keeps the Translate screen up); toggled so a re-arm restarts it.
            () async {
              await audioCtl(false);
              await audioCtl(true);
            },
            // 2: Even AI ENTER (+ heartbeat): the proven live mic path.
            () async {
              enteredByUs = true;
              await e.sendCtrl(ai.ctrlEnter);
            },
          ],
          disarmFns: [
            () => audioCtl(false),
            () async {
              if (enteredByUs) await e.sendCtrl(ai.ctrlExit);
            },
          ],
          report: _log,
        ),
        src,
        dst,
      );
    } else {
      await live.start(
        PhoneMicSource(
          onStarted: MicForegroundService.micOn,
          onStopped: () => MicForegroundService.micOff(glassesConnected: hub.status == LinkStatus.connected),
        ),
        src,
        dst,
      );
    }
    await update((s) {
      s.translateSrc = src;
      s.translateDst = dst;
      s.liveSource = source;
    });
  }

  Future<void> stopLive() async {
    _resume = null;
    await live.stop(reason: 'stopped');
    await _ConnectedDisplay(this).close();
  }

  // ── typed try ─────────────────────────────────────────────────────────────────────────
  /// The typed "Try it": works without glasses (a detached controller is used if needed).
  Future<String> tryIt(String q) async {
    final c = evenAi ?? EvenAiController(_OfflineLink(), _deps(), tools: AssistantTools(HubToolHost(hub, sync: sync)));
    try {
      return (await c.tryIt(q)).text;
    } finally {
      if (!identical(c, evenAi)) c.dispose();
    }
  }

  AiDeps _deps() => AiDeps(
      settings: () => settings,
      engines: engines,
      saveSettings: () => store.saveSettings(settings),
      log: _log,
      addHistory: addHistory,
      vad: vad);

  void resetConversation() {
    evenAi?.responder.reset();
    _log('Even AI: conversation reset', LogLevel.info);
  }
}

/// Translate display that follows the current connection (no-op while disconnected).
class _ConnectedDisplay implements TranslateDisplay {
  _ConnectedDisplay(this.ai);
  final AiHub ai;
  G2Features? get _f => ai.hub.status == LinkStatus.connected ? ai.hub.features : null;
  @override
  bool get isOpen => _f?.currentApp == 'translate';
  @override
  Future<void> show(String src, String dst, String original, String translated) async {
    final f = _f;
    if (f == null) throw StateError('glasses not connected');
    await FeaturesTranslateDisplay(() => f).show(src, dst, original, translated);
  }

  @override
  Future<void> close() async {
    final f = _f;
    if (f != null && f.currentApp == 'translate') await f.closeApp();
  }
}

class _NoMic implements MicLink {
  @override
  Stream<MicPacketIn> get packets => const Stream.empty();
  @override
  bool get running => false;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

class _OfflineLink implements EvenAiLink {
  @override
  Stream<RxFrame> get frames => const Stream.empty();
  @override
  MicLink get mic => _NoMic();
  @override
  int nextMagic() => 0;
  @override
  Future<void> send(int sid, Uint8List payload) async {}
}
