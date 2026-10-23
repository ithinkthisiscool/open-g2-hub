/// Background keep-alive.
///
/// Android: a foreground service (flutter_foreground_task, type `connectedDevice`) with a
/// persistent notification. The BLE link, timers and the protocol all stay in the app's main
/// isolate; the service's only job is to keep the process (and its FlutterEngine) alive and
/// exempt from background execution limits while the screen is off or another app is in front,
/// so the 4 s EvenHub heartbeat and 60 s keep-alive keep running. The task handler itself does
/// nothing. If the user swipes the app away from recents, Android tears the engine down and the
/// GATT clients are closed (closeGattOnDetach), releasing the glasses cleanly.
///
/// iOS: CoreBluetooth keeps a connected peripheral's link and wakes the app for notifications
/// thanks to the `bluetooth-central` background mode (ios/Runner/Info.plist); no service needed.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
void g2ServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_IdleTaskHandler());
}

class _IdleTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class BackgroundLink {
  static bool get _supported => !kIsWeb && Platform.isAndroid;

  static void init() {
    if (!_supported) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'g2_link',
        channelName: 'Glasses connection',
        channelDescription: 'Shown while the app keeps the Even G2 link alive in the background.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  static Future<void> requestPermissions() async {
    if (!_supported) return;
    try {
      if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (_) {}
  }

  static Future<void> start(String title, String text) async {
    if (!_supported) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
      } else {
        await FlutterForegroundTask.startService(
          serviceId: 4762,
          serviceTypes: [ForegroundServiceTypes.connectedDevice],
          notificationTitle: title,
          notificationText: text,
          callback: g2ServiceCallback,
        );
      }
    } catch (_) {}
  }

  static Future<void> update(String title, String text) async {
    if (!_supported) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
      }
    } catch (_) {}
  }

  static Future<void> stop() async {
    if (!_supported) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }
}
