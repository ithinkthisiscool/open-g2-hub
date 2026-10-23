/// Live weather conversion for the status bar. Port of g2-hub/hub/weather.py (Open-Meteo, free,
/// no key): WMO code → WeatherType icon + text, the app's rain hint ("Now", "{n}h", "Tmr", "0%")
/// and the next sunrise/sunset. Pure; the HTTP lives in services/weather_service.dart.
library;

import 'pyfmt.dart';

const Map<int, (int, String)> wmo = {
  0: (1, 'Clear'), 1: (1, 'Mostly clear'), 2: (2, 'Partly cloudy'), 3: (2, 'Overcast'), 45: (11, 'Fog'), //
  48: (11, 'Freezing fog'), 51: (3, 'Light drizzle'), 53: (3, 'Drizzle'), 55: (4, 'Heavy drizzle'),
  56: (15, 'Freezing drizzle'), 57: (15, 'Freezing drizzle'), 61: (5, 'Light rain'), 63: (5, 'Rain'),
  65: (6, 'Heavy rain'), 66: (15, 'Freezing rain'), 67: (15, 'Freezing rain'), 71: (9, 'Light snow'),
  73: (9, 'Snow'), 75: (9, 'Heavy snow'), 77: (9, 'Snow grains'), 80: (5, 'Showers'), 81: (5, 'Showers'),
  82: (6, 'Heavy showers'), 85: (9, 'Snow showers'), 86: (9, 'Snow showers'), 95: (7, 'Thunderstorm'),
  96: (7, 'Thunderstorm, hail'), 99: (7, 'Thunderstorm, hail'),
};
const int rainProbThreshold = 40;
const Duration refreshEvery = Duration(minutes: 15);

const String forecastUrl = 'https://api.open-meteo.com/v1/forecast';
const String geocodeUrl = 'https://geocoding-api.open-meteo.com/v1/search';

Map<String, String> forecastParams(double lat, double lon) => {
      'latitude': '$lat',
      'longitude': '$lon',
      'timezone': 'auto',
      'forecast_days': '2',
      'current': 'temperature_2m,weather_code,is_day',
      'hourly': 'precipitation_probability',
      'daily': 'sunrise,sunset',
    };

/// Open-Meteo geocoding reply → (label, lat, lon); throws StateError when nothing was found.
(String, double, double) geocodeResult(Map<String, Object?>? data, String city) {
  final res = (data?['results'] as List?) ?? const [];
  if (res.isEmpty) throw StateError('city not found: $city');
  final top = (res.first as Map).cast<String, Object?>();
  final label = [top['name'], top['admin1'], top['country_code']]
      .where((x) => x != null && x != '')
      .join(', ');
  return (label, (top['latitude'] as num).toDouble(), (top['longitude'] as num).toDouble());
}

/// One geocoding match (Open-Meteo): "Springfield" in "Missouri", "United States".
class GeoPlace {
  const GeoPlace({required this.name, this.admin1 = '', this.country = '', this.countryCode = '', required this.lat, required this.lon});
  final String name, admin1, country, countryCode;
  final double lat, lon;

  /// The label shown on the card and stored as the place (same format as [geocodeResult]).
  String get label => [name, admin1, countryCode].where((x) => x.isNotEmpty).join(', ');

  /// Region + country, to tell matches apart ("Missouri, United States").
  String get detail => [admin1, country.isNotEmpty ? country : countryCode].where((x) => x.isNotEmpty).join(', ');

  factory GeoPlace.fromJson(Map<String, Object?> j) => GeoPlace(
        name: (j['name'] ?? '').toString(),
        admin1: (j['admin1'] ?? '').toString(),
        country: (j['country'] ?? '').toString(),
        countryCode: (j['country_code'] ?? '').toString(),
        lat: (j['latitude'] as num).toDouble(),
        lon: (j['longitude'] as num).toDouble(),
      );
}

/// How many matches the city search offers.
const int geocodeCount = 8;

/// "Springfield, Missouri" → ("Springfield", "missouri"): Open-Meteo matches the name only, so a
/// region / country after a comma is used to filter the matches.
(String, String) splitPlaceQuery(String q) {
  final i = q.indexOf(',');
  if (i < 0) return (q.trim(), '');
  return (q.substring(0, i).trim(), q.substring(i + 1).trim().toLowerCase());
}

/// Every match of a geocoding reply, filtered by the part of [query] after a comma (region,
/// country or country code); when the filter removes everything the unfiltered list is kept.
List<GeoPlace> geocodePlaces(Map<String, Object?>? data, [String query = '']) {
  final res = (data?['results'] as List?) ?? const [];
  final all = <GeoPlace>[];
  for (final r in res) {
    if (r is Map && r['latitude'] is num && r['longitude'] is num) all.add(GeoPlace.fromJson(r.cast<String, Object?>()));
  }
  final (_, filter) = splitPlaceQuery(query);
  if (filter.isEmpty) return all;
  bool hit(GeoPlace p) => [p.admin1, p.country, p.countryCode].any((x) => x.toLowerCase().startsWith(filter));
  final some = all.where(hit).toList();
  return some.isEmpty ? all : some;
}

String _hhmm(String? iso) => iso != null && iso.length >= 16 ? iso.substring(11, 16) : '';

String _lstrip0(String s) {
  var i = 0;
  while (i < s.length && s[i] == '0') {
    i++;
  }
  return s.substring(i);
}

/// The forecast JSON → {temp_c, weather_type, status, rain_icon, rain_hint, sunset_select,
/// sunset_hint, summary} (weather.current minus fetched_at).
Map<String, Object?> weatherFromForecast(Map<String, Object?> d) {
  final cur = (d['current'] as Map).cast<String, Object?>();
  var (wtype, text) = wmo[(cur['weather_code'] as num?)?.toInt()] ?? (0, 'Unknown');
  final isDay = cur.containsKey('is_day') ? cur['is_day'] : 1;
  if (wtype == 1 && (isDay == 0 || isDay == null || isDay == false)) (wtype, text) = (16, 'Clear night');

  final nowIso = cur['time'] as String;
  final hourly = (d['hourly'] as Map).cast<String, Object?>();
  final hours = (hourly['time'] as List).cast<String>();
  final probs = (hourly['precipitation_probability'] as List);
  final upcoming = <(String, num?)>[];
  for (var i = 0; i < hours.length && i < probs.length; i++) {
    if (hours[i].compareTo(nowIso.substring(0, 13)) >= 0) upcoming.add((hours[i], probs[i] as num?));
  }
  final up = upcoming.length > 36 ? upcoming.sublist(0, 36) : upcoming;
  var rainIcon = 0;
  var rainHint = '0%', rainText = 'no rain expected';
  for (var i = 0; i < up.length; i++) {
    if ((up[i].$2 ?? 0) >= rainProbThreshold) {
      final t = up[i].$1;
      rainIcon = 1;
      if (i == 0) {
        (rainHint, rainText) = ('Now', 'rain now');
      } else if (t.substring(0, 10) != nowIso.substring(0, 10) && i >= 24 - int.parse(nowIso.substring(11, 13))) {
        (rainHint, rainText) = ('Tmr', 'rain tomorrow');
      } else {
        (rainHint, rainText) = ('${i}h', 'rain in $i h');
      }
      break;
    }
  }

  final daily = (d['daily'] as Map).cast<String, Object?>();
  final events = <(String, int)>[
    for (final t in (daily['sunrise'] as List).cast<String>()) (t, 0),
    for (final t in (daily['sunset'] as List).cast<String>()) (t, 1),
  ]..sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });
  var sunsetSelect = 1;
  var sunsetHint = '-', sunText = '';
  for (final (t, kind) in events) {
    if (t.compareTo(nowIso) > 0) {
      sunsetSelect = kind;
      var h = _lstrip0(_hhmm(t));
      if (h.isEmpty) h = '0:00';
      if (h.startsWith(':')) h = '0$h';
      sunsetHint = h;
      sunText = '${kind == 1 ? 'sunset' : 'sunrise'} $sunsetHint';
      break;
    }
  }
  final tempC = pyRoundInt((cur['temperature_2m'] as num).toDouble());
  final tempF = pyRoundInt(tempC * 9 / 5 + 32);
  return {
    'temp_c': tempC,
    'weather_type': wtype,
    'status': text.length > 32 ? text.substring(0, 32) : text,
    'rain_icon': rainIcon,
    'rain_hint': rainHint,
    'sunset_select': sunsetSelect,
    'sunset_hint': sunsetHint,
    'summary': '$tempC°C / $tempF°F ${text.toLowerCase()}; $rainText; $sunText',
  };
}
