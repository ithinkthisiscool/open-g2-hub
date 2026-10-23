/// Speech-to-text engines. Input is always 16 kHz mono PCM16 — decoded glasses audio (LC3)
/// or the phone microphone — sent as a WAV file.
///
///  * [DeepgramStt]: the hub's default — prerecorded REST /v1/listen (punctuate,
///    smart_format), `Authorization: Token <key>`.
///  * [WhisperCompatStt]: any OpenAI-compatible `/audio/transcriptions` (OpenAI whisper-1 /
///    gpt-4o-mini-transcribe, Groq whisper-large-v3-turbo, a local faster-whisper /
///    whisper.cpp server on your network).
///  * Offline: `SherpaWhisperStt` (lib/ai/local/local_stt.dart, sherpa-onnx + Whisper int8);
///    [OnDeviceStt] stands in for it while its model is not downloaded.
library;

import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../audio/pcm.dart';
import '../engines.dart';
import 'http_util.dart';
import 'llm.dart';

const String deepgramUrl = 'https://api.deepgram.com/v1';

class DeepgramStt implements SttEngine {
  DeepgramStt({required this.apiKey, this.model = '', String? baseUrl, http.Client? client, Sleep? sleep})
      : baseUrl = (baseUrl == null || baseUrl.trim().isEmpty) ? deepgramUrl : baseUrl.trim(),
        _http = HttpJson(client ?? http.Client(), provider: 'Deepgram', sleep: sleep, timeout: const Duration(seconds: 30));

  final String apiKey;

  /// e.g. nova-3; empty = Deepgram's default (what the hub uses).
  final String model;
  final String baseUrl;
  final HttpJson _http;

  @override
  EngineCaps get caps => const EngineCaps();
  @override
  String get name => 'Deepgram';

  Uri listenUrl({String? language}) => joinUrl(baseUrl, '/listen', {
        'punctuate': 'true',
        'smart_format': 'true',
        if (model.isNotEmpty) 'model': model,
        if (language != null && language.isNotEmpty) 'language': language.toLowerCase(),
      });

  @override
  Future<Transcript> transcribe(Int16List pcm, {int sampleRate = 16000, String? language}) async {
    final wav = pcmToWav(pcm, rate: sampleRate);
    final j = await _http.send(() => _http.client.post(listenUrl(language: language),
        headers: {'authorization': 'Token $apiKey', 'content-type': 'audio/wav'}, body: wav));
    try {
      final alt = (((((j['results'] as Map)['channels'] as List).first as Map)['alternatives'] as List).first as Map);
      return Transcript((alt['transcript'] ?? '').toString().trim(), ((alt['confidence'] ?? 0) as num).toDouble());
    } catch (_) {
      throw AiError('Deepgram: unexpected reply');
    }
  }

  @override
  Future<String> testConnection() async {
    final j = await _http.getJson(joinUrl(baseUrl, '/projects'), {'authorization': 'Token $apiKey'});
    final n = (j['projects'] as List?)?.length ?? 0;
    return 'OK — key accepted ($n project${n == 1 ? '' : 's'})';
  }
}

class WhisperCompatStt implements SttEngine {
  WhisperCompatStt({required this.baseUrl, this.model = 'whisper-1', this.apiKey, http.Client? client, Sleep? sleep})
      : _http = HttpJson(client ?? http.Client(), provider: 'Whisper', sleep: sleep, timeout: const Duration(seconds: 45));

  final String baseUrl;
  final String model;
  final String? apiKey;
  final HttpJson _http;

  @override
  EngineCaps get caps => const EngineCaps();
  @override
  String get name => 'Whisper ($model)';

  Map<String, String> get _auth => {if (apiKey != null && apiKey!.isNotEmpty) 'authorization': 'Bearer $apiKey'};

  /// The multipart request (fields are snapshot-tested).
  http.MultipartRequest buildRequest(Int16List pcm, {int sampleRate = 16000, String? language}) {
    final req = http.MultipartRequest('POST', joinUrl(baseUrl, '/audio/transcriptions'))
      ..headers.addAll(_auth)
      ..fields['model'] = model
      ..fields['response_format'] = 'json';
    if (language != null && language.isNotEmpty) req.fields['language'] = language.toLowerCase();
    req.files.add(http.MultipartFile.fromBytes('file', pcmToWav(pcm, rate: sampleRate), filename: 'audio.wav'));
    return req;
  }

  @override
  Future<Transcript> transcribe(Int16List pcm, {int sampleRate = 16000, String? language}) async {
    final j = await _http.send(() async =>
        http.Response.fromStream(await _http.client.send(buildRequest(pcm, sampleRate: sampleRate, language: language))));
    return Transcript((j['text'] ?? '').toString().trim(), 1.0);
  }

  @override
  Future<String> testConnection() async {
    // A short silent clip proves URL, key and model in one call.
    final t = await transcribe(Int16List(8000));
    return 'OK — endpoint transcribed a test clip${t.text.isEmpty ? '' : ' ("${t.text}")'}';
  }
}

/// Stand-in for the offline engine while it cannot run (model not downloaded, or a build
/// without on-device AI). It reports itself unavailable, so a configured fallback takes over.
class OnDeviceStt implements SttEngine {
  const OnDeviceStt([this.reason = 'On-device speech recognition is not set up: download a speech model in AI models → On this phone.']);
  final String reason;
  @override
  EngineCaps get caps => const EngineCaps(offline: true);
  @override
  String get name => 'On-device';
  @override
  Future<Transcript> transcribe(Int16List pcm, {int sampleRate = 16000, String? language}) async => throw EngineUnavailable(reason);
  @override
  Future<String> testConnection() async => throw EngineUnavailable(reason);
}
