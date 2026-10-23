/// Phone notifications → glasses, like the official app: Android's NotificationListenerService
/// (G2NotificationListener.kt) hands each notification over; this filters it and sends the
/// notification JSON file over the EvenFile service. A notification that arrives while the glasses
/// are disconnected is delivered on reconnect if it is less than 2 minutes old.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../hub/features.dart';
import '../hub/models.dart';
import '../logic/notification_filter.dart';

class NotificationLogEntry {
  NotificationLogEntry(this.n, this.verdict, this.at, [this.result]);
  final PhoneNotification n;
  final FilterVerdict verdict;
  final DateTime at;
  String? result;
}

class NotificationService extends ChangeNotifier {
  NotificationService({required this.data, required this.features, required this.log, this.clock = DateTime.now});

  final AppData Function() data;
  final G2Features? Function() features;
  final void Function(String m, {bool warn}) log;
  final DateTime Function() clock;

  static const _events = EventChannel('g2hub/notifications');
  static const _control = MethodChannel('g2hub/notifications/control');
  StreamSubscription<Object?>? _sub;
  final guard = DuplicateGuard();
  final recent = <NotificationLogEntry>[];
  final _pending = <NotificationLogEntry>[];
  bool accessGranted = false;
  int _msgId = DateTime.now().millisecondsSinceEpoch ~/ 1000 & 0x3FFFFFFF;
  Future<void> _chain = Future<void>.value();

  bool get supported => !kIsWeb && Platform.isAndroid;

  Future<void> start() async {
    if (!supported) return;
    await refreshAccess();
    _sub ??= _events.receiveBroadcastStream().listen((e) {
      if (e is Map) handle(PhoneNotification.fromMap(e));
    }, onError: (Object _) {});
  }

  Future<bool> refreshAccess() async {
    if (!supported) return false;
    try {
      accessGranted = await _control.invokeMethod<bool>('isEnabled') ?? false;
    } catch (_) {
      accessGranted = false;
    }
    notifyListeners();
    return accessGranted;
  }

  Future<void> openAccessSettings() async {
    try {
      await _control.invokeMethod<bool>('openSettings');
    } catch (_) {}
  }

  /// Launcher apps on the phone: [(package, name)].
  Future<List<(String, String)>> installedApps() async {
    if (!supported) return const [];
    try {
      final l = await _control.invokeMethod<List<Object?>>('listApps') ?? const [];
      return [for (final m in l.whereType<Map>()) ((m['package'] ?? '').toString(), (m['name'] ?? '').toString())];
    } catch (_) {
      return const [];
    }
  }

  /// Entry point for every phone notification (also used by tests).
  void handle(PhoneNotification n) {
    final p = data().notifications;
    if (n.appName.isNotEmpty && p.appNames[n.package] != n.appName && n.package != ownPackage) p.appNames[n.package] = n.appName;
    final v = decide(n, p, clock(), guard);
    final e = NotificationLogEntry(n, v, clock());
    recent.insert(0, e);
    if (recent.length > 40) recent.removeLast();
    notifyListeners();
    if (v != FilterVerdict.forward) return;
    if (features() == null) {
      _pending.add(e);
      if (_pending.length > 5) _pending.removeAt(0);
      e.result = 'waiting for the glasses';
      return;
    }
    _send(e);
  }

  /// Called on (re)connect: deliver what arrived while disconnected (< 2 min old).
  void flushPending() {
    final now = clock();
    final list = [..._pending.where((e) => now.difference(e.at) < const Duration(minutes: 2))];
    _pending.clear();
    for (final e in list) {
      _send(e);
    }
  }

  void _send(NotificationLogEntry e) {
    _chain = _chain.then((_) async {
      final f = features();
      if (f == null) {
        _pending.add(e);
        return;
      }
      final now = clock().millisecondsSinceEpoch ~/ 1000;
      _msgId = (_msgId + 1) & 0x7FFFFFFF;
      final file = notificationFile(e.n, data().notifications, now: now, msgId: _msgId);
      try {
        final r = await f.sendNotificationFile(file);
        e.result = r.ok ? 'shown' : r.message;
        log('Notification from ${e.n.appName.isEmpty ? e.n.package : e.n.appName}: ${r.message}', warn: !r.ok);
      } catch (err) {
        e.result = '$err';
      }
      notifyListeners();
    });
  }

  /// A test notification from the app itself (Glasses → Notifications).
  Future<PushResult> sendTest(String title, String message, {String from = 'G2 Hub'}) async {
    final f = features();
    if (f == null) return PushResult(false, 'Not connected');
    final n = PhoneNotification(package: 'dev.g2hub.test', appName: from, title: title, text: message);
    final now = clock().millisecondsSinceEpoch ~/ 1000;
    _msgId = (_msgId + 1) & 0x7FFFFFFF;
    final p = NotificationPrefs(showContent: true);
    return f.sendNotificationFile(notificationFile(n, p, now: now, msgId: _msgId));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
