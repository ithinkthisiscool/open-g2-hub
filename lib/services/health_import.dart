/// Health card values from the phone's health store instead of typing them: Health Connect on
/// Android, Apple Health on iOS (both through the `health` plugin). Read only: today's steps,
/// the latest and average heart rate today, and last night's sleep. Goals (steps, calories) and
/// anything the store does not have stay as typed.
///
/// The plugin sits behind [HealthSource] so the logic is tested with a fake.
library;

import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';

import '../logic/health_values.dart';

/// Whether the phone can give health data.
enum HealthAvailability {
  /// Health Connect / Apple Health is there.
  available,

  /// Android: Health Connect is not installed (Android 13 and older) or must be updated.
  notInstalled,
  updateRequired,

  /// No health store on this platform (desktop, tests, Android 8.0 without Health Connect).
  unsupported,
}

/// One import: what the store had (null = no data for that metric).
class HealthReading {
  const HealthReading({this.steps, this.heartRate, this.heartRateAvg, this.sleepMinutes});
  final int? steps;
  final int? heartRate;
  final int? heartRateAvg;
  final int? sleepMinutes;
  bool get isEmpty => steps == null && heartRate == null && sleepMinutes == null;
}

/// Where health data comes from (the plugin in the app, a fake in tests).
abstract class HealthSource {
  /// "Health Connect" / "Apple Health".
  String get name;
  Future<HealthAvailability> availability();
  Future<bool> hasAccess();

  /// Shows the system permission screen (call from a user action).
  Future<bool> requestAccess();

  /// Opens the store page to install / update Health Connect.
  Future<void> install();

  /// Today's values at [now] (local time).
  Future<HealthReading> read(DateTime now);
}

/// The metrics the health card can import.
const List<String> importedHealthKeys = ['steps', 'heart_rate', 'heart_rate_avg', 'sleep_minutes'];

/// Minutes of sleep in "last night": sessions that end between 18:00 yesterday and [now],
/// overlaps merged, at most 24 h.
int? sleepMinutesLastNight(List<(DateTime, DateTime)> sessions, DateTime now) {
  final from = DateTime(now.year, now.month, now.day - 1, 18);
  final spans = [
    for (final (a, b) in sessions)
      if (b.isAfter(from) && !b.isAfter(now) && b.isAfter(a)) (a.isBefore(from.subtract(const Duration(hours: 12))) ? from.subtract(const Duration(hours: 12)) : a, b),
  ]..sort((x, y) => x.$1.compareTo(y.$1));
  if (spans.isEmpty) return null;
  var total = Duration.zero;
  DateTime? curStart, curEnd;
  for (final (a, b) in spans) {
    if (curEnd == null || a.isAfter(curEnd)) {
      if (curStart != null) total += curEnd!.difference(curStart);
      curStart = a;
      curEnd = b;
    } else if (b.isAfter(curEnd)) {
      curEnd = b;
    }
  }
  total += curEnd!.difference(curStart!);
  return min(total.inMinutes, 1440);
}

/// [values] with the imported metrics replaced (each checked against the card's limits; a value
/// out of range or missing in the store keeps what was there). Returns the keys that changed.
Set<String> applyReading(Map<String, num> values, HealthReading r) {
  final changed = <String>{};
  void put(String key, int? v) {
    if (v == null) return;
    final (lo, hi, _) = healthFields[key]!;
    if (v < lo || v > hi) return;
    if (values[key] != v) changed.add(key);
    values[key] = v;
  }

  put('steps', r.steps);
  put('heart_rate', r.heartRate);
  put('heart_rate_avg', r.heartRateAvg);
  put('sleep_minutes', r.sleepMinutes);
  return changed;
}

/// Health Connect (Android) / Apple Health (iOS) through the `health` plugin.
class PluginHealthSource implements HealthSource {
  final _health = Health();
  bool _configured = false;

  static const _types = [HealthDataType.STEPS, HealthDataType.HEART_RATE, HealthDataType.SLEEP_SESSION];
  static const _read = [HealthDataAccess.READ, HealthDataAccess.READ, HealthDataAccess.READ];

  bool get _android => !kIsWeb && Platform.isAndroid;
  bool get _ios => !kIsWeb && Platform.isIOS;

  @override
  String get name => _ios ? 'Apple Health' : 'Health Connect';

  Future<bool> _setup() async {
    if (!_android && !_ios) return false;
    if (!_configured) {
      await _health.configure();
      _configured = true;
    }
    return true;
  }

  @override
  Future<HealthAvailability> availability() async {
    try {
      if (!await _setup()) return HealthAvailability.unsupported;
      if (_ios) return HealthAvailability.available;
      return switch (await _health.getHealthConnectSdkStatus()) {
        HealthConnectSdkStatus.sdkAvailable => HealthAvailability.available,
        HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired => HealthAvailability.updateRequired,
        HealthConnectSdkStatus.sdkUnavailable => HealthAvailability.notInstalled,
        null => HealthAvailability.unsupported,
      };
    } catch (_) {
      return HealthAvailability.unsupported;
    }
  }

  @override
  Future<bool> hasAccess() async {
    try {
      if (!await _setup()) return false;
      // iOS never says whether read access was granted (privacy): null = "asked before".
      return await _health.hasPermissions(_types, permissions: _read) ?? _ios;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> requestAccess() async {
    try {
      if (!await _setup()) return false;
      return await _health.requestAuthorization(_types, permissions: _read);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> install() async {
    try {
      if (await _setup()) await _health.installHealthConnect();
    } catch (_) {}
  }

  @override
  Future<HealthReading> read(DateTime now) async {
    if (!await _setup()) throw StateError('No health data on this phone');
    final midnight = DateTime(now.year, now.month, now.day);
    final steps = await _health.getTotalStepsInInterval(midnight, now);
    final hr = await _health.getHealthDataFromTypes(types: const [HealthDataType.HEART_RATE], startTime: midnight, endTime: now);
    final sleepFrom = DateTime(now.year, now.month, now.day - 1, 6);
    final sleep = await _health.getHealthDataFromTypes(types: const [HealthDataType.SLEEP_SESSION], startTime: sleepFrom, endTime: now);
    final beats = [
      for (final p in hr)
        if (p.value is NumericHealthValue) (p.dateTo, (p.value as NumericHealthValue).numericValue.round()),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    return HealthReading(
      steps: steps,
      heartRate: beats.isEmpty ? null : beats.last.$2,
      heartRateAvg: beats.isEmpty ? null : (beats.map((b) => b.$2).reduce((a, b) => a + b) / beats.length).round(),
      sleepMinutes: sleepMinutesLastNight([for (final p in sleep) (p.dateFrom, p.dateTo)], now),
    );
  }
}

/// No health store (tests, desktop).
class NoHealthSource implements HealthSource {
  const NoHealthSource();
  @override
  String get name => 'Health Connect';
  @override
  Future<HealthAvailability> availability() async => HealthAvailability.unsupported;
  @override
  Future<bool> hasAccess() async => false;
  @override
  Future<bool> requestAccess() async => false;
  @override
  Future<void> install() async {}
  @override
  Future<HealthReading> read(DateTime now) async => throw StateError('No health data on this phone');
}
