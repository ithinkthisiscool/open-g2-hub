/// Offline speech recognition: sherpa-onnx (Apache-2.0, k2-fsa / Next-gen Kaldi) running an
/// int8 Whisper model (MIT) on the 16 kHz PCM decoded from the glasses' LC3 mic (or the phone
/// mic). Each transcription runs in a short-lived background isolate (sherpa-onnx's FFI calls
/// are synchronous), so the UI never stalls.
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import '../engines.dart';

class WhisperFiles {
  const WhisperFiles({required this.encoder, required this.decoder, required this.tokens});
  final String encoder;
  final String decoder;
  final String tokens;
}

/// Whisper's language codes (ISO 639-1, lower case) for the languages the app offers.
const Set<String> whisperLanguages = {
  'en', 'es', 'fr', 'de', 'it', 'pt', 'nl', 'ru', 'zh', 'ja', 'ko', 'ar', 'hi', 'tr', 'pl', 'sv', //
  'uk', 'vi', 'th', 'id', 'el', 'he', 'cs', 'da', 'fi', 'no', 'ro', 'hu', 'ca', 'ms',
};

/// Transcribes [pcm] in the current isolate (used by [SherpaWhisperStt] inside Isolate.run).
String transcribeWhisperSync(WhisperFiles f, Float32List samples, int rate, String language, int threads) {
  so.initBindings();
  final rec = so.OfflineRecognizer(so.OfflineRecognizerConfig(
    model: so.OfflineModelConfig(
      whisper: so.OfflineWhisperModelConfig(encoder: f.encoder, decoder: f.decoder, language: language, task: 'transcribe'),
      tokens: f.tokens,
      numThreads: threads,
      debug: false,
    ),
  ));
  final s = rec.createStream();
  try {
    s.acceptWaveform(samples: samples, sampleRate: rate);
    rec.decode(s);
    return rec.getResult(s).text.trim();
  } finally {
    s.free();
    rec.free();
  }
}

class SherpaWhisperStt implements SttEngine {
  SherpaWhisperStt(this.files, {this.label = 'Whisper', this.threads = 2});
  final WhisperFiles files;
  final String label;
  final int threads;

  /// Whisper takes at most 30 s per call.
  static const int maxSeconds = 30;

  @override
  EngineCaps get caps => const EngineCaps(offline: true);
  @override
  String get name => 'On this phone ($label)';

  @override
  Future<Transcript> transcribe(Int16List pcm, {int sampleRate = 16000, String? language}) async {
    if (pcm.isEmpty) return const Transcript('', 0);
    final n = pcm.length.clamp(0, maxSeconds * sampleRate);
    final samples = Float32List(n);
    for (var i = 0; i < n; i++) {
      samples[i] = pcm[i] / 32768.0;
    }
    final lang = (language ?? '').toLowerCase();
    final l = whisperLanguages.contains(lang) ? lang : '';
    final f = files;
    final t = threads;
    try {
      final text = await Isolate.run(() => transcribeWhisperSync(f, samples, sampleRate, l, t));
      return Transcript(text, 1.0);
    } catch (e) {
      throw EngineUnavailable('On-device speech recognition failed: $e');
    }
  }

  @override
  Future<String> testConnection() async {
    final t = await transcribe(Int16List(16000));
    return 'OK — the on-device model ran on a silent test clip${t.text.isEmpty ? '' : ' ("${t.text}")'}';
  }
}

