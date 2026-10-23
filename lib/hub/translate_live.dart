/// Live translation — port of g2-hub/hub/live_translate_mic.py + translate_live.py and the
/// fixed live-translate-off-on-close behaviour of routes/even_ai.py:
///
///  * Conversation mode ([LiveTranslator]): a continuous PCM source — the PHONE mic
///    ([PcmSource] from translate_live_phone_mic.dart) or the GLASSES mic
///    ([GlassesPcmSource], LC3 on 0x6402, re-armed when it stalls) — → energy VAD
///    [Segmenter] → queue (drops the oldest when behind) → STT → translation engine → the
///    glasses' Translate screen. Stops by itself after an idle period (battery).
///  * Hands-free mode: each Even AI wake gesture translates one utterance (lib/hub/even_ai.dart);
///    [onTranslateClosedOnGlasses] turns it off when the user closes Translate on the glasses,
///    so later wake gestures open Even AI again.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../ai/audio/glasses_mic.dart';
import '../ai/audio/pcm.dart';
import '../ai/audio/vad.dart';
import '../ai/config/ai_config.dart';
import '../ai/engines.dart';
import '../ble/lens_ad.dart';
import '../services/diagnostics_recorder.dart';
import 'even_ai.dart' show TranslateDisplay;
import 'glasses_session.dart' show LogLevel;

const double minConfidence = 0.3;

class MicUnavailable implements Exception {
  MicUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A continuous 16 kHz PCM source delivering ~100 ms blocks.
abstract class PcmSource {
  String get name;

  /// Start capturing; throws [MicUnavailable] with a readable reason.
  Future<void> start();

  /// Next block (awaits audio). Throws [MicUnavailable] when the source gives up.
  Future<Int16List> read();
  Future<void> stop();
}

/// The hub's on_translate_closed_on_glasses: the user closed Translate ON THE GLASSES, which
/// ends wake-based live translate (otherwise the saved flag keeps hijacking every later Even
/// AI wake gesture). Returns true if it was switched off.
bool onTranslateClosedOnGlasses(AiSettings s) {
  if (!s.translateHandsFree) return false;
  s.translateHandsFree = false;
  return true;
}

// ── glasses mic ──────────────────────────────────────────────────────────────────────────
typedef ArmFn = Future<void> Function();

/// Async PCM source fed by the glasses' mic packets (hub GlassesMicSource). The stream only
/// runs while "armed": if no packet arrives for [stall], [read] re-arms by rotating through
/// [armFns] (EvenHub audio control, then Even AI ENTER) with a short backoff. After
/// [maxFailures] failed re-arms — or re-arms that are accepted but never bring audio — it
/// throws [MicUnavailable]. The left lens is preferred if it streams.
class GlassesPcmSource implements PcmSource {
  GlassesPcmSource(this.mic, this.armFns, {this.disarmFns = const [], this.stall = const Duration(seconds: 3), this.maxFailures = 5, this.report, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final MicLink mic;
  final List<ArmFn> armFns;
  final List<ArmFn> disarmFns;
  final Duration stall;
  final int maxFailures;
  final void Function(String, LogLevel)? report;
  final DateTime Function() _clock;

  @override
  String get name => 'glasses';

  final Map<LensSide, Lc3Stream> _decoders = {};
  final List<int> _buf = [];
  final Queue<MicPacketIn> _queue = Queue();
  Completer<void>? _wake;
  StreamSubscription<MicPacketIn>? _sub;
  int _rearmIdx = 0;
  int rearms = 0;
  int _failures = 0;
  int _deadRearms = 0;
  bool _gotAudioSinceArm = false;
  DateTime _lastPacket = DateTime.fromMillisecondsSinceEpoch(0);

  void _say(String m, [LogLevel l = LogLevel.info]) => report?.call(m, l);

  @override
  Future<void> start() async {
    _sub = mic.packets.listen((p) {
      _queue.add(p);
      _wake?.complete();
      _wake = null;
    });
    await mic.start();
    await arm(first: true);
  }

  Future<void> arm({bool first = false}) async {
    final fn = armFns[_rearmIdx % armFns.length];
    _rearmIdx++;
    if (!first) rearms++;
    try {
      await fn();
      _failures = 0;
    } catch (e) {
      _failures++;
      _say('Glasses mic arm failed ($_failures/$maxFailures): $e', LogLevel.warn);
      if (first || _failures >= maxFailures) {
        throw MicUnavailable('Could not start the glasses microphone: $e. Use the phone microphone instead.');
      }
    }
    _lastPacket = _clock();
    _gotAudioSinceArm = false;
  }

  Future<MicPacketIn?> _next(Duration timeout) async {
    if (_queue.isNotEmpty) return _queue.removeFirst();
    final c = _wake = Completer<void>();
    await c.future.timeout(timeout, onTimeout: () {});
    if (identical(_wake, c)) _wake = null;
    return _queue.isEmpty ? null : _queue.removeFirst();
  }

  @override
  Future<Int16List> read() async {
    const need = Segmenter.blockSamples;
    while (_buf.length < need) {
      final p = await _next(const Duration(milliseconds: 250));
      if (p == null) {
        if (_clock().difference(_lastPacket) >= stall) {
          if (_failures == 0 && !_gotAudioSinceArm) {
            // The arm command succeeded but no audio ever came: don't re-arm forever.
            _deadRearms++;
            if (_deadRearms >= maxFailures) {
              throw MicUnavailable('The glasses accepted the microphone commands but sent no audio. '
                  'Use the phone microphone instead.');
            }
          }
          _say('Glasses mic stalled — re-arming');
          if (_failures > 0) {
            await Future<void>.delayed(Duration(milliseconds: (250 * _failures).clamp(0, 2000)));
          }
          await arm();
        }
        continue;
      }
      _lastPacket = _clock();
      _gotAudioSinceArm = true;
      _deadRearms = 0;
      if (p.side == LensSide.right && _decoders.containsKey(LensSide.left)) continue; // left streams: skip right
      _buf.addAll((_decoders[p.side] ??= Lc3Stream()).decode(p.data));
    }
    final block = Int16List.fromList(_buf.sublist(0, need));
    _buf.removeRange(0, need);
    return block;
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await mic.stop();
    } catch (_) {}
    for (final fn in disarmFns) {
      try {
        await fn();
      } catch (e) {
        _say('Glasses mic disarm step failed: $e', LogLevel.warn);
      }
    }
  }
}

// ── the translator ────────────────────────────────────────────────────────────────────────
class LiveLine {
  LiveLine(this.original, this.translated) : at = DateTime.now();
  final String original;
  final String translated;
  final DateTime at;
}

class LiveTranslator extends ChangeNotifier {
  LiveTranslator({
    required this.stt,
    required this.translation,
    required this.display,
    this.report,
    this.idleStop,
    this.segmenter,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// The utterance segmenter for a session (Silero VAD in the app); null = energy [Segmenter].
  final Future<UtteranceSegmenter> Function()? segmenter;

  /// Engines are looked up per utterance (settings changes apply immediately).
  final Future<SttEngine> Function() stt;
  final Future<TranslationEngine> Function() translation;
  final TranslateDisplay? display;
  final void Function(String, LogLevel)? report;

  /// Stop after this long without an utterance (null/zero = never).
  final Duration Function()? idleStop;
  final DateTime Function() _clock;

  PcmSource? _source;
  bool _running = false;
  String src = 'EN', dst = 'ES';
  String? sourceName;
  final List<LiveLine> lines = [];
  String lastError = '';
  String lastPushError = '';
  int utterances = 0;
  bool listeningSpeech = false;
  DateTime _lastActivity = DateTime.now();
  final _pending = Queue<Int16List>();
  bool _working = false;
  int _gen = 0;

  bool get running => _running;
  int get rearms => (_source is GlassesPcmSource) ? (_source as GlassesPcmSource).rearms : 0;

  void _say(String m, [LogLevel l = LogLevel.info]) => report?.call(m, l);

  /// Open [source] and run until [stop]. Throws [MicUnavailable] (nothing left running).
  ///
  /// A later [start] or a [stop] while this one is still opening its source wins: the source
  /// is then closed again and nothing keeps running (no mic, no microphone service type).
  Future<void> start(PcmSource source, String src, String dst) async {
    final gen = ++_gen;
    if (_running) await _halt();
    if (gen != _gen) return;
    this.src = src;
    this.dst = dst;
    lastError = lastPushError = '';
    await source.start();
    if (gen != _gen) {
      try {
        await source.stop();
      } catch (_) {}
      return;
    }
    _source = source;
    sourceName = source.name;
    _running = true;
    _lastActivity = _clock();
    notifyListeners();
    _say('Live translate started ($src>$dst, ${source.name} mic)', LogLevel.ok);
    DiagnosticsRecorder.instance.ai('live_translate', 'start $src>$dst ${source.name} mic');
    unawaited(_run(source));
  }

  Future<void> stop({String reason = ''}) async {
    _gen++; // also cancels a start that is still opening its source
    await _halt(reason: reason);
  }

  Future<void> _halt({String reason = ''}) async {
    if (!_running) return;
    _running = false;
    final s = _source;
    _source = null;
    _pending.clear();
    try {
      await s?.stop();
    } catch (_) {}
    listeningSpeech = false;
    DiagnosticsRecorder.instance.ai('live_translate', 'stop${reason.isEmpty ? '' : ' ($reason)'} after $utterances utterance(s)');
    _say('Live translate stopped${reason.isEmpty ? '' : ' ($reason)'}');
    notifyListeners();
  }

  Future<void> _run(PcmSource source) async {
    UtteranceSegmenter seg;
    try {
      seg = await (segmenter?.call() ?? Future.value(Segmenter()));
    } catch (_) {
      seg = Segmenter();
    }
    try {
      await _loop(source, seg);
    } finally {
      seg.close();
    }
  }

  bool _current(PcmSource source) => _running && identical(_source, source);

  Future<void> _loop(PcmSource source, UtteranceSegmenter seg) async {
    while (_current(source)) {
      Int16List block;
      try {
        block = await source.read();
      } catch (e) {
        if (!_current(source)) return; // stopped (or restarted with another source) meanwhile
        lastError = e is MicUnavailable ? e.message : 'Microphone read failed: $e';
        DiagnosticsRecorder.instance.ai('live_translate', 'mic error ${e.runtimeType}');
        _say(lastError, LogLevel.err);
        await stop(reason: 'microphone');
        return;
      }
      if (!_current(source)) return;
      final utt = seg.feed(block);
      if (seg.inUtterance != listeningSpeech) {
        listeningSpeech = seg.inUtterance;
        DiagnosticsRecorder.instance.ai('live_translate', listeningSpeech ? 'speech start' : 'speech end');
        notifyListeners();
      }
      if (utt != null) {
        if (_pending.length >= 4) _pending.removeFirst(); // drop the oldest rather than fall behind
        _pending.add(utt);
        _lastActivity = _clock();
        unawaited(_work());
      }
      final idle = idleStop?.call();
      if (idle != null && idle > Duration.zero && !_working && _pending.isEmpty && _clock().difference(_lastActivity) >= idle) {
        await stop(reason: 'no speech for ${idle.inMinutes} min');
        return;
      }
    }
  }

  Future<void> _work() async {
    if (_working) return;
    _working = true;
    try {
      while (_pending.isNotEmpty && _running) {
        final pcm = _pending.removeFirst();
        try {
          await process(pcm);
        } catch (e) {
          lastError = '$e';
          DiagnosticsRecorder.instance.ai('live_translate', 'utterance failed ${e.runtimeType}');
          _say('Live translate: $e', LogLevel.warn);
          notifyListeners();
        }
      }
    } finally {
      _working = false;
    }
  }

  /// One utterance: STT → translate → show. Returns the translation, or null if skipped.
  Future<String?> process(Int16List pcm) async {
    final t = await (await stt()).transcribe(pcm, language: src.toLowerCase());
    final text = t.text.trim();
    if (text.isEmpty || t.confidence < minConfidence) {
      DiagnosticsRecorder.instance.ai('live_translate', 'utterance skipped (${text.isEmpty ? 'empty' : 'low confidence'})');
      return null;
    }
    final translated = await (await translation()).translate(text, src, dst);
    utterances++;
    lastError = '';
    _lastActivity = _clock();
    lines.add(LiveLine(text, translated));
    DiagnosticsRecorder.instance.ai('live_translate', 'utterance translated');
    if (lines.length > 200) lines.removeAt(0);
    notifyListeners();
    try {
      await display?.show(src, dst, text, translated);
      lastPushError = '';
    } catch (e) {
      lastPushError = 'push to glasses failed: $e';
      _say('Live translate: $lastPushError', LogLevel.warn);
    }
    _say('Live $src>$dst: "$text" -> "$translated"', LogLevel.ok);
    return translated;
  }
}
