/// Builds the engine each feature uses from the saved profiles + keystore keys.
library;

import 'package:http/http.dart' as http;

import 'config/ai_config.dart';
import 'config/secret_store.dart';
import 'engines.dart';
import 'local/local_ai.dart';
import 'local/local_catalog.dart';
import 'providers/anthropic.dart';
import 'providers/gemini.dart';
import 'providers/http_util.dart' show badEndpoint;
import 'providers/llm.dart';
import 'providers/openai_compat.dart';
import 'providers/stt.dart';
import 'providers/translation.dart';

/// A feature has no usable engine configured (shown to the user as setup guidance).
class NotConfigured extends AiError {
  NotConfigured(super.message);
}

class EngineFactory {
  EngineFactory(this.secrets, {http.Client Function()? httpClient, MlKitApi? mlKit, this.local})
      : _client = httpClient ?? http.Client.new,
        _mlKitApi = mlKit;

  final SecretStore secrets;

  /// On-device models (null in builds/tests without them: "On this phone" is not set up).
  final LocalAi? local;
  final http.Client Function() _client;
  final MlKitApi? _mlKitApi;
  MlKitTranslationEngine? _ml;

  MlKitTranslationEngine get mlKit => _ml ??= MlKitTranslationEngine(api: _mlKitApi);

  /// A key from the keystore. A keystore failure (Android can lose its Keystore key after a
  /// lock-screen change or a backup restore) is reported readably, never as a platform error
  /// (whose text could carry stored data).
  Future<String?> _key(String name, String profile) async {
    try {
      final k = await secrets.read(name);
      return k == null || k.isEmpty ? null : k;
    } catch (_) {
      throw NotConfigured('$profile: could not read the API key from the phone keystore; enter it again in AI models');
    }
  }

  static void _url(String profile, String url, {bool optional = false}) {
    if (optional && url.trim().isEmpty) return;
    final bad = badEndpoint(url);
    if (bad != null) throw NotConfigured('$profile: $bad');
  }

  /// [firstTokenTimeout]: on-device only, see [LocalLlmEngine]. [translation]: allow longer
  /// output and a lower temperature than the glasses-reply cap.
  Future<LlmEngine> llm(LlmProfile p, {Duration? firstTokenTimeout, bool translation = false}) async {
    if (p.provider == LlmProvider.local) return _local(p, firstTokenTimeout: firstTokenTimeout, translation: translation);
    final key = await _key(llmKeyName(p.id), p.name);
    switch (p.provider) {
      case LlmProvider.local:
        throw StateError('unreachable');
      case LlmProvider.anthropic:
        if (key == null) throw NotConfigured('${p.name}: add your Anthropic API key in AI models');
        _url(p.name, p.baseUrl, optional: true);
        return AnthropicEngine(apiKey: key, model: p.model, baseUrl: p.baseUrl, client: _client());
      case LlmProvider.gemini:
        if (key == null) throw NotConfigured('${p.name}: add your Google AI (Gemini) API key in AI models');
        _url(p.name, p.baseUrl, optional: true);
        return GeminiEngine(apiKey: key, model: p.model, baseUrl: p.baseUrl, client: _client());
      case LlmProvider.openai:
        if (p.baseUrl.trim().isEmpty) throw NotConfigured('${p.name}: set the endpoint base URL in AI models');
        _url(p.name, p.baseUrl);
        return OpenAiCompatEngine(
            baseUrl: p.baseUrl, model: p.model, apiKey: key, toolsEnabled: p.toolsEnabled, maxTokensField: p.maxTokensField, client: _client());
    }
  }

  Future<SttEngine> stt(SttProfile p) async {
    final key = p.provider == SttProvider.onDevice ? null : await _key(sttKeyName(p.id), p.name);
    switch (p.provider) {
      case SttProvider.deepgram:
        if (key == null) throw NotConfigured('${p.name}: add your Deepgram API key in AI models');
        _url(p.name, p.baseUrl, optional: true);
        return DeepgramStt(apiKey: key, model: p.model, baseUrl: p.baseUrl, client: _client());
      case SttProvider.whisper:
        if (p.baseUrl.trim().isEmpty) throw NotConfigured('${p.name}: set the Whisper endpoint base URL in AI models');
        _url(p.name, p.baseUrl);
        return WhisperCompatStt(baseUrl: p.baseUrl, model: p.model.isEmpty ? 'whisper-1' : p.model, apiKey: key, client: _client());
      case SttProvider.onDevice:
        final id = p.model.isEmpty ? recommendStt(null).id : p.model;
        final e = await local?.stt(id);
        if (e != null) return e;
        return OnDeviceStt(local == null
            ? 'On-device speech recognition is not available in this build.'
            : 'The on-device speech model is not downloaded yet (AI models → On this phone).');
    }
  }

  Future<LlmEngine> _local(LlmProfile p, {Duration? firstTokenTimeout, bool translation = false}) async {
    final ai = local;
    if (ai == null) throw NotConfigured('${p.name}: on-device AI is not available in this build');
    final m = await ai.store.spec(p.model);
    if (m == null || m.kind != LocalKind.llm) throw NotConfigured('${p.name}: choose a model to download in AI models → On this phone');
    final problem = await ai.problem(m);
    if (problem != null) throw NotConfigured(problem);
    return LocalLlmEngine(
      ai,
      m,
      tools: p.toolsEnabled,
      maxTokensCap: translation ? (p.maxTokens < 512 ? 512 : p.maxTokens) : p.maxTokens,
      firstTokenTimeout: firstTokenTimeout,
      temperature: translation ? 0.2 : (p.temperature ?? 0.4),
    );
  }

  Duration? _slow(AiSettings s, LlmProfile p, LlmProfile? fallback) =>
      p.provider == LlmProvider.local && fallback != null && fallback.id != p.id && s.localSlowSec > 0
          ? Duration(seconds: s.localSlowSec)
          : null;

  /// The assistant engine (with its optional fallback profile).
  Future<(LlmEngine, LlmProfile)> assistant(AiSettings s, {FallbackNotice? onFallback}) async {
    final p = s.llmById(s.assistantProfileId) ?? s.llmProfiles.firstOrNull;
    if (p == null) throw NotConfigured('No AI model set up: add one in AI models');
    final fb = s.llmById(s.assistantFallbackProfileId);
    try {
      final primary = await llm(p, firstTokenTimeout: _slow(s, p, fb));
      if (fb == null || fb.id == p.id) return (primary, p);
      try {
        return (FallbackLlm(primary, await llm(fb), onFallback: onFallback), p);
      } on NotConfigured {
        return (primary, p);
      }
    } on NotConfigured {
      if (fb == null) rethrow;
      onFallback?.call('${p.name} is not set up; using ${fb.name}');
      return (await llm(fb), fb);
    }
  }

  Future<SttEngine> speech(AiSettings s, {FallbackNotice? onFallback}) async {
    final p = s.sttById(s.sttProfileId) ?? s.sttProfiles.firstOrNull;
    if (p == null) throw NotConfigured('No speech-to-text set up: add one in AI models');
    final fb = s.sttById(s.sttFallbackProfileId);
    SttEngine? fallback;
    if (fb != null && fb.id != p.id) {
      try {
        fallback = await stt(fb);
      } on NotConfigured {
        fallback = null;
      }
    }
    try {
      final primary = await stt(p);
      return fallback == null ? primary : FallbackStt(primary, fallback, onFallback: onFallback);
    } on NotConfigured {
      if (fallback == null) rethrow;
      return fallback;
    }
  }

  Future<TranslationEngine> translation(AiSettings s, {FallbackNotice? onFallback}) async {
    final p = s.llmById(s.translationProfileId) ?? s.llmById(s.assistantProfileId) ?? s.llmProfiles.firstOrNull;
    final fb = s.llmById(s.translationFallbackProfileId);
    Future<TranslationEngine> cloud() async {
      if (p == null) throw NotConfigured('No translation model set up: choose one in AI models');
      final useFb = fb != null && fb.id != p.id && s.translationEngine == TranslationEngineKind.llm;
      TranslationEngine? fallback;
      if (useFb) {
        try {
          fallback = LlmTranslationEngine(await llm(fb, translation: true), label: fb.name);
        } on NotConfigured {
          fallback = null;
        }
      }
      try {
        final primary = LlmTranslationEngine(
            await llm(p, translation: true, firstTokenTimeout: fallback == null ? null : _slow(s, p, fb)),
            label: p.name);
        return fallback == null ? primary : FallbackTranslation(primary, fallback, onFallback: onFallback);
      } on NotConfigured {
        if (fallback == null) rethrow;
        onFallback?.call('${p.name} is not set up; using ${fb!.name}');
        return fallback;
      }
    }

    if (s.translationEngine == TranslationEngineKind.mlkit) {
      if (!s.translationCloudFallback) return mlKit;
      try {
        return FallbackTranslation(mlKit, await cloud(), onFallback: onFallback);
      } on NotConfigured {
        return mlKit;
      }
    }
    return cloud();
  }
}
