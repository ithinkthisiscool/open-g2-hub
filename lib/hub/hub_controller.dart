/// App-level state: persisted data, the connection loop (connect, post-connect, profile restore,
/// reconnect with backoff), the Android foreground service and the log. The UI listens to it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/lens_ad.dart';
import '../ble/lens_link.dart';
import '../protocol/hub_format.dart';
import '../services/hub_services.dart';
import '../services/net.dart';
import 'background_service.dart';
import 'features.dart';
import 'glasses_session.dart';
import 'models.dart';

enum LinkStatus { noGlasses, disconnected, connecting, connected }

/// One step of the connection state machine (Report a problem: connection history).
class ConnEvent {
  ConnEvent(this.event, {this.detail = '', this.attempt = 0}) : at = DateTime.now();
  final DateTime at;

  /// connecting · connected · connect_failed · link_lost · retry_scheduled · superseded ·
  /// disconnect · hand_off · take_back
  final String event;
  final String detail;
  final int attempt;
}

class HubController extends ChangeNotifier {
  HubController({LensLink Function(String id, LensSide side)? linkFactory, this.net})
      : _linkFactory = linkFactory ?? ((id, side) => UniversalBleLens(id, side)) {
    // Service-side changes (a weather / news error, notification access re-checked on resume,
    // a profile applied by the schedule) refresh the tiles like any other change.
    services.addListener(notifyListeners);
  }
  /// Network for public data (tests inject a fake).
  final Net? net;

  static const _prefsKey = 'g2_app_data_v1';
  final LensLink Function(String, LensSide) _linkFactory;

  AppData data = AppData();
  G2Session? session;
  G2Features? features;
  LinkStatus status = LinkStatus.noGlasses;
  final logs = <SessionLog>[];

  /// The last connection state changes with reasons and retries (newest last, capped).
  final connectionHistory = <ConnEvent>[];

  void _conn(String event, {String detail = ''}) {
    connectionHistory.add(ConnEvent(event, detail: detail, attempt: _attempt));
    if (connectionHistory.length > 200) connectionHistory.removeRange(0, connectionHistory.length - 200);
  }
  bool _wantConnected = false;

  /// False after the user disconnects on purpose (vs a link drop that will be retried).
  bool get wantConnected => _wantConnected;
  int _attempt = 0;
  Timer? _retry;
  final _rng = Random();

  GlassesStatus? get glasses => session?.status;

  /// Auto-sync, periodic refreshes, profiles, notifications, navigation, EvenHub apps.
  late final HubServices services = HubServices(this, net: net, startTimers: _startServices);
  bool _startServices = !Platform.environment.containsKey('FLUTTER_TEST');

  /// Section changed (UI or assistant): saved and synced to the glasses ~1 s later.
  void changed(String section) => services.changed(section);

  Future<void> load() async {
    String? raw;
    try {
      final p = await SharedPreferences.getInstance();
      raw = p.getString(_prefsKey);
      if (raw != null) data = AppData.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
    } catch (e) {
      _log('Could not read saved data: $e', LogLevel.warn);
      // Keep the unreadable copy aside: the next save must not destroy the only copy.
      if (raw != null) {
        try {
          await (await SharedPreferences.getInstance()).setString('${_prefsKey}_unreadable', raw);
        } catch (_) {}
      }
    }
    status = data.glasses == null ? LinkStatus.noGlasses : LinkStatus.disconnected;
    notifyListeners();
    if (_startServices) await services.start();
  }

  /// Tests: no timers, no platform channels.
  void disableServiceTimers() => _startServices = false;

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsKey, jsonEncode(data.toJson()));
    notifyListeners();
  }

  void _log(String m, [LogLevel l = LogLevel.info]) {
    logs.add(SessionLog(l, m));
    if (logs.length > 500) logs.removeRange(0, logs.length - 500);
    if (kDebugMode) debugPrint('[g2] $m');
    notifyListeners();
  }

  /// Public log entry point (used by the AI stack, lib/hub/even_ai_hub.dart).
  void log(String m, [LogLevel l = LogLevel.info]) => _log(m, l);

  // ── pairing ─────────────────────────────────────────────────────────────────────────────
  Future<void> adoptPair(LensPair p) async {
    await disconnect();
    await services.switchPair(PairedGlasses(
      pairId: p.pairId,
      rightId: p.right!.deviceId,
      leftId: p.left!.deviceId,
      rightName: p.right!.name,
      leftName: p.left!.name,
      serial: p.serial,
    ));
    status = LinkStatus.disconnected;
    await save();
    _log('Saved glasses pair ${p.pairId} (R ${p.right!.deviceId} / L ${p.left!.deviceId})', LogLevel.ok);
  }

  Future<void> forgetGlasses() async {
    await disconnect();
    final id = data.glasses?.pairId;
    data.glasses = null;
    data.pairs.removeWhere((p) => p.glasses.pairId == id);
    status = LinkStatus.noGlasses;
    await save();
  }

  // ── connection loop ─────────────────────────────────────────────────────────────────────
  /// Connect (also used by auto-connect on start and the reconnect loop). Does nothing while
  /// the glasses are handed off to the official Even app — see [takeBack].
  Future<void> connect() async {
    final g = data.glasses;
    if (g == null || data.handedOff || status == LinkStatus.connecting || status == LinkStatus.connected) return;
    _wantConnected = true;
    _retry?.cancel();
    status = LinkStatus.connecting;
    _conn('connecting');
    notifyListeners();
    final s = G2Session(right: _linkFactory(g.rightId, LensSide.right), left: _linkFactory(g.leftId, LensSide.left));
    session = s;
    s.logs.listen((l) => _log(l.message, l.level));
    s.statusChanges.listen((_) {
      notifyListeners();
      _updateNotification();
    });
    s.linkLost.listen((reason) => _onLinkLost(s, reason));
    // A disconnect / hand-off / pair switch while this attempt is still running wins: the
    // attempt must not come back as "connected" on a session that was already closed.
    bool superseded() => !identical(session, s) || !_wantConnected;
    try {
      await s.connect().timeout(const Duration(seconds: 40));
      if (superseded()) throw const _Superseded();
      await s.postConnect();
      if (superseded()) throw const _Superseded();
      final f = G2Features(s);
      f.tasks = data.tasks;
      f.onTaskToggled = _onTaskToggled;
      features = f;
      status = LinkStatus.connected;
      _conn('connected');
      _attempt = 0;
      notifyListeners();
      await BackgroundLink.start('Connected to Even G2', 'Keeping the glasses link alive');
      services.onConnected(f); // reconnect restore + sync (replaces the phase-1 _restoreProfile)
    } catch (e) {
      if (e is _Superseded || superseded()) {
        _conn('superseded');
        if (identical(session, s)) await _teardown(s);
        try {
          await s.close();
        } catch (_) {}
        return;
      }
      _log('Connect failed: $e', LogLevel.err);
      _conn('connect_failed', detail: '$e');
      await _teardown(s);
      _scheduleRetry();
    }
  }

  /// A connect from a user action ("Connect", "Use these glasses", a newly paired pair): it also
  /// ends a hand-off to the official app.
  Future<void> connectByUser() async {
    if (data.handedOff) return takeBack();
    return connect();
  }

  // ── hand-off to the official Even app ──────────────────────────────────────────────────────
  /// Release the glasses so the official Even app can use them (its Even AI, updates, …) without
  /// uninstalling this one: stop auto-reconnect, park the sync queue (pending changes stay
  /// pending), disconnect both lenses and close their GATT clients. Remembered across restarts:
  /// the app will not grab the glasses back until [takeBack]. Nothing of the official app or
  /// Even's services is called; this only lets go of our own Bluetooth connection.
  Future<void> handOff() async {
    if (data.handedOff) return;
    data.handedOff = true;
    _conn('hand_off');
    await save();
    _log('Glasses handed off to the Even app — tap "Take back" to reconnect', LogLevel.ok);
    await disconnect();
  }

  /// Reconnect after a hand-off; the sync engine then restores everything (and sends what was
  /// changed meanwhile).
  Future<void> takeBack() async {
    if (data.handedOff) {
      data.handedOff = false;
      _conn('take_back');
      await save();
      _log('Taking the glasses back from the Even app');
    }
    await connect();
  }

  Future<void> disconnect() async {
    if (_wantConnected || session != null) _conn('disconnect');
    _wantConnected = false;
    _retry?.cancel();
    final s = session;
    if (s != null) await _teardown(s);
    await BackgroundLink.stop();
    status = data.glasses == null ? LinkStatus.noGlasses : LinkStatus.disconnected;
    notifyListeners();
  }

  Future<void> _teardown(G2Session s) async {
    services.onDisconnected();
    features?.dispose();
    features = null;
    if (identical(session, s)) session = null;
    try {
      await s.close();
    } catch (_) {}
    status = data.glasses == null ? LinkStatus.noGlasses : LinkStatus.disconnected;
    notifyListeners();
  }

  void _onLinkLost(G2Session s, String reason) {
    if (!identical(session, s)) return;
    _log('Link lost ($reason) — reconnecting', LogLevel.err);
    _conn('link_lost', detail: reason);
    _teardown(s).then((_) => _scheduleRetry());
  }

  void _scheduleRetry() {
    if (!_wantConnected || !data.autoConnect || data.handedOff) return;
    // Exponential backoff with jitter (g2.ble.backoff_delay: base 1, x2, cap 30, ±25 %).
    final base = min(30.0, pow(2, _attempt).toDouble());
    final delay = base * (1 + 0.25 * (2 * _rng.nextDouble() - 1));
    _attempt++;
    _conn('retry_scheduled', detail: '${delay.toStringAsFixed(1)} s');
    _log('Retrying in ${delay.toStringAsFixed(1)} s');
    _retry = Timer(Duration(milliseconds: (delay * 1000).round()), connect);
  }

  void _onTaskToggled(int uid, bool completed) {
    for (final t in data.tasks) {
      if (t.uid == uid) t.completed = completed;
    }
    _log('Task $uid ${completed ? 'done' : 'not done'} (from the glasses)', LogLevel.ok);
    save();
  }

  void _updateNotification() {
    final g = session?.status;
    if (g?.battery == null) return;
    BackgroundLink.update('Connected to Even G2', 'Glasses ${g!.battery}%${g.charging == true ? ' (charging)' : ''}'
        '${g.caseBattery != null ? ' · case ${g.caseBattery}%' : ''}');
  }

  /// Run a feature action with a connected session, reporting the result in the log.
  Future<PushResult> run(Future<PushResult> Function(G2Features f) action) async {
    final f = features;
    if (f == null || status != LinkStatus.connected) return PushResult(false, 'Not connected');
    try {
      final r = await action(f);
      _log(r.message, r.ok ? LogLevel.ok : LogLevel.warn);
      return r;
    } catch (e) {
      _log('Error: $e', LogLevel.err);
      return PushResult(false, '$e');
    }
  }

  /// Assign stable uids before saving/pushing tasks.
  void setTasks(List<TaskItem> tasks) {
    data.tasks = assignUids(tasks, data.tasks);
    features?.tasks = data.tasks;
    changed('tasks');
  }

  bool get isAndroid => !kIsWeb && Platform.isAndroid;
}

class _Superseded implements Exception {
  const _Superseded();
}
