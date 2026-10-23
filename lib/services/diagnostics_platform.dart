/// Platform side of "Report a problem": phone / app / Bluetooth facts and permission states for
/// the bundle, and handing the finished file to the Android share sheet or a "Save as" dialog.
/// No network: sharing only opens the system share sheet; the user picks where it goes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:universal_ble/universal_ble.dart';

import 'diagnostics_report.dart';

const _channel = MethodChannel('g2hub/diagnostics');

/// Collect device, app, BLE and permission facts. Every part is best effort: a missing plugin
/// or platform channel just leaves that part out.
Future<PlatformFacts> gatherPlatformFacts() async {
  final device = <String, Object?>{
    'os': kIsWeb ? 'web' : Platform.operatingSystem,
    'os_version': kIsWeb ? '' : Platform.operatingSystemVersion,
  };
  final ble = <String, Object?>{};
  try {
    final m = await _channel.invokeMapMethod<String, Object?>('deviceInfo');
    if (m != null) {
      for (final e in m.entries) {
        (e.key.startsWith('ble_') ? ble : device)[e.key.startsWith('ble_') ? e.key.substring(4) : e.key] = e.value;
      }
    }
  } catch (_) {/* no channel (tests, other platforms) */}
  try {
    ble['availability'] = (await UniversalBle.getBluetoothAvailabilityState().timeout(const Duration(seconds: 3))).name;
  } catch (e) {
    ble['availability'] = 'unknown';
  }
  final perms = <String, String>{};
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    final list = <String, Permission>{
      'bluetooth_scan': Permission.bluetoothScan,
      'bluetooth_connect': Permission.bluetoothConnect,
      if (Platform.isIOS) 'bluetooth': Permission.bluetooth,
      'location_when_in_use': Permission.locationWhenInUse,
      'notifications': Permission.notification,
      'microphone': Permission.microphone,
      'calendar': Permission.calendarFullAccess,
      'ignore_battery_optimizations': Permission.ignoreBatteryOptimizations,
    };
    for (final e in list.entries) {
      try {
        perms[e.key] = (await e.value.status).name;
      } catch (_) {
        perms[e.key] = 'unknown';
      }
    }
  }
  return PlatformFacts(device: device, permissions: perms, ble: ble);
}

/// Where a finished report goes. Tests use a fake.
abstract class ReportSink {
  /// Open the share sheet with the report attached. False if sharing is not available.
  Future<bool> share(DiagnosticsBundle b);

  /// Let the user save the report to a file. False if cancelled.
  Future<bool> save(DiagnosticsBundle b);
}

class PlatformReportSink implements ReportSink {
  const PlatformReportSink();

  @override
  Future<bool> share(DiagnosticsBundle b) async {
    // The file goes to the app's cache (cache/diagnostics, cleared each time) and is handed to
    // the share sheet through the app's own read-only content provider.
    final dir = Directory('${(await getTemporaryDirectory()).path}/diagnostics');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    final f = File('${dir.path}/${b.fileName}');
    await f.writeAsString(b.text, flush: true);
    try {
      return await _channel.invokeMethod<bool>('share', {'name': b.fileName, 'subject': 'G2 Hub problem report'}) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> save(DiagnosticsBundle b) async {
    final path = await FilePicker.saveFile(dialogTitle: 'Save problem report', fileName: b.fileName, bytes: utf8.encode(b.text));
    return path != null;
  }
}
