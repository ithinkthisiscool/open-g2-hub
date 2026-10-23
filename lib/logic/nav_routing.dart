/// Real routing for the glasses' Navigation app. Port of g2-hub/hub/nav_routing.py:
/// OSM Nominatim (geocoding) + the public OSRM demo server (routing), the glasses formatting
/// (distance, duration, arrows, ETA) and — new on the phone, which has GPS — a progress tracker
/// that advances turn by turn from live positions.
library;

import 'dart:math';

import 'pyfmt.dart';

const String nominatim = 'https://nominatim.openstreetmap.org/search';
const String osrm = 'https://router.project-osrm.org/route/v1/driving/{lon1},{lat1};{lon2},{lat2}';
const Duration minInterval = Duration(seconds: 1); // Nominatim policy: ≤ 1 request/s
final RegExp latLonRe = RegExp(r'^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$');

class RoutingError implements Exception {
  RoutingError(this.message);
  final String message;
  @override
  String toString() => message;
}

class NavStep {
  NavStep(this.maneuver, this.road, this.distanceM, this.durationS, {this.lat, this.lon});
  final String maneuver; // 'type[:modifier]'
  final String road;
  final double distanceM; // the leg that FOLLOWS this maneuver
  final double durationS;
  final double? lat, lon; // where the maneuver is (phone extension)
  Map<String, Object?> toJson() => {'maneuver': maneuver, 'road': road, 'distance_m': distanceM, 'duration_s': durationS};
  Map<String, Object?> toStore() => {...toJson(), 'lat': lat, 'lon': lon};
  factory NavStep.fromJson(Map<String, Object?> j) => NavStep((j['maneuver'] ?? 'continue').toString(), (j['road'] ?? '').toString(),
      (j['distance_m'] as num? ?? 0).toDouble(), (j['duration_s'] as num? ?? 0).toDouble(),
      lat: (j['lat'] as num?)?.toDouble(), lon: (j['lon'] as num?)?.toDouble());
}

/// A literal "lat,lon" (no network), or null.
(double, double)? parseLatLon(String place) {
  final m = latLonRe.firstMatch(place);
  if (m == null) return null;
  final lat = double.parse(m[1]!), lon = double.parse(m[2]!);
  if (lat.abs() > 90 || lon.abs() > 180) throw RoutingError('invalid coordinates: ${place.trim()}');
  return (lat, lon);
}

/// Nominatim JSON → (lat, lon, display name).
(double, double, String) parseNominatim(Object? data, String place) {
  if (data is! List || data.isEmpty) throw RoutingError('no match found for "$place"');
  try {
    final hit = (data.first as Map).cast<String, Object?>();
    final name = (hit['display_name'] ?? '').toString();
    return (double.parse(hit['lat'].toString()), double.parse(hit['lon'].toString()), name.isEmpty ? place : name);
  } catch (_) {
    throw RoutingError('unexpected geocoder reply for "$place"');
  }
}

double _num(Object? v) => v is num ? v.toDouble() : 0.0;

/// OSRM route JSON → steps.
List<NavStep> parseOsrm(Object? data) {
  if (data is! Map || data['code'] != 'Ok' || (data['routes'] as List?)?.isEmpty != false) {
    throw RoutingError('no route found between those places');
  }
  final steps = <NavStep>[];
  for (final leg in ((data['routes'] as List).first as Map)['legs'] as List? ?? const []) {
    for (final s in (leg as Map)['steps'] as List? ?? const []) {
      final st = s as Map;
      final man = (st['maneuver'] as Map?) ?? const {};
      final kind = (man['type'] ?? '').toString().isEmpty ? 'continue' : man['type'].toString();
      final mod = man['modifier'];
      final loc = man['location'] as List?;
      steps.add(NavStep(mod != null && mod != '' ? '$kind:$mod' : kind, (st['name'] ?? '').toString(), _num(st['distance']),
          _num(st['duration']),
          lon: loc != null && loc.length == 2 ? _num(loc[0]) : null, lat: loc != null && loc.length == 2 ? _num(loc[1]) : null));
    }
  }
  if (steps.isEmpty) throw RoutingError('route has no steps');
  return steps;
}

String fmtDistance(double m) {
  if (m < 1000) return '${m >= 20 ? pyRoundTo(m, -1).toInt() : pyRoundInt(m)} m';
  return '${pyFixed(m / 1000, 1)} km';
}

String fmtDuration(double s) {
  final mins = max(1, pyRoundInt(s / 60));
  return mins < 60 ? '$mins min' : '${mins ~/ 60} h ${(mins % 60).toString().padLeft(2, '0')} min';
}

/// OSRM 'type:modifier' → navigation DIRECTION name.
String directionFor(String maneuver) {
  final i = maneuver.indexOf(':');
  final kind = i < 0 ? maneuver : maneuver.substring(0, i);
  final mod = i < 0 ? '' : maneuver.substring(i + 1);
  if (kind == 'depart') return 'DEPART';
  if (kind == 'roundabout' || kind == 'rotary' || kind == 'roundabout turn') return 'ROUNDABOUT_CW';
  return const {
        'right': 'TURN_RIGHT', 'left': 'TURN_LEFT', 'slight right': 'TURN_SLIGHT_RIGHT', //
        'slight left': 'TURN_SLIGHT_LEFT', 'sharp right': 'TURN_SHARP_RIGHT', 'sharp left': 'TURN_SHARP_LEFT',
        'uturn': 'UTURN_COUNTERCLOCKWISE',
      }[mod] ??
      'STRAIGHT';
}

String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Glasses fields for steps[i] (hub step_fields): direction, distance TO this maneuver, road,
/// remaining distance/time, ETA (local wall time [now]). [toHereM] overrides the distance
/// with a live GPS value.
Map<String, String?> stepFields(List<NavStep> steps, int i, DateTime now, {double? toHereM}) {
  final s = steps[i];
  final toHere = toHereM ?? (i > 0 ? steps[i - 1].distanceM : null);
  var remM = steps.skip(i).fold<double>(0, (a, x) => a + x.distanceM);
  var remS = steps.skip(i).fold<double>(0, (a, x) => a + x.durationS);
  if (toHereM != null && i > 0) {
    final legM = steps[i - 1].distanceM;
    remM += toHereM;
    remS += legM > 0 ? steps[i - 1].durationS * (toHereM / legM) : 0;
  }
  return {
    'direction': directionFor(s.maneuver),
    'distance': toHere != null ? fmtDistance(toHere) : null,
    'road': s.road.isEmpty ? null : s.road,
    'remaining_distance': fmtDistance(remM),
    'remaining_time': fmtDuration(remS),
    'eta': _hm(now.add(Duration(microseconds: (remS * 1e6).round()))),
  };
}

/// Great-circle distance in metres.
double haversine(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = sin(dLat / 2) * sin(dLat / 2) + cos(rad(lat1)) * cos(rad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
  return 2 * r * asin(min(1.0, sqrt(a)));
}

enum NavUpdate { none, distance, advanced, arrived, offRoute }

/// Turn-by-turn progress from live GPS fixes. [index] is the maneuver the glasses show (the
/// next one ahead). A maneuver counts as passed when the phone comes within [reachM] of it, or
/// was within [nearM] and is now moving away. Getting [offRouteM] further from the next
/// maneuver than the closest point seen so far means the user left the route.
class NavTracker {
  NavTracker(this.steps, {this.reachM = 25, this.nearM = 60, this.offRouteM = 250, this.distanceStepM = 25});
  final List<NavStep> steps;
  final double reachM, nearM, offRouteM, distanceStepM;
  int index = 1; // after DEPART (0) the first real maneuver is next
  double? toNext; // live metres to steps[index]
  double? _closest;
  double? _lastPushedDist;
  bool arrived = false;

  NavStep get next => steps[index.clamp(0, steps.length - 1)];

  NavUpdate update(double lat, double lon) {
    if (arrived || steps.length < 2) return NavUpdate.none;
    final s = next;
    if (s.lat == null || s.lon == null) return NavUpdate.none;
    final d = haversine(lat, lon, s.lat!, s.lon!);
    toNext = d;
    final closest = _closest;
    final passed = d <= reachM || (closest != null && closest <= nearM && d > closest + 15 && d < closest + offRouteM);
    if (passed) {
      if (index >= steps.length - 1) {
        arrived = true;
        return NavUpdate.arrived;
      }
      index++;
      _closest = null;
      _lastPushedDist = null;
      final n = next;
      toNext = n.lat != null ? haversine(lat, lon, n.lat!, n.lon!) : null;
      return NavUpdate.advanced;
    }
    _closest = closest == null ? d : min(closest, d);
    if (d > _closest! + offRouteM) {
      _closest = null;
      return NavUpdate.offRoute;
    }
    final last = _lastPushedDist;
    final step = d < 200 ? distanceStepM : (d < 1000 ? 50.0 : 200.0);
    if (last == null || (last - d).abs() >= step) {
      _lastPushedDist = d;
      return NavUpdate.distance;
    }
    return NavUpdate.none;
  }
}
