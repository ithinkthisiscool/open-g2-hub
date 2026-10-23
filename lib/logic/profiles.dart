/// Profiles: named widget sets per pair of glasses plus time-based switching. Port of the rule
/// logic in g2-hub/hub/profiles.py (schedule rules, first match wins, windows may wrap past
/// midnight; `days` names the day a window STARTS, Monday = 0).
library;

/// Sections a profile captures (the hub's PROFILE_SECTIONS; never secrets).
const List<String> profileSections = ['weather', 'calendar', 'quicklist', 'menu', 'evenhub_menu', 'news', 'stocks', 'health', 'settings'];
const int maxNameLen = 40;

class ProfileError implements Exception {
  ProfileError(this.message);
  final String message;
  @override
  String toString() => message;
}

String cleanName(Object? name) {
  final n = (name ?? '').toString().trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).join(' ');
  if (n.isEmpty) throw ProfileError('name required');
  if (n.length > maxNameLen) throw ProfileError('name too long (max $maxNameLen)');
  return n;
}

int minutesOf(Object? hhmm) {
  final parts = (hhmm ?? '').toString().split(':');
  if (parts.length != 2) throw ProfileError("bad time '$hhmm' (use HH:MM)");
  final h = int.tryParse(parts[0].trim()), m = int.tryParse(parts[1].trim());
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) throw ProfileError("bad time '$hhmm' (use HH:MM)");
  return h * 60 + m;
}

String _hhmm(int mins) => '${(mins ~/ 60).toString().padLeft(2, '0')}:${(mins % 60).toString().padLeft(2, '0')}';

/// Validate + clean rules [{profile, start, end, days?}].
List<Map<String, Object?>> normalizeRules(Object? rules) {
  if (rules is! List) throw ProfileError('rules must be a list');
  final out = <Map<String, Object?>>[];
  for (final r in rules) {
    if (r is! Map) throw ProfileError('each rule must be an object');
    final rule = <String, Object?>{
      'profile': cleanName(r['profile']),
      'start': _hhmm(minutesOf(r['start'])),
      'end': _hhmm(minutesOf(r['end'])),
    };
    if (rule['start'] == rule['end']) throw ProfileError('start and end must differ');
    final days = r['days'];
    if (days != null && !(days is List && days.isEmpty)) {
      if (days is! List || !days.every((d) => d is int && d >= 0 && d <= 6)) {
        throw ProfileError('days must be a list of 0 (Mon) .. 6 (Sun)');
      }
      rule['days'] = (days.cast<int>().toSet().toList()..sort());
    }
    out.add(rule);
  }
  return out;
}

/// The profile the rules select at [now] (local wall time), or null. Rules naming a profile
/// not in [known] (when given) are skipped.
String? scheduledProfile(List<Map<String, Object?>> rules, DateTime now, {Set<String>? known}) {
  final cur = now.hour * 60 + now.minute;
  final today = now.weekday - 1;
  for (final r in rules) {
    if (known != null && !known.contains(r['profile'])) continue;
    final start = minutesOf(r['start']), end = minutesOf(r['end']);
    final rd = r['days'] as List?;
    final days = rd == null || rd.isEmpty ? const [0, 1, 2, 3, 4, 5, 6] : rd.cast<int>();
    final bool hit;
    if (start < end) {
      hit = start <= cur && cur < end && days.contains(today);
    } else {
      hit = (cur >= start && days.contains(today)) || (cur < end && days.contains((today - 1) % 7));
    }
    if (hit) return r['profile'] as String;
  }
  return null;
}
