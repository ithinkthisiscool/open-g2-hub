/// One live connection to a pair of G2 glasses: both lenses, auth, the official app's connect
/// sequence, ack routing, the EvenHub heartbeat and the 60 s keep-alive to both lenses.
///
/// Port of g2/transport/session.py (GlassesSession) plus g2-hub/hub/connection.py
/// (_post_connect_prelude, run_connect_sequence, maintenance_loop). The order, timing and
/// counters (magic from 101, frame seq from 11) match the Python hub, which
/// test/session_flow_test.dart checks frame-for-frame against tool/gen_vectors.py.
library;

import 'dart:async';
import 'dart:typed_data';

import '../ble/lens_ad.dart';
import '../ble/lens_link.dart';
import '../protocol/app_sync.dart' as app_sync;
import '../protocol/dashboard.dart' as dash;
import '../protocol/device.dart' as dev;
import '../protocol/evenhub.dart' as eh;
import '../protocol/file_service.dart' as fs;
import '../protocol/framing.dart';
import '../protocol/pb.dart';
import '../protocol/settings.dart' as st;

enum LogLevel { info, ok, warn, err }

class SessionLog {
  SessionLog(this.level, this.message) : at = DateTime.now();
  final LogLevel level;
  final String message;
  final DateTime at;
  @override
  String toString() => '[${level.name}] $message';
}

/// A frame received from a lens (already reassembled).
class RxFrame {
  RxFrame(this.side, this.sid, this.flag, this.payload);
  final LensSide side;
  final int sid;
  final int flag;
  final Uint8List payload;
}

/// What the app shows about the glasses (updated from read-backs and pushes).
class GlassesStatus {
  int? battery;
  bool? charging;
  String? leftVersion;
  String? rightVersion;
  int? caseBattery;
  bool? worn;
  bool? silentMode;
  int? brightnessLevel;
  bool? brightnessAuto;
  int? headUpAngle;
  int? foregroundApp;
  int? displayTimeout;
  DateTime? lastKeepaliveEcho;
}

enum SessionState { idle, connecting, connected, closing, closed }

/// One frame on the wire (Developer mode console / raw frame inspector).
class WireFrame {
  WireFrame(this.rx, this.side, this.sid, this.flag, this.payload) : at = DateTime.now();
  final bool rx;
  final LensSide side;
  final int sid;
  final int flag;
  final Uint8List payload;
  final DateTime at;
}

class G2Session {
  G2Session({
    required this.right,
    required this.left,
    DateTime Function()? clock,
    int Function(int epochSeconds)? tzUnits,
  })  : _clock = clock ?? DateTime.now,
        _tzUnits = tzUnits ?? dev.localTzUnits;

  final LensLink right;
  final LensLink left;
  final DateTime Function() _clock;
  final int Function(int) _tzUnits;

  // Timing copied from the Python hub (seconds there, Durations here).
  static const heartbeatInterval = Duration(seconds: 4);
  static const packetGap = Duration(milliseconds: 50);
  static const connectSequenceGap = Duration(milliseconds: 150);
  static const preludeDrain = Duration(milliseconds: 1500);
  static const settle = Duration(milliseconds: 300);
  static const keepaliveEchoWait = Duration(seconds: 5);

  int _magic = 100;
  int _seq = 10;
  /// Message magic: 1..255, wrapping, never 0 (the firmware's decoder drops a 1-byte magic above 255).
  int nextMagic() => _magic = _magic % 255 + 1;
  int nextSeq() => _seq = (_seq + 1) % 256;

  final _asm = {LensSide.right: FrameAssembler(), LensSide.left: FrameAssembler()};
  final _pending = <int, Completer<Uint8List>>{};
  final _locks = <LensSide, Future<void>>{};
  final _subs = <StreamSubscription<Object?>>[];
  Timer? _hbTimer;
  bool _maintenanceRunning = false;
  int _missedKeepalives = 0;
  DateTime _lastTimeSync = DateTime.fromMillisecondsSinceEpoch(0);

  final status = GlassesStatus();
  SessionState state = SessionState.idle;

  final _rx = StreamController<RxFrame>.broadcast();
  final _log = StreamController<SessionLog>.broadcast();
  final _statusChanged = StreamController<GlassesStatus>.broadcast();
  final _linkLost = StreamController<String>.broadcast();
  final _wire = StreamController<WireFrame>.broadcast();
  final _fileReplies = StreamController<(int, int)>.broadcast();
  StreamSubscription<Uint8List>? _fileSub;
  bool _fileOn = false;
  Future<void> _fileLock = Future<void>.value();

  /// Display time (s) sent with the notification enable on connect.
  int notificationDispTime = 5;

  /// Every frame sent or received (for the Developer console). Read-only tap.
  Stream<WireFrame> get wire => _wire.stream;

  /// EvenFile replies (cid, rsp) from 0x7402 or the control channel.
  Stream<(int, int)> get fileReplies => _fileReplies.stream;

  void _tap(bool rx, LensSide side, int sid, int flag, Uint8List payload) {
    if (!_wire.isClosed && _wire.hasListener) _wire.add(WireFrame(rx, side, sid, flag, payload));
  }

  /// Every frame from either lens (after reassembly). Read-only tap; never steals acks.
  Stream<RxFrame> get frames => _rx.stream;
  Stream<SessionLog> get logs => _log.stream;
  Stream<GlassesStatus> get statusChanges => _statusChanged.stream;

  /// Fires with a reason when a lens drops or the keep-alive watchdog gives up.
  Stream<String> get linkLost => _linkLost.stream;

  bool get isConnected => right.isConnected && left.isConnected && state == SessionState.connected;
  bool get heartbeatRunning => _hbTimer != null;

  void log(String m, [LogLevel l = LogLevel.info]) {
    if (!_log.isClosed) _log.add(SessionLog(l, m));
  }

  LensLink _link(LensSide s) => s == LensSide.right ? right : left;

  // ── connect ─────────────────────────────────────────────────────────────────────────────
  /// Connect both lenses (concurrently), subscribe, authenticate both, send the prelude and
  /// start the EvenHub heartbeat (GlassesSession.connect(launch_app=True, skip_page=True)).
  Future<void> connect() async {
    state = SessionState.connecting;
    log('Connecting right ${right.deviceId} + left ${left.deviceId}...');
    await Future.wait([right.connect(), left.connect()]);
    _checkOpen();
    for (final side in LensSide.values) {
      final link = _link(side);
      _subs.add(link.notifications.listen((p) => _onPacket(side, p)));
      _subs.add(link.connectionChanges.listen((up) {
        if (!up && state == SessionState.connected) {
          log('Link lost: ${side.name} lens disconnected', LogLevel.err);
          _linkLost.add('${side.name} lens disconnected');
        }
      }));
    }
    await Future<void>.delayed(settle);
    _checkOpen();

    // Auth: right first (wait for its reply), then left (fire-and-forget), like the hub.
    final firstReply = frames.where((f) => f.side == LensSide.right).first..ignore();
    final (_, authR) = authFrame();
    await right.write(authR);
    try {
      final rx = await firstReply.timeout(const Duration(seconds: 5));
      final ok = rx.payload.length >= 6 &&
          rx.payload[rx.payload.length - 2] == 0x1A &&
          rx.payload[rx.payload.length - 1] == 0x00;
      log('auth right: ${ok ? 'OK' : '? ${hex(rx.payload)}'}', ok ? LogLevel.ok : LogLevel.warn);
    } on TimeoutException {
      log('auth right: no reply (is the lens bonded? close the official Even app)', LogLevel.warn);
    }
    final (_, authL) = authFrame();
    await left.write(authL);
    log('auth left: sent');
    await Future<void>.delayed(settle);

    _checkOpen();
    log('Sending prelude...');
    await _sendFrames(LensSide.right, [eh.preludeFrame]);
    await Future<void>.delayed(preludeDrain);
    _checkOpen();
    startHeartbeat();
    state = SessionState.connected;
    log('Session up. Heartbeat running.', LogLevel.ok);
  }

  /// [close] ran while [connect] was waiting: stop here (a closed session never comes back as
  /// connected, and no new listeners are added to the lenses after close cancelled the others).
  void _checkOpen() {
    if (state == SessionState.closing || state == SessionState.closed) throw StateError('session closed while connecting');
  }

  /// The hub's post-connect work: prelude again, dashboard init (display_mode 4), app-sync
  /// subscribe, the official app's connect sequence + notification enable/whitelist, then the
  /// keep-alive maintenance loop.
  Future<void> postConnect() async {
    await _sendFrames(LensSide.right, [eh.preludeFrame]);
    await Future<void>.delayed(preludeDrain);
    log('Prelude sent (dashboard init, commandId=2, magic=156)');
    final mInit = nextMagic();
    final ack = await request(dash.sidDashboardCh, dash.buildDashboardInit(mInit), mInit,
        label: 'dashboard init', timeout: const Duration(seconds: 4));
    final flag = dash.ackFlag(ack);
    log('Dashboard init (display_mode=4): flag=$flag', flag == 0 ? LogLevel.ok : LogLevel.warn);
    final mSub = nextMagic();
    await send(app_sync.sid, app_sync.buildSubscribe(mSub));
    log('SID=0x0d subscribed (content-state notifications)');
    await runConnectSequence();
    _lastTimeSync = _clock();
    unawaited(_maintenanceLoop());
  }

  Future<void> runConnectSequence() async {
    final now = _clock().millisecondsSinceEpoch ~/ 1000;
    final steps = dev.connectSequence(nextMagic, now: now, tzUnits: _tzUnits(now));
    // Notifications are dropped unless notifEnable is set, and the glasses forget it on reboot.
    steps.add(dev.Step(fs.sidNotificationCh, fs.buildNotificationCtrl(nextMagic(), dispTime: notificationDispTime), dev.Lens.right));
    steps.add(dev.Step(fs.sidNotificationCh, fs.buildWhitelistDisable(nextMagic()), dev.Lens.right));
    for (final s in steps) {
      if (state != SessionState.connected) return;
      await sendFramed(s.sid, s.payload, s.lens);
      await Future<void>.delayed(connectSequenceGap);
    }
    log('Connect sequence sent (${steps.length} steps: role, time sync, settings read, units, '
        'onboarding finish, wear check, case, gestures, notifications)', LogLevel.ok);
  }

  // ── keep-alive ──────────────────────────────────────────────────────────────────────────
  Future<void> _maintenanceLoop() async {
    if (_maintenanceRunning) return;
    _maintenanceRunning = true;
    status.lastKeepaliveEcho = _clock();
    try {
      while (state == SessionState.connected) {
        await Future<void>.delayed(dev.keepaliveInterval);
        if (state != SessionState.connected) break;
        final sentAt = _clock();
        final steps = dev.keepaliveSteps(nextMagic);
        for (var n = 0; n < steps.length; n++) {
          await sendFramed(steps[n].sid, steps[n].payload, steps[n].lens);
          if (n == 0) await Future<void>.delayed(dev.keepaliveLeftLead);
        }
        await Future<void>.delayed(keepaliveEchoWait);
        if (state != SessionState.connected) break;
        final echo = status.lastKeepaliveEcho;
        if (echo != null && !echo.isBefore(sentAt)) {
          _missedKeepalives = 0;
        } else {
          _missedKeepalives += 1;
          log('Keep-alive: no echo from the right lens ($_missedKeepalives/2)', LogLevel.warn);
          if (_missedKeepalives >= 2) {
            log('Keep-alive: link looks dead — reconnecting', LogLevel.err);
            _linkLost.add('keep-alive watchdog');
            break;
          }
        }
        if (_clock().difference(_lastTimeSync) > const Duration(hours: 1)) {
          final t = _clock().millisecondsSinceEpoch ~/ 1000;
          await sendFramed(dev.sid, dev.buildTimeSync(nextMagic(), now: t, tzUnits: _tzUnits(t)));
          _lastTimeSync = _clock();
        }
      }
    } catch (e) {
      log('Maintenance loop stopped: $e', LogLevel.warn);
    } finally {
      _maintenanceRunning = false;
    }
  }

  // ── EvenHub heartbeat ───────────────────────────────────────────────────────────────────
  /// (Re)start the EvenHub heartbeat (SID 0xE0 every 4 s). SID 0x01 pushes are only accepted
  /// while it runs. Returns true if it was started now.
  bool startHeartbeat() {
    if (_hbTimer != null || state == SessionState.closing || state == SessionState.closed) return false;
    _hbTimer = Timer.periodic(heartbeatInterval, (_) {
      final m = nextMagic();
      final hb = eh.buildHeartbeat(m);
      _tap(false, LensSide.right, eh.sidEvenHubCh, flagRequest, hb);
      _sendFrames(LensSide.right, framePb(hb, eh.sidEvenHubCh, flagRequest, nextSeq()))
          .catchError((Object _) {});
    });
    return true;
  }

  /// Stop the heartbeat: the native dashboard takes the screen back ~5 s later and shows
  /// freshly pushed widgets. Returns true if it was running.
  bool stopHeartbeat() {
    final t = _hbTimer;
    _hbTimer = null;
    t?.cancel();
    return t != null;
  }

  // ── sending ─────────────────────────────────────────────────────────────────────────────
  /// Write packets to one lens, keeping a multi-packet message contiguous (50 ms gap between
  /// packets, none after the last).
  Future<void> _sendFrames(LensSide side, List<Uint8List> packets) {
    final link = _link(side);
    final prev = _locks[side] ?? Future<void>.value();
    final next = prev.then((_) async {
      for (var n = 0; n < packets.length; n++) {
        if (n > 0) await Future<void>.delayed(packetGap);
        await link.write(packets[n]);
      }
    });
    _locks[side] = next.catchError((Object _) {});
    return next;
  }

  /// Frame [payload] for [sid] with flag 0x20 and send without waiting (session.send).
  Future<void> send(int sid, Uint8List payload, {dev.Lens lens = dev.Lens.right, int flag = flagRequest}) async {
    if (lens != dev.Lens.left) {
      _tap(false, LensSide.right, sid, flag, payload);
      await _sendFrames(LensSide.right, framePb(payload, sid, flag, nextSeq()));
    }
    if (lens != dev.Lens.right) {
      _tap(false, LensSide.left, sid, flag, payload);
      await _sendFrames(LensSide.left, framePb(payload, sid, flag, nextSeq()));
    }
  }

  /// Frame with the flag the official app uses (device.flag_for) and send (hub send_framed).
  Future<void> sendFramed(int sid, Uint8List payload, [dev.Lens lens = dev.Lens.right]) =>
      send(sid, payload, lens: lens, flag: dev.flagFor(sid, payload));

  /// Send to the right lens and wait for the reply echoing (sid, magic); null on timeout.
  Future<Uint8List?> request(int sid, Uint8List payload, int magic,
      {String label = 'request', Duration timeout = const Duration(seconds: 3)}) async {
    final key = (sid << 40) ^ magic;
    final c = Completer<Uint8List>();
    _pending[key] = c;
    try {
      _tap(false, LensSide.right, sid, flagRequest, payload);
      await _sendFrames(LensSide.right, framePb(payload, sid, flagRequest, nextSeq()));
      return await c.future.timeout(timeout);
    } on TimeoutException {
      log('no ack for $label (sid=0x${sid.toRadixString(16).padLeft(2, '0')} magic=$magic)', LogLevel.warn);
      return null;
    } finally {
      if (identical(_pending[key], c)) _pending.remove(key);
    }
  }

  // ── receiving ───────────────────────────────────────────────────────────────────────────
  void _onPacket(LensSide side, Uint8List packet) {
    final data = _asm[side]!.feed(packet);
    if (data == null) return;
    final parsed = parseFrame(data);
    if (parsed == null) return;
    if (side == LensSide.right && _pending.isNotEmpty) {
      final magic = readAckMagic(parsed.payload);
      if (magic != null) {
        final c = _pending.remove((parsed.sid << 40) ^ magic);
        if (c != null && !c.isCompleted) c.complete(parsed.payload);
      }
    }
    _tap(true, side, parsed.sid, parsed.flag, parsed.payload);
    if (side == LensSide.right && (parsed.sid == 0xC4 || parsed.sid == 0xC5) && parsed.payload.length >= 2) {
      if (!_fileReplies.isClosed) _fileReplies.add((parsed.payload[0], parsed.payload[1]));
    }
    try {
      _track(side, parsed);
    } catch (e) {
      log('decode error sid=0x${parsed.sid.toRadixString(16)}: $e', LogLevel.warn);
    }
    if (!_rx.isClosed) _rx.add(RxFrame(side, parsed.sid, parsed.flag, parsed.payload));
  }

  /// Update [status] from read-backs and pushes.
  void _track(LensSide side, ParsedFrame f) {
    var changed = false;
    switch (f.sid) {
      case st.sidSettings:
        final d = st.decode(f.payload);
        final v = d['values'] as Map<String, Object?>?;
        if (v != null) {
          if (v['battery'] is int) status.battery = v['battery'] as int;
          if (v.containsKey('battery')) status.charging = (v['charging'] ?? 0) == 1;
          if (v['left_version'] is String) status.leftVersion = v['left_version'] as String;
          if (v['right_version'] is String) status.rightVersion = v['right_version'] as String;
          if (v.containsKey('battery')) status.silentMode = (v['silent_mode'] ?? 0) == 1;
          if (v['brightness_level'] is int) status.brightnessLevel = v['brightness_level'] as int;
          if (v.containsKey('battery')) status.brightnessAuto = (v['brightness_auto'] ?? 0) == 1;
          if (v['head_up_angle'] is int) status.headUpAngle = v['head_up_angle'] as int;
          changed = true;
        }
      case dev.sidCase:
        final c = dev.decodeCase(f.payload);
        if (c != null && c['battery'] != null) {
          status.caseBattery = c['battery'] as int;
          changed = true;
        }
      case dev.sidOnboarding:
        final o = dev.decodeOnboarding(f.payload);
        if (o['worn'] != null) {
          status.worn = o['worn'] as bool;
          changed = true;
        }
      case app_sync.sid:
        final a = app_sync.decode(f.payload);
        if (a['foreground'] != null) {
          status.foregroundApp = a['foreground'] as int;
          changed = true;
        }
      case dev.sid:
        final d = dev.decode(f.payload);
        if (d['cmd'] == dev.cmdKeepalive && side == LensSide.right) status.lastKeepaliveEcho = _clock();
      case st.sidModule:
        final m = st.decodeModule(f.payload);
        if (m['timeout'] != null) {
          status.displayTimeout = m['timeout'] as int;
          changed = true;
        }
    }
    if (changed && !_statusChanged.isClosed) _statusChanged.add(status);
  }

  /// Ask for battery / firmware / settings (reply updates [status]).
  Future<void> readSettings() async {
    await sendFramed(st.sidSettings, st.buildReadSettings(nextMagic()));
    await sendFramed(dev.sidCase, dev.buildCaseInfoQuery(nextMagic()));
  }

  // ── EvenFile channel (0x7401 / 0x7402) ───────────────────────────────────────────────────
  /// Subscribe to the file notify characteristic on the right lens (idempotent).
  Future<void> enableFileChannel() async {
    if (_fileOn) return;
    await right.enableFileChannel();
    _fileSub ??= right.fileNotifications.listen((p) {
      final f = parseFrame(p);
      if (f == null) return;
      _tap(true, LensSide.right, f.sid, f.flag, f.payload);
      if (f.payload.length >= 2 && !_fileReplies.isClosed) _fileReplies.add((f.payload[0], f.payload[1]));
    });
    _fileOn = true;
  }

  /// Write raw EFS frames to 0x7401, [gap] apart, never interleaved with another transfer.
  Future<void> sendFileFrames(List<Uint8List> frames, {Duration gap = const Duration(milliseconds: 10)}) {
    final next = _fileLock.then((_) async {
      for (final f in frames) {
        if (f.length > 7) _tap(false, LensSide.right, f[6], f[7], f.length > 10 ? Uint8List.sublistView(f, 8, f.length - 2) : Uint8List(0));
        await right.writeFile(f);
        await Future<void>.delayed(gap);
      }
    });
    _fileLock = next.catchError((Object _) {});
    return next;
  }

  // ── teardown ────────────────────────────────────────────────────────────────────────────
  Future<void> close() async {
    if (state == SessionState.closed) return;
    state = SessionState.closing;
    stopHeartbeat();
    // Cancelling stops delivery right away; the returned futures are not awaited (they belong to
    // the root zone, which made close() hang under fake time in tests).
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('session closed'));
    }
    _pending.clear();
    await Future.wait([right.disconnect(), left.disconnect()]).timeout(const Duration(seconds: 6), onTimeout: () => []);
    state = SessionState.closed;
    log('Disconnected');
    await _rx.close();
    await _statusChanged.close();
    await _linkLost.close();
    unawaited(_fileSub?.cancel());
    await _wire.close();
    await _fileReplies.close();
    await _log.close();
  }
}
