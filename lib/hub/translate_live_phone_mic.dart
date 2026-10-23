/// Phone-microphone PCM source for conversation translate (the hub's SoundDeviceSource), and
/// the Android foreground-service switch it needs.
///
/// Android 14+ only lets an app keep the microphone in the background from a foreground
/// service of type `microphone`, started while the app is visible and RECORD_AUDIO is granted.
/// The app's service normally runs as `connectedDevice` only (the glasses link); while the
/// phone mic is listening it is restarted as `connectedDevice|microphone`, and switched back
/// (or stopped, if the glasses are not connected) as soon as listening ends — so the mic type,
/// and the privacy indicator, are only active while the user is translating.
/// The glasses mic arrives over BLE and needs no microphone service type.
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:record/record.dart';

import '../ai/audio/pcm.dart';
import '../ai/audio/vad.dart';
import 'background_service.dart' show g2ServiceCallback;
import 'translate_live.dart';

class PhoneMicSource implements PcmSource {
  PhoneMicSource({this.onStarted, this.onStopped});

  /// Called after the mic opened / closed (foreground-service type switch).
  final Future<void> Function()? onStarted;
  final Future<void> Function()? onStopped;

  AudioRecorder? _rec;
  StreamSubscription<Uint8List>? _sub;
  final _blocks = StreamController<Int16List>();
  StreamIterator<Int16List>? _it;
  final _reblock = Reblocker();
  final List<int> _odd = [];

  @override
  String get name => 'phone';

  @override
  Future<void> start() async {
    final rec = AudioRecorder();
    if (!await rec.hasPermission()) {
      await rec.dispose();
      throw MicUnavailable('Microphone permission is needed for conversation translate (Android Settings → Apps → G2 Hub → Permissions).');
    }
    Stream<Uint8List> stream;
    try {
      stream = await rec.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        androidConfig: AndroidRecordConfig(audioSource: AndroidAudioSource.voiceRecognition, manageBluetooth: false),
      ));
    } catch (e) {
      await rec.dispose();
      throw MicUnavailable('Could not open the phone microphone: $e');
    }
    _rec = rec;
    _sub = stream.listen((bytes) {
      // Keep sample alignment across chunk boundaries.
      _odd.addAll(bytes);
      final even = _odd.length & ~1;
      final pcm = pcmSamples(_odd.sublist(0, even));
      _odd.removeRange(0, even);
      for (final b in _reblock.add(pcm)) {
        _blocks.add(b);
      }
    }, onError: (Object e) => _blocks.addError(MicUnavailable('Microphone error: $e')));
    _it = StreamIterator(_blocks.stream);
    await onStarted?.call();
  }

  @override
  Future<Int16List> read() async {
    final it = _it;
    if (it == null || !await it.moveNext()) throw MicUnavailable('The phone microphone stopped');
    return it.current;
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _rec?.stop();
      await _rec?.dispose();
    } catch (_) {}
    _rec = null;
    await _blocks.close();
    await onStopped?.call();
  }
}

/// The plugin calls [MicForegroundService] makes (a seam for tests).
abstract class ForegroundBackend {
  Future<void> restart(List<ForegroundServiceTypes> types, String title, String text);
  Future<void> stop();
}

class _PluginForeground implements ForegroundBackend {
  static const int _serviceId = 4762; // same service as BackgroundLink
  @override
  Future<void> restart(List<ForegroundServiceTypes> types, String title, String text) async {
    if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
    await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: types,
      notificationTitle: title,
      notificationText: text,
      callback: g2ServiceCallback,
    );
  }

  @override
  Future<void> stop() async => FlutterForegroundTask.stopService();
}

/// Foreground-service type switching (Android). No-ops elsewhere.
class MicForegroundService {
  /// Tests replace the plugin.
  static ForegroundBackend? backendOverride;
  static final ForegroundBackend _plugin = _PluginForeground();
  static ForegroundBackend get _backend => backendOverride ?? _plugin;
  static bool get _supported => backendOverride != null || (!kIsWeb && Platform.isAndroid);

  /// Switches run one after another, in call order: a quick start → stop must never end with
  /// the stop's switch finishing first and the microphone type left on.
  static Future<void> _chain = Future<void>.value();

  static Future<void> _serial(Future<void> Function() op) {
    final next = _chain.then((_) async {
      try {
        await op();
      } catch (_) {}
    });
    _chain = next;
    return next;
  }

  /// The phone mic is listening: add the `microphone` type.
  static Future<void> micOn() async {
    if (!_supported) return;
    await _serial(() => _backend.restart([ForegroundServiceTypes.connectedDevice, ForegroundServiceTypes.microphone],
        'Live translate is listening', 'Using the phone microphone'));
  }

  /// Listening ended: back to the glasses-link service, or none.
  static Future<void> micOff({required bool glassesConnected}) async {
    if (!_supported) return;
    await _serial(() => glassesConnected
        ? _backend.restart([ForegroundServiceTypes.connectedDevice], 'Connected to Even G2', 'Keeping the glasses link alive')
        : _backend.stop());
  }
}
