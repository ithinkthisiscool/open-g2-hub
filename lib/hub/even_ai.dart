/// Even AI on the phone — port of g2-hub/hub/routes/even_ai.py (ai_handle_wake & co):
///
///   glasses CTRL WAKE_UP → CTRL ENTER + HEARTBEAT every 2 s → subscribe the mic (0x6402) →
///   LC3 → PCM → SilenceDetector (the glasses never send VAD_END) → STT → voice shortcut or
///   LLM with the glasses tools (or the fixed auto-reply) → ASK / ANALYSE / REPLY chunks
///   (≤512 B, 150 ms apart) → EXIT after a reading time (optional) → history log.
///
/// With hands-free translate on, the transcript is translated and shown in the glasses'
/// Translate app instead (hub translate_utterance). Everything external is behind small
/// interfaces so the loop runs against fakes in test/ai/even_ai_flow_test.dart.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../ai/assistant/responder.dart';
import '../ai/assistant/tools.dart';
import '../ai/assistant/voice_shortcuts.dart';
import '../ai/audio/glasses_mic.dart';
import '../ai/audio/pcm.dart';
import '../ai/audio/silero_vad.dart';
import '../ai/audio/vad.dart';
import '../ai/config/ai_config.dart';
import '../ai/engine_factory.dart';
import '../ai/local/local_ai.dart' show localSystemPrompt;
import '../ai/providers/llm.dart';
import '../ble/lens_ad.dart';
import '../protocol/even_ai.dart' as ai;
import '../services/diagnostics_recorder.dart';
import 'glasses_session.dart' show LogLevel, RxFrame;

/// What the Even AI loop needs from the glasses connection.
abstract class EvenAiLink {
  Stream<RxFrame> get frames;
  int nextMagic();

  /// Frame [payload] for [sid] (flag 0x20) and write it to the right lens.
  Future<void> send(int sid, Uint8List payload);
  MicLink get mic;
}

/// The glasses' native Translate screen (implemented over G2Features).
abstract class TranslateDisplay {
  bool get isOpen;
  Future<void> show(String src, String dst, String original, String translated);
  Future<void> close();
}

/// Where engines, settings, logging and history come from (the AiHub in the app).
class AiDeps {
  AiDeps({
    required this.settings,
    required this.engines,
    required this.saveSettings,
    required this.log,
    required this.addHistory,
    this.vad,
  });
  final AiSettings Function() settings;

  /// Silero VAD for end-of-speech (null or unavailable = the energy [SilenceDetector]).
  final SileroVad? vad;
  final EngineFactory engines;
  final Future<void> Function() saveSettings;
  final void Function(String message, LogLevel level) log;
  final void Function(AiHistoryEntry entry) addHistory;
}

enum AiPhase { idle, open, listening, transcribing, heard, thinking, answered, error }

class _Turn {
  bool vadEnd = false;
  bool exit = false;

  /// The glasses mic delivered nothing for [EvenAiController.micStall] while listening.
  bool micStalled = false;
  final _changed = StreamController<void>.broadcast();
  void poke() => _changed.add(null);
}

class EvenAiController extends ChangeNotifier {
  EvenAiController(
    this.link,
    this.deps, {
    this.tools,
    this.display,
    Responder? responder,
    this.micBusy,
    DateTime Function()? clock,
  }) : responder = responder ?? Responder(clock: clock) {
    _sub = link.frames.listen(_onFrame);
  }

  final EvenAiLink link;
  final AiDeps deps;
  final AssistantTools? tools;
  final TranslateDisplay? display;
  final Responder responder;

  /// True while conversation translate owns the glasses mic (a wake would fight it).
  final bool Function()? micBusy;

  /// Listening gives up when the glasses mic sends nothing for this long (a stalled stream
  /// would otherwise keep the user waiting for the whole "Listen at most" time).
  static const Duration micStall = Duration(seconds: 3);
  static const String noAudioMessage =
      "I couldn't hear you: the glasses microphone sent no audio. Please try again.";

  late final StreamSubscription<RxFrame> _sub;
  bool _disposed = false;
  Timer? _hb;
  int _hbCount = 0;
  Timer? _autoClose;
  _Turn? _turn;
  bool get turnRunning => _turn != null;
  bool get sessionOpen => _hb != null;

  AiPhase phase = AiPhase.idle;
  String question = '';
  String reply = '';
  String statusMessage = '';

  void _phase(AiPhase p, {String? q, String? r, String? message}) {
    if (_disposed) return; // the glasses disconnected / were handed off mid-turn
    if (phase != p) DiagnosticsRecorder.instance.ai('even_ai', 'phase ${p.name}');
    phase = p;
    if (q != null) question = q;
    if (r != null) reply = r;
    statusMessage = message ?? '';
    notifyListeners();
  }

  void _log(String m, [LogLevel l = LogLevel.info]) => deps.log(m, l);

  @override
  void dispose() {
    _disposed = true;
    _sub.cancel();
    _stopHeartbeat();
    _autoClose?.cancel();
    final t = _turn;
    if (t != null) {
      t.exit = true;
      t.poke();
    }
    super.dispose();
  }

  // ── sending ─────────────────────────────────────────────────────────────────────────────
  Future<void> _send(Uint8List pb, String label, {bool quiet = false}) async {
    if (_disposed) throw StateError('glasses disconnected');
    if (!quiet) {
      _log('Even AI → $label');
      DiagnosticsRecorder.instance.ai('even_ai', 'tx ${label.split('"').first.trim()}'); // no ASK text
    }
    await link.send(ai.sid, pb);
  }

  Future<void> sendCtrl(int status) async {
    await _send(ai.buildCtrl(link.nextMagic(), status), 'CTRL ${ai.ctrlNames[status] ?? status}');
    if (status == ai.ctrlEnter) {
      _startHeartbeat();
    } else if (status == ai.ctrlExit) {
      _stopHeartbeat();
      _autoClose?.cancel();
    }
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    if (_disposed) return;
    _hbCount = 0;
    _hb = Timer.periodic(ai.heartbeatInterval, (_) {
      _hbCount++;
      _send(ai.buildHeartbeat(link.nextMagic(), _hbCount), 'HEARTBEAT', quiet: true).catchError((Object e) {
        _log('Even AI heartbeat stopped: $e', LogLevel.warn);
        _stopHeartbeat();
      });
    });
  }

  void _stopHeartbeat() {
    _hb?.cancel();
    _hb = null;
  }

  Future<void> sendAsk(String text) => _send(ai.buildAsk(link.nextMagic(), text), 'ASK "${_short(text)}"');
  Future<void> sendAnalyse() => _send(ai.buildAnalyse(link.nextMagic()), 'ANALYSE (thinking)');

  /// End the Even AI session from our side: heartbeat off, no auto-close pending, and (if
  /// [exit]) CTRL EXIT so the glasses close the Even AI screen. Best effort.
  Future<void> _endSession({required bool exit}) async {
    _autoClose?.cancel();
    if (!sessionOpen) return;
    if (exit && !_disposed) {
      try {
        await sendCtrl(ai.ctrlExit);
      } catch (_) {}
    }
    _stopHeartbeat();
  }

  /// [turn]: stop sending further chunks if the user closed Even AI meanwhile.
  Future<void> sendReply(String text, {Object? turn}) async {
    final t = turn is _Turn ? turn : null;
    final chunks = ai.replyChunks(text);
    for (var i = 0; i < chunks.length; i++) {
      if (_disposed || (t?.exit ?? false)) return;
      final last = i == chunks.length - 1;
      await _send(ai.buildReply(link.nextMagic(), chunks[i], last), 'REPLY ${i + 1}/${chunks.length}${last ? ' (end)' : ''}');
      if (!last) await Future<void>.delayed(ai.replyPace);
    }
    _armAutoClose(text);
  }

  Future<void> _sendReplyPart(String text, bool last) async {
    final chunks = ai.replyChunks(text);
    for (var i = 0; i < chunks.length; i++) {
      if (_disposed || (_turn?.exit ?? false)) return;
      final end = last && i == chunks.length - 1;
      await _send(ai.buildReply(link.nextMagic(), chunks[i], end), 'REPLY (streamed)${end ? ' (end)' : ''}');
      if (!end) await Future<void>.delayed(ai.replyPace);
    }
  }

  static String _short(String s) => s.length > 40 ? '${s.substring(0, 40)}…' : s;

  /// Reading time before the answer closes itself: 8 s + 60 ms per character, max 90 s.
  static Duration readingTime(String text) => Duration(milliseconds: (8000 + 60 * text.length).clamp(8000, 90000));

  void _armAutoClose(String text) {
    _autoClose?.cancel();
    if (_disposed || !deps.settings().autoCloseReply) return;
    _autoClose = Timer(readingTime(text), () {
      if (_turn == null && sessionOpen) {
        sendCtrl(ai.ctrlExit).catchError((Object _) {});
        _phase(AiPhase.idle);
      }
    });
  }

  // ── glasses → phone ────────────────────────────────────────────────────────────────────
  void _onFrame(RxFrame f) {
    if (f.sid != ai.sid) return;
    final msg = ai.decode(f.payload);
    final cmd = msg['cmd'] as int;
    final value = msg['value'] as int?;
    if (cmd != ai.cmdHeartbeat) {
      _log('Even AI ← ${msg['label']}', LogLevel.ok);
      DiagnosticsRecorder.instance.ai('even_ai', 'rx ${msg['label']}');
    }
    final turn = _turn;
    if (cmd == ai.cmdVadInfo && turn != null && (value == ai.vadEnd || value == ai.vadTimeout)) {
      turn.vadEnd = true;
      turn.poke();
    }
    if (cmd == ai.cmdEvent && sessionOpen && turn == null) {
      // Scrolling (or the end of the stream) restarts the reading time.
      _armAutoClose(reply);
    }
    if (cmd == ai.cmdCtrl && value == ai.ctrlExit) {
      _stopHeartbeat();
      _autoClose?.cancel();
      if (turn != null) {
        turn.exit = true;
        turn.poke();
        // Stop an on-device generation now, not only when its next token arrives.
        if (phase == AiPhase.thinking) deps.engines.local?.cancel();
      }
      _phase(AiPhase.idle);
    } else if (cmd == ai.cmdCtrl && value == ai.ctrlWakeUp && f.side == LensSide.right) {
      unawaited(handleWake());
    } else if (cmd == ai.cmdCtrl && value == ai.ctrlWakeUp && turn == null && !sessionOpen) {
      // Some firmware reports the wake on the left lens only.
      unawaited(handleWake());
    }
  }

  // ── the turn ──────────────────────────────────────────────────────────────────────────
  /// WAKE_UP → per the configured mode. Returns when the turn is done.
  Future<void> handleWake() async {
    if (micBusy?.call() == true) {
      _log('Even AI: wake ignored — conversation translate is using the glasses mic');
      return;
    }
    var cfg = deps.settings();
    final handsFree = cfg.translateHandsFree;
    var mode = cfg.mode;
    var listen = cfg.listen;
    if (handsFree) {
      // Translate overrides off/open: it still needs listening.
      listen = true;
      if (mode != EvenAiMode.autoReply && mode != EvenAiMode.assistant) mode = EvenAiMode.autoReply;
    }
    if (mode == EvenAiMode.off) return;
    if (_turn != null) {
      _log('Even AI: wake ignored — a turn is already running');
      return;
    }
    final turn = _Turn();
    _turn = turn;
    _autoClose?.cancel();
    final entry = AiHistoryEntry(source: 'voice', mode: mode.name);
    try {
      await sendCtrl(ai.ctrlEnter);
      if (mode == EvenAiMode.open) {
        _phase(AiPhase.open);
        return;
      }
      var q = '';
      String? sttProblem;
      if (listen) {
        _phase(AiPhase.listening, q: '', r: '');
        final packets = await _capture(turn, Duration(seconds: cfg.listenSeconds));
        final (pcm, side, n) = decodePackets(packets);
        final secs = pcm.length / sampleRate;
        _log('Even AI: captured $n audio packets from the ${side?.name ?? '-'} lens (${secs.toStringAsFixed(1)} s)',
            n > 0 ? LogLevel.ok : LogLevel.warn);
        entry.audioSeconds = double.parse(secs.toStringAsFixed(1));
        if (turn.exit || _disposed) {
          _phase(AiPhase.idle);
          return;
        }
        if (turn.micStalled && pcm.isEmpty) {
          sttProblem = noAudioMessage;
          entry.error = 'no audio from the glasses microphone';
        }
        if (pcm.isNotEmpty) {
          _phase(AiPhase.transcribing);
          try {
            final stt = await deps.engines.speech(cfg, onFallback: (m) => _log('Even AI: $m', LogLevel.warn));
            final t = await stt.transcribe(pcm, language: _sttLanguage(cfg, handsFree));
            q = t.text;
            entry.confidence = double.parse(t.confidence.toStringAsFixed(3));
            _log('Even AI heard: "$q" (${(t.confidence * 100).round()}%)', LogLevel.ok);
          } on NotConfigured catch (e) {
            sttProblem = e.message;
            entry.error = e.message;
            _log('Even AI: ${e.message}', LogLevel.err);
          } catch (e) {
            entry.error = '$e';
            _log('Even AI transcription failed: $e', LogLevel.err);
          }
        }
      }
      entry.question = q;
      _phase(AiPhase.heard, q: q);
      cfg = deps.settings(); // may have changed while listening

      if (handsFree) {
        if (q.isEmpty) {
          _log('Live translate: nothing heard', LogLevel.warn);
          await _endSession(exit: true);
          _phase(AiPhase.idle);
          return;
        }
        _phase(AiPhase.thinking, q: q);
        try {
          final out = await translateUtterance(q, cfg);
          entry
            ..reply = out
            ..source = 'translate';
          // The Translate app now owns the screen; the Even AI heartbeat only kept the mic
          // session alive, so stop it (no EXIT: that could close what the user is reading).
          await _endSession(exit: false);
          _phase(AiPhase.answered, q: q, r: out);
        } catch (e) {
          entry.error = '$e';
          _log('Live translate failed: $e', LogLevel.err);
          await _endSession(exit: true);
          _phase(AiPhase.error, message: '$e');
        }
        return;
      }

      // Voice shortcuts: a recognised command runs directly, no model round-trip.
      if (cfg.voiceShortcuts && q.isNotEmpty && tools != null) {
        final hit = matchShortcut(q, custom: cfg.customShortcuts);
        if (hit != null) {
          final (action, args) = hit;
          final label = args.isEmpty ? action : '$action $args';
          String text;
          String tag;
          try {
            final r = await tools!.run(action, Map.of(args));
            text = r.isEmpty ? 'Done.' : r;
            tag = label;
          } catch (e) {
            text = "Sorry, I couldn't do that: $e";
            tag = '$label FAILED';
          }
          entry
            ..actions = ['shortcut: $tag']
            ..source = 'shortcut'
            ..reply = text;
          _log('Even AI shortcut: $tag', tag.endsWith('FAILED') ? LogLevel.warn : LogLevel.ok);
          if (cfg.showQuestion) {
            await sendAsk(q);
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
          if (turn.exit) {
            _phase(AiPhase.idle);
            return;
          }
          await sendReply(text, turn: turn);
          _phase(AiPhase.answered, q: q, r: text);
          return;
        }
      }

      final shown = q.isNotEmpty ? q : cfg.fallbackQuestion;
      if (cfg.showQuestion && shown.isNotEmpty) {
        await sendAsk(shown);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      await sendAnalyse();
      _phase(AiPhase.thinking, q: q);

      String answer;
      final stream = ReplyStreamer(
        sendChunk: _sendReplyPart,
        stopped: () {
          if (turn.exit) deps.engines.local?.cancel(); // EXIT on the glasses: stop generating
          return turn.exit;
        },
      );
      if (mode == EvenAiMode.assistant) {
        if (sttProblem != null) {
          answer = sttProblem;
        } else if (q.isEmpty) {
          answer = "Sorry, I didn't catch that.";
        } else {
          try {
            final r = await askAssistant(q, cfg, entry, onDelta: stream.add);
            answer = r.text.isEmpty ? (stream.sent.isEmpty ? '(no answer)' : stream.sent) : r.text;
          } on NotConfigured catch (e) {
            entry.error = e.message;
            answer = '${e.message} (G2 Hub app → AI models).';
          } catch (e) {
            entry.error = '$e';
            _log('Even AI: $e', LogLevel.err);
            answer = 'Sorry, the assistant is unavailable right now.';
          }
        }
      } else {
        answer = cfg.cannedReply.isEmpty ? '(no reply configured)' : cfg.cannedReply;
      }
      entry.reply = answer;
      if (turn.exit) {
        _phase(AiPhase.idle);
        return;
      }
      if (stream.started) {
        // Part of the answer is already on the glasses (on-device model, streamed).
        await stream.finish(answer);
        _armAutoClose(answer);
      } else {
        await sendReply(answer, turn: turn);
      }
      if (turn.exit) {
        _phase(AiPhase.idle);
        return;
      }
      _phase(AiPhase.answered, q: q, r: answer);
    } catch (e) {
      entry.error ??= '$e';
      if (_disposed) {
        _log('Even AI: turn ended (glasses disconnected)');
      } else {
        _log('Even AI turn failed: $e', LogLevel.err);
        await _endSession(exit: true);
        _phase(AiPhase.error, message: '$e');
      }
    } finally {
      _turn = null;
      if (mode != EvenAiMode.open) deps.addHistory(entry);
    }
  }

  static String? _sttLanguage(AiSettings cfg, bool handsFree) {
    final p = cfg.sttById(cfg.sttProfileId);
    if (p != null && p.language.isNotEmpty) return p.language;
    return handsFree ? cfg.translateSrc.toLowerCase() : null;
  }

  /// Collect mic packets until the user stops talking (silence detector on the left lens,
  /// or the right one if the left does not stream), VAD_END / EXIT, or [max]. The mic
  /// subscription is always released.
  Future<List<MicPacketIn>> _capture(_Turn turn, Duration max) async {
    final packets = <MicPacketIn>[];
    final cfg = deps.settings();
    final silero = deps.vad;
    EndOfSpeech vad;
    try {
      vad = silero != null && cfg.vadEngine == 'silero' ? await silero.endOfSpeech(cfg.evenAiVad) : SilenceDetector();
    } catch (_) {
      vad = SilenceDetector();
    }
    final stream = Lc3Stream();
    LensSide? vadSide;
    var rightOnly = 0;
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    var quietTicks = 0;
    const tick = Duration(milliseconds: 250);
    final sub = link.mic.packets.listen((p) {
      quietTicks = 0;
      packets.add(p);
      if (vadSide == null) {
        if (p.side == LensSide.left) {
          vadSide = LensSide.left;
        } else if (++rightOnly >= 20) {
          vadSide = LensSide.right; // 1 s of right-only audio: the left lens is silent
        }
      }
      if (p.side == vadSide && !done.isCompleted && vad.feedPcm(stream.decode(p.data))) {
        _log('Even AI: ${vad.heardSpeech ? 'end of speech' : 'no speech'} detected after '
            '${vad.elapsed.toStringAsFixed(1)} s (${vad.kind})');
        finish();
      }
    });
    final stall = Timer.periodic(tick, (_) {
      if (++quietTicks * tick.inMilliseconds >= micStall.inMilliseconds) {
        turn.micStalled = true;
        _log('Even AI: the glasses microphone sent no audio for ${micStall.inSeconds} s; stopped listening', LogLevel.warn);
        finish();
      }
    });
    final poke = turn._changed.stream.listen((_) {
      if (turn.vadEnd || turn.exit) finish();
    });
    final timer = Timer(max, finish);
    try {
      await link.mic.start();
      await done.future;
    } finally {
      timer.cancel();
      stall.cancel();
      vad.close();
      unawaited(poke.cancel());
      unawaited(sub.cancel());
      try {
        await link.mic.stop();
      } catch (e) {
        _log('Even AI: could not stop the mic stream: $e', LogLevel.warn);
      }
    }
    return packets;
  }

  /// Hub decode_packets: the left lens if it streamed, else the right. (pcm, lens, count).
  static (Int16List, LensSide?, int) decodePackets(List<MicPacketIn> packets) {
    if (packets.isEmpty) return (Int16List(0), null, 0);
    final side = packets.any((p) => p.side == LensSide.left) ? LensSide.left : LensSide.right;
    final chosen = packets.where((p) => p.side == side).toList();
    final s = Lc3Stream();
    final parts = [for (final p in chosen) s.decode(p.data)];
    final out = Int16List(parts.fold(0, (a, b) => a + b.length));
    var o = 0;
    for (final p in parts) {
      out.setAll(o, p);
      o += p.length;
    }
    return (out, side, chosen.length);
  }

  // ── assistant / translate ──────────────────────────────────────────────────────────────
  /// [onDelta]: reply text as it is generated (on-device models stream; cloud ones don't).
  Future<AssistantReply> askAssistant(String q, AiSettings cfg, AiHistoryEntry? entry, {void Function(String)? onDelta}) async {
    final (engine, profile) = await deps.engines.assistant(cfg, onFallback: (m) => _log('Even AI: $m', LogLevel.warn));
    final useTools = cfg.tools && profile.toolsEnabled && tools != null;
    if (cfg.tools && !engine.caps.toolCalling) _log('Even AI: this model has no tool calling; answering without tools');
    final local = profile.provider == LlmProvider.local;
    final r = await responder.ask(
      q,
      engine: engine,
      onDelta: onDelta,
      system: profile.systemPrompt.trim().isNotEmpty
          ? profile.systemPrompt
          : local
              ? localSystemPrompt(tools: useTools && engine.caps.toolCalling)
              : defaultSystemPrompt,
      maxTokens: profile.maxTokens,
      temperature: profile.temperature,
      effort: profile.effort,
      tools: useTools ? glassesTools : const [],
      runTool: useTools ? tools!.run : null,
    );
    for (final a in r.actions) {
      _log('Even AI tool: $a', a.endsWith('FAILED') ? LogLevel.warn : LogLevel.ok);
    }
    if (entry != null) {
      entry.model = r.model.isEmpty ? profile.model : r.model;
      if (r.actions.isNotEmpty) entry.actions = r.actions;
    }
    return r;
  }

  /// Hub translate_utterance: translate, open the glasses Translate app if needed, show
  /// original + translation.
  Future<String> translateUtterance(String text, AiSettings cfg) async {
    final engine = await deps.engines.translation(cfg, onFallback: (m) => _log('Translate: $m', LogLevel.warn));
    final out = await engine.translate(text, cfg.translateSrc, cfg.translateDst);
    final d = display;
    if (d != null) await d.show(cfg.translateSrc, cfg.translateDst, text, out);
    _log('Live translate ${cfg.translateSrc}>${cfg.translateDst}: "$text" -> "$out"', LogLevel.ok);
    return out;
  }

  /// Typed question from the app (hub /api/ai_try, fixed): refuses clearly when Even AI is
  /// set to give no answer, never touches the glasses, and is logged as 'typed'.
  Future<AssistantReply> tryIt(String question) async {
    question = question.trim();
    if (question.isEmpty) throw AiError('Type a question first');
    final cfg = deps.settings();
    if (cfg.mode != EvenAiMode.autoReply && cfg.mode != EvenAiMode.assistant) {
      throw AiError('Even AI is set to give no answer. Choose "Auto-reply" or "AI assistant" under '
          '"When Even AI wakes", then try again.');
    }
    final entry = AiHistoryEntry(source: 'typed', mode: cfg.mode.name, question: question);
    try {
      final r = cfg.mode == EvenAiMode.assistant
          ? await askAssistant(question, cfg, entry)
          : AssistantReply(cfg.cannedReply);
      entry.reply = r.text;
      return r;
    } catch (e) {
      entry.error = '$e';
      rethrow;
    } finally {
      deps.addHistory(entry);
    }
  }
}

/// Streams a reply that is still being generated to the glasses as REPLY chunks: text is
/// sent in pieces that end at a sentence boundary (or every ~400 bytes), never flagged as the
/// last chunk; [finish] sends the rest with the end flag. Sends are serialised.
class ReplyStreamer {
  ReplyStreamer({required this.sendChunk, required this.stopped, this.minChars = 40, this.maxChars = 400});
  final Future<void> Function(String text, bool last) sendChunk;
  final bool Function() stopped;
  final int minChars;
  final int maxChars;

  final StringBuffer _pending = StringBuffer();
  final StringBuffer _sent = StringBuffer();
  Future<void> _chain = Future<void>.value();
  bool _finished = false;

  bool get started => _sent.isNotEmpty;
  String get sent => _sent.toString();

  static final RegExp _boundary = RegExp(r'[.!?。！？\n]\s*');

  void add(String delta) {
    if (_finished || stopped()) return;
    _pending.write(delta);
    final p = _pending.toString();
    var cut = -1;
    if (p.length >= minChars) {
      for (final m in _boundary.allMatches(p)) {
        cut = m.end;
      }
    }
    if (cut < 0 && p.length >= maxChars) cut = p.lastIndexOf(' ') > 0 ? p.lastIndexOf(' ') + 1 : p.length;
    if (cut <= 0) return;
    final piece = p.substring(0, cut);
    _pending
      ..clear()
      ..write(p.substring(cut));
    _sent.write(piece);
    _chain = _chain.then((_) => stopped() ? null : sendChunk(piece, false));
  }

  /// Send what is left of [full] (the final answer) as the last chunk.
  Future<void> finish(String full) async {
    _finished = true;
    await _chain;
    if (stopped()) return;
    final s = sent;
    await sendChunk(full.startsWith(s) ? full.substring(s.length) : _pending.toString(), true);
  }
}
