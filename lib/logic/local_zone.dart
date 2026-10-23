/// Local time zone abstraction so time-dependent logic (ICS expansion, calendar formatting,
/// profile schedules) is testable in any zone. Walls are naive wall-clock times stored in
/// DateTime.utc fields.
library;

import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

bool _tzReady = false;

/// Load the IANA database once (pure Dart, bundled with package:timezone).
void ensureTimeZones() {
  if (_tzReady) return;
  tzdata.initializeTimeZones();
  _tzReady = true;
}

/// IANA zone by name, or null when unknown (Windows names etc.).
tz.Location? zoneByName(String name) {
  ensureTimeZones();
  try {
    return tz.getLocation(name);
  } catch (_) {
    return null;
  }
}

abstract class LocalZone {
  const LocalZone();

  /// Unix seconds of a naive wall time in this zone.
  int epochOf(DateTime wall);

  /// Naive wall time (DateTime.utc fields) of unix seconds in this zone.
  DateTime wallOf(int epochSeconds);

  /// UTC offset in seconds at [epochSeconds].
  int offsetAt(int epochSeconds) => wallOf(epochSeconds).millisecondsSinceEpoch ~/ 1000 - epochSeconds;
}

/// The phone's own zone (DateTime local).
class SystemZone extends LocalZone {
  const SystemZone();
  @override
  int epochOf(DateTime w) =>
      DateTime(w.year, w.month, w.day, w.hour, w.minute, w.second).millisecondsSinceEpoch ~/ 1000;
  @override
  DateTime wallOf(int s) {
    final l = DateTime.fromMillisecondsSinceEpoch(s * 1000);
    return DateTime.utc(l.year, l.month, l.day, l.hour, l.minute, l.second);
  }
}

/// A named IANA zone (tests, TZID events).
class TzZone extends LocalZone {
  TzZone(this.location);
  TzZone.named(String name) : location = zoneByName(name)!;
  final tz.Location location;
  static final TzZone utc = TzZone(tz.UTC);
  @override
  int epochOf(DateTime w) =>
      tz.TZDateTime(location, w.year, w.month, w.day, w.hour, w.minute, w.second).millisecondsSinceEpoch ~/ 1000;
  @override
  DateTime wallOf(int s) {
    final t = tz.TZDateTime.fromMillisecondsSinceEpoch(location, s * 1000);
    return DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second);
  }
}
