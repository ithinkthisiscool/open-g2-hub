/// In-memory diagnostics for "Report a problem" (lib/services/diagnostics_report.dart):
///
/// * recent uncaught errors with their stack traces (Flutter framework errors, uncaught async
///   errors), recorded by hooks that chain to whatever handler was installed before, so crash
///   and logging behaviour stays exactly as it was;
/// * Even AI / live-translate state-machine events (phase changes, commands, start/stop) —
///   never the words spoken, asked, answered or translated.
///
/// Everything here lives only in RAM (ring buffers) and leaves the phone only when the user
/// shares a report, after scrubbing.
library;

import 'dart:collection';

import 'package:flutter/foundation.dart';

/// One uncaught error.
class RecordedError {
  RecordedError(this.at, this.source, this.error, this.stack);
  final DateTime at;

  /// 'flutter' (FlutterError.onError) or 'async' (PlatformDispatcher.onError: uncaught errors
  /// of futures, streams and timers in the root zone).
  final String source;
  final String error;
  final String stack;
}

/// One Even AI / translate state event. [event] is a fixed word or name (a phase, a command
/// label), never user content.
class AiEvent {
  AiEvent(this.at, this.component, this.event);
  final DateTime at;
  final String component;
  final String event;
}

class DiagnosticsRecorder {
  DiagnosticsRecorder({this.maxErrors = 30, this.maxAiEvents = 200, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// The app-wide recorder (hooks installed in main.dart write here).
  static final DiagnosticsRecorder instance = DiagnosticsRecorder();

  final int maxErrors;
  final int maxAiEvents;
  final DateTime Function() _clock;
  final _errors = ListQueue<RecordedError>();
  final _ai = ListQueue<AiEvent>();

  List<RecordedError> get errors => List.unmodifiable(_errors);
  List<AiEvent> get aiEvents => List.unmodifiable(_ai);

  void recordError(Object error, StackTrace? stack, {String source = 'async'}) {
    String text;
    try {
      text = '$error';
    } catch (_) {
      text = error.runtimeType.toString();
    }
    _errors.addLast(RecordedError(_clock(), source, text, (stack ?? StackTrace.empty).toString()));
    while (_errors.length > maxErrors) {
      _errors.removeFirst();
    }
  }

  void recordFlutterError(FlutterErrorDetails d) => recordError(d.exception, d.stack, source: 'flutter');

  /// [event] must be a fixed label (no user text).
  void ai(String component, String event) {
    _ai.addLast(AiEvent(_clock(), component, event));
    while (_ai.length > maxAiEvents) {
      _ai.removeFirst();
    }
  }

  void clear() {
    _errors.clear();
    _ai.clear();
  }

  // ── hooks ────────────────────────────────────────────────────────────────────────────────
  bool _installed = false;

  /// Record Flutter framework errors and uncaught async errors. Both handlers chain to the one
  /// installed before (FlutterError.presentError by default), and the dispatcher hook returns
  /// what the previous one returned (false = not handled, so the engine still reports it), so
  /// nothing changes about how errors are shown or whether the app crashes.
  void installHooks({PlatformDispatcher? dispatcher}) {
    if (_installed) return;
    _installed = true;
    final prevFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      recordFlutterError(details);
      (prevFlutter ?? FlutterError.presentError)(details);
    };
    final pd = dispatcher ?? PlatformDispatcher.instance;
    final prevAsync = pd.onError;
    pd.onError = (error, stack) {
      recordError(error, stack, source: 'async');
      return prevAsync?.call(error, stack) ?? false;
    };
  }

  @visibleForTesting
  void resetHooksForTest() => _installed = false;
}
