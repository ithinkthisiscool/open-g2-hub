/// Turn-by-turn navigation on the glasses' Navigate screen. Routing like the hub
/// (hub/nav_routing.py: OSM Nominatim + the public OSRM server); the phone adds GPS: the route
/// starts at the current position and advances by itself as you move (NavTracker), re-routing
/// when you leave it. Opening Navigate from the glasses menu offers the saved favorites.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../hub/features.dart';
import '../hub/models.dart';
import '../logic/nav_routing.dart' as r;
import 'data_services.dart';
import 'net.dart';

class ActiveRoute {
  ActiveRoute(this.from, this.to, this.steps, this.dest);
  final String from;
  final String to;
  final List<r.NavStep> steps;
  final (double, double) dest;
  int index = -1;
  bool get finished => index >= steps.length - 1;
}

class NavService extends ChangeNotifier {
  NavService({required this.net, required this.features, required this.data, required this.log, Stream<(double, double)> Function()? positions})
      : _positions = positions ?? (() => LocationService.stream().map((p) => (p.latitude, p.longitude)));

  final Net net;
  final G2Features? Function() features;
  final AppData Function() data;
  final void Function(String m, {bool warn}) log;
  final Stream<(double, double)> Function() _positions;

  ActiveRoute? route;
  r.NavTracker? tracker;
  StreamSubscription<(double, double)>? _gps;
  DateTime _lastCall = DateTime.fromMillisecondsSinceEpoch(0);
  String? status;
  bool busy = false;

  Future<Object?> _polite(Uri url) async {
    final wait = r.minInterval - DateTime.now().difference(_lastCall);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    try {
      return await net.getJson(url, headers: const {'Accept': 'application/json'}, timeout: const Duration(seconds: 10));
    } on NetError catch (e) {
      throw r.RoutingError('routing service unreachable (${e.message}); routing needs internet access');
    } finally {
      _lastCall = DateTime.now();
    }
  }

  Future<(double, double, String)> geocode(String place) async {
    final p = place.trim();
    if (p.isEmpty) throw r.RoutingError('place required');
    final ll = r.parseLatLon(p);
    if (ll != null) return (ll.$1, ll.$2, '${ll.$1.toStringAsFixed(5)}, ${ll.$2.toStringAsFixed(5)}');
    final data = await _polite(Uri.parse(r.nominatim).replace(queryParameters: {'format': 'json', 'limit': '1', 'q': p}));
    return r.parseNominatim(data, p);
  }

  Future<List<r.NavStep>> plan((double, double) a, (double, double) b) async {
    final url = r.osrm
        .replaceFirst('{lon1}', '${a.$2}')
        .replaceFirst('{lat1}', '${a.$1}')
        .replaceFirst('{lon2}', '${b.$2}')
        .replaceFirst('{lat2}', '${b.$1}');
    return r.parseOsrm(await _polite(Uri.parse(url).replace(queryParameters: {'steps': 'true', 'overview': 'false'})));
  }

  /// Plan from [from] (empty = GPS) to [to], open Navigate and show the first turn.
  Future<PushResult> start(String to, {String from = ''}) async {
    final f = features();
    if (f == null) return PushResult(false, 'Connect your glasses first');
    busy = true;
    status = 'Finding a route…';
    notifyListeners();
    try {
      (double, double, String) a;
      if (from.trim().isEmpty) {
        final pos = await LocationService.current();
        if (pos == null) return PushResult(false, 'No GPS fix — allow location or type a start');
        a = (pos.$1, pos.$2, 'Current location');
      } else {
        a = await geocode(from);
      }
      final b = await geocode(to);
      final steps = await plan((a.$1, a.$2), (b.$1, b.$2));
      route = ActiveRoute(a.$3, b.$3, steps, (b.$1, b.$2));
      await f.navigationStart();
      await _push(0);
      if (data().nav.autoAdvance && from.trim().isEmpty) _follow();
      status = null;
      return PushResult(true, '${steps.length} steps to ${b.$3}');
    } on r.RoutingError catch (e) {
      status = e.message;
      return PushResult(false, e.message);
    } catch (e) {
      // A malformed server reply or a dropped link: report it (this also runs from the glasses
      // menu, where nobody would catch an exception).
      status = 'Navigation failed: ${e is StateError ? e.message : e}';
      log(status!, warn: true);
      return PushResult(false, status!);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _push(int i, {double? toHereM}) async {
    final rt = route;
    final f = features();
    if (rt == null || f == null) return;
    rt.index = i;
    final fl = r.stepFields(rt.steps, i, DateTime.now(), toHereM: toHereM);
    await f.navigationStep(fl['direction']!,
        distance: fl['distance'],
        road: fl['road'],
        remainingTime: fl['remaining_time'],
        remainingDistance: fl['remaining_distance'],
        eta: fl['eta'],
        method: data().nav.method);
    if (i == rt.steps.length - 1) await f.navigationEvent('arrive');
    notifyListeners();
  }

  /// Manual "next turn" (or when GPS is off).
  Future<PushResult> next() async {
    final rt = route;
    if (rt == null) return PushResult(false, 'No route loaded');
    if (rt.finished) return PushResult(false, 'Route finished');
    await _push(rt.index + 1);
    tracker?.index = rt.index;
    return PushResult(true, 'Step ${rt.index + 1} of ${rt.steps.length}');
  }

  void _follow() {
    final rt = route;
    if (rt == null) return;
    tracker = r.NavTracker(rt.steps)..index = 1;
    _gps?.cancel();
    _gps = _positions().listen((p) => onPosition(p.$1, p.$2), onError: (Object _) {});
  }

  /// One GPS fix (public for tests).
  Future<void> onPosition(double lat, double lon) async {
    final t = tracker, rt = route;
    if (t == null || rt == null || features() == null) return;
    switch (t.update(lat, lon)) {
      case r.NavUpdate.advanced:
        await _push(t.index, toHereM: t.toNext);
      case r.NavUpdate.distance:
        await _push(t.index, toHereM: t.toNext);
      case r.NavUpdate.arrived:
        await _push(rt.steps.length - 1, toHereM: 0);
        await _gps?.cancel();
        _gps = null;
      case r.NavUpdate.offRoute:
        log('Navigation: off route — finding a new one', warn: true);
        await features()?.navigationEvent('recalculating');
        try {
          final steps = await plan((lat, lon), rt.dest);
          route = ActiveRoute('Current location', rt.to, steps, rt.dest);
          tracker = r.NavTracker(steps)..index = 1;
          await _push(0);
        } on r.RoutingError catch (e) {
          log('Re-route failed: ${e.message}', warn: true);
        } catch (e) {
          log('Re-route failed: $e', warn: true);
        }
      case r.NavUpdate.none:
        break;
    }
  }

  Future<PushResult> singleTurn(String direction, {String? distance, String? road}) async {
    final f = features();
    if (f == null) return PushResult(false, 'Connect your glasses first');
    return f.navigationStep(direction, distance: distance, road: road, method: data().nav.method);
  }

  Future<void> stop() async {
    await _gps?.cancel();
    _gps = null;
    route = null;
    tracker = null;
    final f = features();
    if (f != null && f.currentApp == 'navigation') await f.closeApp();
    notifyListeners();
  }

  /// Wire the glasses-side menu launch to the favorites (called on every connect).
  void attach(G2Features f) {
    f.onNavMenuStartup = () => unawaited(f.navigationFavorites([for (final x in data().nav.favorites) x.name]).catchError((Object e) => log('Navigation: favorites not sent ($e)', warn: true)));
    f.onNavLocationSelected = (i, name) {
      final favs = data().nav.favorites;
      final fav = i >= 0 && i < favs.length ? favs[i] : favs.where((x) => x.name == name).firstOrNull;
      Future<void> error(String m) => f.navigationError(m).catchError((Object e) => log('Navigation: error not shown ($e)', warn: true));
      if (fav == null) {
        unawaited(error('Unknown place'));
        return;
      }
      unawaited(start(fav.query).then((res) => res.ok ? null : error(res.message)));
    };
    f.onNavExit = () {
      _gps?.cancel();
      _gps = null;
      route = null;
      tracker = null;
      notifyListeners();
    };
  }

  static Future<bool> gpsAllowed() => LocationService.granted();
  static Future<LocationPermission> permission() => Geolocator.checkPermission();
}
