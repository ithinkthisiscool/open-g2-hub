/// Which phone notifications go to the glasses: the per-app allow/deny list, quiet hours,
/// duplicates, and the notification file body (limits: appID / displayName ≤ 32 UTF-8 bytes,
/// title ≤ 64 / message ≤ 512 characters like the hub's notify route).
library;

import 'dart:typed_data';

import '../protocol/file_service.dart' as fs;
import '../protocol/limits.dart' as lim;
import 'profiles.dart' show minutesOf;

const String ownPackage = 'dev.g2hub.mobile';
const int titleMaxChars = 64, messageMaxChars = 512, subtitleMaxChars = 64;
const Duration duplicateWindow = Duration(seconds: 10);

/// One notification posted on the phone (from the Android listener service).
class PhoneNotification {
  PhoneNotification({
    required this.package,
    this.appName = '',
    this.title = '',
    this.text = '',
    this.subText = '',
    this.ongoing = false,
    this.groupSummary = false,
    this.postTime,
    this.key = '',
    this.category = '',
  });
  final String package;
  final String appName;
  final String title;
  final String text;
  final String subText;
  final bool ongoing;
  final bool groupSummary;
  final DateTime? postTime;
  final String key;
  final String category;

  factory PhoneNotification.fromMap(Map<Object?, Object?> m) => PhoneNotification(
        package: (m['package'] ?? '').toString(),
        appName: (m['appName'] ?? '').toString(),
        title: (m['title'] ?? '').toString(),
        text: (m['text'] ?? '').toString(),
        subText: (m['subText'] ?? '').toString(),
        ongoing: m['ongoing'] == true,
        groupSummary: m['groupSummary'] == true,
        postTime: m['postTime'] is int ? DateTime.fromMillisecondsSinceEpoch(m['postTime'] as int) : null,
        key: (m['key'] ?? '').toString(),
        category: (m['category'] ?? '').toString(),
      );
}

class NotificationPrefs {
  NotificationPrefs({
    this.enabled = true,
    this.newAppsAllowed = true,
    Map<String, bool>? apps,
    Map<String, String>? appNames,
    this.quietHours = false,
    this.quietStart = '22:00',
    this.quietEnd = '07:00',
    this.skipOngoing = true,
    this.showContent = true,
    this.displaySeconds = 5,
    this.lowBatteryAlerts = true,
  })  : apps = apps ?? {},
        appNames = appNames ?? {};
  bool enabled;

  /// Apps not in [apps] are forwarded when true (deny-list mode), dropped when false (allow-list).
  bool newAppsAllowed;
  final Map<String, bool> apps;

  /// Labels of apps seen so far (for the list in the UI).
  final Map<String, String> appNames;
  bool quietHours;
  String quietStart;
  String quietEnd;
  bool skipOngoing;
  bool showContent;
  int displaySeconds;
  bool lowBatteryAlerts;

  bool allows(String pkg) => apps[pkg] ?? newAppsAllowed;

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'new_apps_allowed': newAppsAllowed,
        'apps': apps,
        'app_names': appNames,
        'quiet_hours': quietHours,
        'quiet_start': quietStart,
        'quiet_end': quietEnd,
        'skip_ongoing': skipOngoing,
        'show_content': showContent,
        'display_seconds': displaySeconds,
        'low_battery_alerts': lowBatteryAlerts,
      };

  factory NotificationPrefs.fromJson(Map<String, Object?> j) => NotificationPrefs(
        enabled: j['enabled'] != false,
        newAppsAllowed: j['new_apps_allowed'] != false,
        apps: {for (final e in ((j['apps'] as Map?) ?? const {}).entries) e.key.toString(): e.value == true},
        appNames: {for (final e in ((j['app_names'] as Map?) ?? const {}).entries) e.key.toString(): e.value.toString()},
        quietHours: j['quiet_hours'] == true,
        quietStart: (j['quiet_start'] ?? '22:00').toString(),
        quietEnd: (j['quiet_end'] ?? '07:00').toString(),
        skipOngoing: j['skip_ongoing'] != false,
        showContent: j['show_content'] != false,
        displaySeconds: (j['display_seconds'] as num?)?.toInt() ?? 5,
        lowBatteryAlerts: j['low_battery_alerts'] != false,
      );
}

enum FilterVerdict { forward, disabled, ownApp, ongoing, groupSummary, empty, blockedApp, quietHours, duplicate }

/// True when [now] (local wall time) is inside the quiet window (may wrap past midnight).
bool inQuietHours(NotificationPrefs p, DateTime now) {
  if (!p.quietHours) return false;
  int s, e;
  try {
    s = minutesOf(p.quietStart);
    e = minutesOf(p.quietEnd);
  } catch (_) {
    return false;
  }
  final cur = now.hour * 60 + now.minute;
  if (s == e) return false;
  return s < e ? (cur >= s && cur < e) : (cur >= s || cur < e);
}

/// Remembers recent notifications to drop Android's repeated re-posts.
class DuplicateGuard {
  final _seen = <String, DateTime>{};
  bool isDuplicate(PhoneNotification n, DateTime now) {
    _seen.removeWhere((_, t) => now.difference(t) > duplicateWindow);
    final k = '${n.package}\u0000${n.title}\u0000${n.text}';
    if (_seen.containsKey(k)) return true;
    _seen[k] = now;
    return false;
  }
}

FilterVerdict decide(PhoneNotification n, NotificationPrefs p, DateTime now, DuplicateGuard guard) {
  if (!p.enabled) return FilterVerdict.disabled;
  if (n.package == ownPackage) return FilterVerdict.ownApp;
  if (p.skipOngoing && n.ongoing) return FilterVerdict.ongoing;
  if (n.groupSummary) return FilterVerdict.groupSummary;
  if (n.title.trim().isEmpty && n.text.trim().isEmpty) return FilterVerdict.empty;
  if (!p.allows(n.package)) return FilterVerdict.blockedApp;
  if (inQuietHours(p, now)) return FilterVerdict.quietHours;
  if (guard.isDuplicate(n, now)) return FilterVerdict.duplicate;
  return FilterVerdict.forward;
}

String _chars(String s, int n) {
  final r = s.runes.toList();
  return r.length > n ? String.fromCharCodes(r.take(n)) : s;
}

/// The JSON file the glasses show (fileType 1). [msgId] should be unique per notification.
Uint8List notificationFile(PhoneNotification n, NotificationPrefs p, {required int now, int? utcOffsetSeconds, int? msgId}) {
  final appName = n.appName.isEmpty ? n.package : n.appName;
  final title = p.showContent ? (n.title.isEmpty ? appName : n.title) : appName;
  final message = p.showContent ? n.text : 'New notification';
  return fs.notificationJson(
    _chars(title, titleMaxChars),
    _chars(message, messageMaxChars),
    subtitle: p.showContent ? _chars(n.subText, subtitleMaxChars) : '',
    displayName: lim.utf8Fit(appName, lim.notificationDisplayNameMaxBytes),
    appIdentifier: lim.utf8Fit(n.package, lim.notificationAppIdMaxBytes),
    msgId: msgId,
    now: now,
    utcOffsetSeconds: utcOffsetSeconds,
  );
}
