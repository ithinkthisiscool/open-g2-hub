/// Public data the phone fetches for the dashboard: live weather (Open-Meteo), news (RSS +
/// article text), calendars (ICS link + the phone's own calendars) and stock quotes (Yahoo).
/// Each service updates AppData; the sync engine then pushes the section.
library;

import 'dart:async';

import 'package:device_calendar/device_calendar.dart' as dc;
import 'package:geolocator/geolocator.dart';

import '../hub/models.dart';
import '../logic/calendar_sync.dart' as ics;
import '../logic/feeds.dart' as feeds;
import '../logic/local_zone.dart';
import '../logic/stock_quotes.dart' as quotes;
import '../logic/weather_logic.dart' as wl;
import '../protocol/hub_format.dart';
import 'net.dart';

/// What the phone allows for location (for the guidance shown next to "Use my location").
enum LocationAccess { granted, denied, deniedForever, serviceOff }

/// GPS position (when the user granted location), or null.
class LocationService {
  /// Ask for permission (call from a user action).
  static Future<bool> request() async => await requestAccess() == LocationAccess.granted;

  /// Ask for permission and say why it is not available.
  static Future<LocationAccess> requestAccess() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.serviceOff;
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      return _access(p);
    } catch (_) {
      return LocationAccess.denied;
    }
  }

  /// The current state, without prompting.
  static Future<LocationAccess> access() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.serviceOff;
      return _access(await Geolocator.checkPermission());
    } catch (_) {
      return LocationAccess.denied;
    }
  }

  static LocationAccess _access(LocationPermission p) => switch (p) {
        LocationPermission.always || LocationPermission.whileInUse => LocationAccess.granted,
        LocationPermission.deniedForever => LocationAccess.deniedForever,
        _ => LocationAccess.denied,
      };

  /// Android's page for this app (to allow a permission that was denied for good).
  static Future<void> openAppSettings() async {
    try {
      await Geolocator.openAppSettings();
    } catch (_) {}
  }

  /// The phone's location (GPS) switch.
  static Future<void> openLocationSettings() async {
    try {
      await Geolocator.openLocationSettings();
    } catch (_) {}
  }

  static Future<bool> granted() async {
    try {
      final p = await Geolocator.checkPermission();
      return p == LocationPermission.always || p == LocationPermission.whileInUse;
    } catch (_) {
      return false;
    }
  }

  /// A recent fix without prompting; null when not allowed or unavailable.
  static Future<(double, double)?> current() async {
    if (!await granted()) return null;
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && DateTime.now().difference(last.timestamp) < const Duration(minutes: 30)) {
        return (last.latitude, last.longitude);
      }
      final p = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.low, timeLimit: Duration(seconds: 15)));
      return (p.latitude, p.longitude);
    } catch (_) {
      return null;
    }
  }

  static Stream<Position> stream() =>
      Geolocator.getPositionStream(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5));
}

/// Shown when the weather service cannot be reached.
const String offlineMessage = "Couldn't reach the weather service. Check your internet connection and try again.";

/// The label used for a GPS reading.
const String currentLocationLabel = 'Current location';

class WeatherService {
  WeatherService(this.net, {Future<(double, double)?> Function()? gps}) : gps = gps ?? LocationService.current;
  final Net net;

  /// Where GPS fixes come from (tests replace it).
  Future<(double, double)?> Function() gps;

  /// City → (label, lat, lon) via Open-Meteo geocoding (first match).
  Future<(String, double, double)> geocode(String city) async {
    final places = await search(city);
    final p = places.first;
    return (p.label, p.lat, p.lon);
  }

  /// Every place matching [query] ("Springfield", "Springfield, Missouri", "Paris, FR").
  /// Throws a StateError with a message for the user when nothing matches or the phone is offline.
  Future<List<wl.GeoPlace>> search(String query) async {
    final q = query.trim();
    final (name, _) = wl.splitPlaceQuery(q);
    if (name.isEmpty) throw StateError('Type a city or town first.');
    Object? j;
    try {
      j = await net.getJson(Uri.parse(wl.geocodeUrl).replace(queryParameters: {'name': name, 'count': '${wl.geocodeCount}', 'language': 'en'}));
    } on NetError {
      throw StateError(offlineMessage);
    } on FormatException {
      throw StateError(offlineMessage);
    }
    final places = wl.geocodePlaces(j is Map ? j.cast<String, Object?>() : null, q);
    if (places.isEmpty) throw StateError('No place called "$q" found. Check the spelling, or try a nearby larger town.');
    return places;
  }

  /// Fetch live conditions for [w] (GPS or the chosen city) into w.last. Throws a StateError with
  /// a message for the user.
  Future<void> refresh(WeatherConfig w) async {
    double? lat, lon;
    if (w.useGps) {
      final p = await gps();
      if (p != null) {
        (lat, lon) = p;
        w.place = currentLocationLabel;
      } else if (w.lat == null && w.city.trim().isEmpty) {
        throw StateError('Your location is not available. Allow location for G2 Hub (and turn on the phone\'s location), or type a city.');
      }
    }
    if (lat == null) {
      if (w.lat == null || w.lon == null) {
        if (w.city.trim().isEmpty) throw StateError(w.useGps ? 'Location not available — allow location or type a city.' : 'Type a city or town, then press search.');
        final (label, la, lo) = await geocode(w.city.trim());
        w
          ..lat = la
          ..lon = lo
          ..place = label;
      } else if (w.place.isEmpty || w.place == currentLocationLabel) {
        // Back from GPS to the saved city: show the city's name again.
        w.place = w.city.trim().isNotEmpty ? w.city.trim() : '${w.lat!.toStringAsFixed(2)}, ${w.lon!.toStringAsFixed(2)}';
      }
      lat = w.lat;
      lon = w.lon;
    }
    final Object? j;
    try {
      j = await net.getJson(Uri.parse(wl.forecastUrl).replace(queryParameters: wl.forecastParams(lat!, lon!)));
    } on NetError {
      throw StateError(offlineMessage);
    } on FormatException {
      throw StateError(offlineMessage);
    }
    if (j is! Map) throw StateError(offlineMessage);
    w.last = wl.weatherFromForecast(j.cast<String, Object?>());
    w.lastAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }

  bool stale(WeatherConfig w) => w.lastAt == null || DateTime.now().millisecondsSinceEpoch ~/ 1000 - w.lastAt! >= wl.refreshEvery.inSeconds - 30;
}

class NewsService {
  NewsService(this.net);
  final Net net;
  static const concurrency = 5;

  Future<List<feeds.FeedItem>> _feed(String id) async {
    final src = feeds.feedSource(id);
    if (src == null) throw StateError('unknown source $id');
    final text = await net.getText(Uri.parse(src.$2), headers: const {'User-Agent': 'Mozilla/5.0 (compatible; G2Hub/1.0)'}, timeout: const Duration(seconds: 12));
    return [for (final i in feeds.parseFeed(text)) i..source = src.$1];
  }

  Future<String> _article(String url) async {
    if (url.isEmpty || url.contains('news.ycombinator.com')) return '';
    try {
      final t = await net.getText(Uri.parse('https://r.jina.ai/$url'), headers: const {'Accept': 'text/plain'}, timeout: const Duration(seconds: 12));
      final cleaned = feeds.cleanJina(t);
      if (cleaned.runes.length > 80) return feeds.smartTrim(cleaned, feeds.articleMaxChars);
    } catch (_) {}
    try {
      final page = await net.getText(Uri.parse(url), timeout: const Duration(seconds: 8));
      return feeds.htmlParagraphText(page);
    } catch (_) {
      return '';
    }
  }

  Future<List<T>> _bounded<T>(List<Future<T> Function()> jobs) async {
    final out = List<T?>.filled(jobs.length, null);
    var next = 0;
    Future<void> worker() async {
      while (next < jobs.length) {
        final i = next++;
        out[i] = await jobs[i]();
      }
    }

    await Future.wait([for (var i = 0; i < concurrency && i < jobs.length; i++) worker()]);
    return out.cast<T>();
  }

  /// hub feeds.fetch_stories: (stories, errors).
  Future<(List<Map<String, Object?>>, List<String>)> fetchStories(List<String> ids, {int count = 5, Set<String> skip = const {}}) async {
    final errors = <String>[];
    final lists = await _bounded<List<feeds.FeedItem>>([
      for (final id in ids)
        () async {
          try {
            return await _feed(id).timeout(const Duration(seconds: 15));
          } catch (e) {
            errors.add('$id: ${e is TimeoutException ? 'timed out after 15s' : e}');
            return <feeds.FeedItem>[];
          }
        }
    ]);
    final picked = feeds.interleave(lists, count, skip);
    final texts = await _bounded<String>([
      for (final it in picked) () => _article(it.url).timeout(const Duration(seconds: 25), onTimeout: () => ''),
    ]);
    return ([for (var i = 0; i < picked.length; i++) feeds.finishStory(picked[i], texts[i])], errors);
  }

  /// hub auto_push_hn: cached unless [force] or stale; skips titles already shown and starts
  /// over when every story was seen. Returns the errors (sources that failed).
  Future<List<String>> refresh(NewsConfig cfg, NewsCache cache, {bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final sameFeeds = cache.feeds.join('\n') == cfg.feeds.join('\n');
    if (!force && sameFeeds && cache.stories.isNotEmpty && now - cache.fetchedAt < feeds.refreshEvery.inSeconds) return const [];
    var seen = force && sameFeeds ? [...cache.seenTitles] : <String>[];
    var (stories, errors) = await fetchStories(cfg.feeds, skip: seen.toSet());
    if (force && stories.isEmpty) {
      seen = [];
      (stories, errors) = await fetchStories(cfg.feeds);
    }
    if (stories.isEmpty) {
      if (errors.isNotEmpty) throw StateError(errors.join('; '));
      return errors;
    }
    cache
      ..stories = stories
      ..fetchedAt = now
      ..seenTitles = feeds.updateSeen(seen, stories.map((s) => s['title'] as String))
      ..feeds = [...cfg.feeds];
    return errors;
  }

  /// What the widget shows: the user's items or the fetched stories.
  static List<NewsItem> articles(AppData d) => d.newsConfig.mode == 'manual'
      ? d.news
      : [
          for (final s in d.newsCache.stories)
            NewsItem(title: (s['title'] ?? '').toString(), source: (s['source'] ?? '').toString(), content: (s['content'] ?? s['url'] ?? '').toString())
        ];
}

class CalendarService {
  CalendarService(this.net, {this.local = const SystemZone()});
  final Net net;
  final LocalZone local;
  final _dc = dc.DeviceCalendarPlugin();

  /// Fetch the ICS link; a failure keeps the previous events. Returns true when they changed.
  Future<bool> syncIcs(CalendarSources c) async {
    if (c.icsUrl.isEmpty || !c.icsEnabled) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final (events, note) = await ics.syncIcs(c.icsUrl, (u) => net.getText(Uri.parse(u), timeout: const Duration(seconds: 20)), now: now, local: local);
    c.icsLastTry = now;
    if (note.isNotEmpty) {
      c.icsNote = note;
      return false;
    }
    final before = c.icsEvents.map((e) => e.toJson().toString()).join();
    c
      ..icsEvents = events
      ..icsLastOk = now
      ..icsNote = '';
    return before != events.map((e) => e.toJson().toString()).join();
  }

  Future<bool> hasPhonePermission() async {
    try {
      return (await _dc.hasPermissions()).data == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestPhonePermission() async {
    try {
      return (await _dc.requestPermissions()).data == true;
    } catch (_) {
      return false;
    }
  }

  Future<List<(String, String)>> phoneCalendars() async {
    try {
      final r = await _dc.retrieveCalendars();
      return [for (final c in r.data ?? const <dc.Calendar>[]) (c.id ?? '', [c.name, c.accountName].whereType<String>().join(' · '))];
    } catch (_) {
      return const [];
    }
  }

  /// Today .. +3 days from the phone's calendars. Returns true when they changed.
  Future<bool> syncPhone(CalendarSources c) async {
    if (!c.phoneEnabled || !await hasPhonePermission()) return false;
    ensureTimeZones();
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: ics.windowDays));
    final out = <CalEvent>[];
    for (final (id, _) in await phoneCalendars()) {
      if (c.phoneCalendarIds.isNotEmpty && !c.phoneCalendarIds.contains(id)) continue;
      try {
        final r = await _dc.retrieveEvents(id, dc.RetrieveEventsParams(startDate: start, endDate: end));
        for (final e in r.data ?? const <dc.Event>[]) {
          if (e.start == null || e.end == null) continue;
          if (e.status == dc.EventStatus.Canceled) continue;
          var s = e.start!.millisecondsSinceEpoch ~/ 1000, en = e.end!.millisecondsSinceEpoch ~/ 1000;
          final allDay = e.allDay == true;
          if (allDay) {
            // All-day events come as UTC midnights: show them on the local day.
            final sd = e.start!.toUtc(), ed = e.end!.toUtc();
            s = local.epochOf(DateTime.utc(sd.year, sd.month, sd.day));
            en = local.epochOf(DateTime.utc(ed.year, ed.month, ed.day));
            if (en <= s) en = s + 86400;
          }
          out.add(CalEvent(id: 'dev:$id:${e.eventId}@$s', title: (e.title ?? '').trim().isEmpty ? 'Event' : e.title!.trim(),
              location: (e.location ?? '').trim(), start: s, end: en, allDay: allDay));
        }
      } catch (_) {}
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    final before = c.phoneEvents.map((e) => e.toJson().toString()).join();
    c.phoneEvents = out;
    return before != out.map((e) => e.toJson().toString()).join();
  }
}

class StocksService {
  StocksService(this.net);
  final Net net;

  /// (quotes, errors) in the order given; one failing symbol does not stop the others.
  Future<(List<Map<String, Object?>>, List<String>)> fetch(List<String> symbols) async {
    final results = await Future.wait([
      for (final s in symbols)
        () async {
          try {
            final j = await net.getJson(Uri.parse(quotes.chartUrl.replaceFirst('{symbol}', Uri.encodeComponent(s))),
                headers: quotes.headers, timeout: const Duration(seconds: 10));
            return quotes.quoteFromChart(s, (j as Map).cast<String, Object?>());
          } on StateError catch (e) {
            return e.message;
          } on NetError catch (e) {
            return '$s: ${e.message.contains('404') ? 'unknown symbol' : e.message}';
          } catch (e) {
            return '$s: ${e.runtimeType}';
          }
        }()
    ]);
    return ([for (final r in results) if (r is Map<String, Object?>) r], [for (final r in results) if (r is String) r]);
  }
}
