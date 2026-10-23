/// EvenHub (.ehpk) apps on the phone, the official app's way: install → app id + an entry in the
/// glasses menu → when the user opens it on the glasses (EvenHub cmd 17) the app's web page runs
/// in a WebView that is never shown (webview_flutter). The local host injects a small shim that
/// provides window.flutter_inappwebview.callHandler over a JavaScript channel; the page's calls
/// (from G2 Hub's own bridge, g2-hub/bridge/g2_hub_bridge.js, or from the Even SDK copy a
/// third-party .ehpk bundles; we ship none) become SID 0xE0 page commands. Port of g2-hub/hub/evenhub_runtime.py sections 3, 8-10 (registry,
/// bridge, host, runtime). EXPERIMENTAL: plugin menu items and cmd 17 are not confirmed live.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../hub/features.dart';
import '../logic/ehpk.dart' as ehpk;
import '../protocol/evenhub.dart' as eh;
import '../protocol/evenhub_pages.dart' as ehp;
import 'data_services.dart' show LocationService;
import 'image_widgets.dart' show decodeToGray4;

const int firstAppId = 20001;

/// Installed apps: `root/registry.json`, `root/apps/PACKAGE/{app.json, dist/...}`,
/// `root/storage/PACKAGE.json` (the app's setLocalStorage values).
class AppRegistry {
  AppRegistry(this.root);
  final Directory root;

  static Future<AppRegistry> open() async => AppRegistry(Directory('${(await getApplicationSupportDirectory()).path}/evenhub'));

  File get _file => File('${root.path}/registry.json');
  Directory appDir(String pid) => Directory('${root.path}/apps/$pid');
  Directory get storageDir => Directory('${root.path}/storage');

  Map<String, Map<String, Object?>> load() {
    try {
      final j = jsonDecode(_file.readAsStringSync()) as Map;
      return {for (final e in j.entries) e.key.toString(): (e.value as Map).cast<String, Object?>()};
    } catch (_) {
      return {};
    }
  }

  void _save(Map<String, Map<String, Object?>> reg) {
    root.createSync(recursive: true);
    final tmp = File('${_file.path}.tmp')..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(reg));
    tmp.renameSync(_file.path);
  }

  List<Map<String, Object?>> list() => load().values.toList()..sort((a, b) => (a['app_id'] as int).compareTo(b['app_id'] as int));

  Map<String, Object?>? get(Object key) {
    final reg = load();
    final asInt = key is int ? key : int.tryParse('$key');
    if (asInt != null) {
      for (final e in reg.values) {
        if (e['app_id'] == asInt) return e;
      }
      return null;
    }
    return reg[key];
  }

  /// Install from .ehpk bytes (an update keeps the app id). Returns the registry entry.
  Map<String, Object?> install(List<int> bytes, {String label = 'file'}) {
    final pkg = ehpk.readEhpk(bytes);
    final manifest = pkg.manifest;
    ehpk.checkManifest(manifest);
    final files = pkg.distFiles();
    final pid = manifest['package_id'] as String;
    final entry = (manifest['entrypoint'] as String?)?.isNotEmpty == true ? manifest['entrypoint'] as String : 'index.html';
    if (!files.containsKey(entry)) throw ehpk.EhpkError("entrypoint '$entry' not in package");
    final reg = load();
    final old = reg[pid];
    var appId = old?['app_id'] as int?;
    if (appId == null) {
      final used = {for (final e in reg.values) e['app_id']};
      appId = firstAppId;
      while (used.contains(appId)) {
        appId = appId! + 1;
      }
    }
    final finalDir = appDir(pid);
    final staging = Directory('${finalDir.path}.installing');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    for (final e in files.entries) {
      ehpk.checkMemberName(e.key);
      final f = File('${staging.path}/dist/${e.key}');
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(e.value);
    }
    File('${staging.path}/app.json').writeAsStringSync(jsonEncode(manifest));
    if (finalDir.existsSync()) finalDir.deleteSync(recursive: true);
    staging.renameSync(finalDir.path);
    final e = <String, Object?>{
      'package_id': pid,
      'app_id': appId,
      'name': ehpk.cleanText(manifest['name'] ?? pid, 64),
      'menu_name': ehp.menuName(manifest['name'] ?? pid),
      'version': ehpk.cleanText(manifest['version'] ?? '', 32),
      'entrypoint': entry,
      'permissions': ehpk.displayPermissions(manifest['permissions']),
      'problems': [for (final p in ehpk.validateManifest(manifest).take(30)) ehpk.cleanText(p, 300)],
      'source': ehpk.cleanText(label, 300),
      'kind': pkg.kindLabel,
      'installed_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
    reg[pid] = e;
    _save(reg);
    return e;
  }

  bool uninstall(String pid) {
    final reg = load();
    if (reg.remove(pid) == null) return false;
    final d = appDir(pid);
    if (d.existsSync()) d.deleteSync(recursive: true);
    _save(reg);
    return true;
  }
}

/// The phone's location for EvenHub apps that declare the `location` permission (bridge calls
/// getAppLocation / startAppLocationUpdates → appLocationChanged). Fixes are location
/// maps: latitude, longitude, accuracy, altitude, speed, heading, timestamp (ms).
abstract class AppLocationProvider {
  /// The OS allows G2 Hub to use the location (never prompts: apps run hidden).
  Future<bool> allowed();
  Future<Map<String, Object?>?> current({String accuracy = 'medium', Duration timeout = const Duration(seconds: 10)});
  Stream<Map<String, Object?>> updates({String accuracy = 'medium', double distanceFilter = 0});
}

bool declaresLocation(Map<String, Object?> app) =>
    ((app['permissions'] as List?) ?? const []).any((p) => p is Map && p['name'] == 'location');

/// Geolocator-backed provider (the app).
class GeolocatorAppLocation implements AppLocationProvider {
  const GeolocatorAppLocation();
  static LocationAccuracy _acc(String a) => switch (a) {
        'high' => LocationAccuracy.high,
        'low' => LocationAccuracy.low,
        _ => LocationAccuracy.medium,
      };
  static Map<String, Object?> fix(Position p) => {
        'latitude': p.latitude,
        'longitude': p.longitude,
        'accuracy': p.accuracy,
        'altitude': p.altitude,
        'speed': p.speed,
        'heading': p.heading,
        'timestamp': p.timestamp.millisecondsSinceEpoch,
      };

  @override
  Future<bool> allowed() async {
    try {
      return await Geolocator.isLocationServiceEnabled() && await LocationService.granted();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Map<String, Object?>?> current({String accuracy = 'medium', Duration timeout = const Duration(seconds: 10)}) async {
    try {
      return fix(await Geolocator.getCurrentPosition(locationSettings: LocationSettings(accuracy: _acc(accuracy), timeLimit: timeout)));
    } catch (_) {
      try {
        final last = await Geolocator.getLastKnownPosition();
        return last == null ? null : fix(last);
      } catch (_) {
        return null;
      }
    }
  }

  @override
  Stream<Map<String, Object?>> updates({String accuracy = 'medium', double distanceFilter = 0}) =>
      Geolocator.getPositionStream(locationSettings: LocationSettings(accuracy: _acc(accuracy), distanceFilter: distanceFilter.round()))
          .map(fix);
}

/// Host side of callHandler('evenAppMessage', ...) for one running app (hub EvenHubBridge).
class EvenHubBridge {
  EvenHubBridge(this.app, this.features, this.storageDir,
      {required this.widgetId, this.push, this.onExit, this.log, this.batteryLevel, this.location});
  final Map<String, Object?> app;
  final G2Features Function() features;
  final Directory storageDir;
  final int widgetId;
  final Future<void> Function(String method, Object? data)? push;
  final void Function(String reason)? onExit;
  final void Function(String m)? log;
  final int? Function()? batteryLevel;

  /// The phone's location, for apps that declare the `location` permission (null = none).
  final AppLocationProvider? location;
  StreamSubscription<Map<String, Object?>>? _locationSub;
  Map? page;
  bool pageCreated = false;
  int imageSession = 0;
  final calls = <(String, Object?)>[];

  String get pid => app['package_id'] as String;
  File get _storage => File('${storageDir.path}/$pid.json');

  Future<Uint8List?> _request(Uint8List payload, String label) =>
      features().evenHubRequest(payload, G2Features.readMagic(payload), label: label);

  Future<Object?> handle(String handler, List<dynamic> args) async {
    if (handler == 'evenHubRuntimeUncaughtException') {
      log?.call('[$pid] page error: ${args.isNotEmpty ? args.first : ''}');
      return true;
    }
    if (handler != 'evenAppMessage') return null;
    Object? msg = args.isNotEmpty ? args.first : const {};
    if (msg is String) msg = jsonDecode(msg);
    if (msg is! Map) return null;
    final data = msg['data'] is Map ? (msg['data'] as Map) : <String, Object?>{};
    final method = (msg['method'] ?? '').toString();
    return call(method.length > 64 ? method.substring(0, 64) : method, data);
  }

  Future<Object?> call(String method, Map data) async {
    Object? result;
    try {
      result = await _dispatch(method, data);
    } catch (e) {
      log?.call('[$pid] $method failed: $e');
      result = null;
    }
    calls.add((method, result));
    if (calls.length > 200) calls.removeAt(0);
    return result;
  }

  Map<String, Object?> deviceStatus() => {
        'sn': '', 'connectType': 'connected', 'isWearing': true, 'batteryLevel': batteryLevel?.call() ?? 0, //
        'isCharging': false, 'isInCase': false,
      };

  Future<Object?> _dispatch(String method, Map data) async {
    switch (method) {
      case 'getUserInfo':
        return {'uid': 0, 'name': 'G2 Hub', 'avatar': '', 'country': ''};
      case 'getGlassesInfo':
        return {'model': 'g2', 'sn': '', 'status': deviceStatus()};
      case 'setLocalStorage':
        final store = _readStore();
        store['${data['key'] ?? ''}'] = '${data['value'] ?? ''}';
        storageDir.createSync(recursive: true);
        _storage.writeAsStringSync(jsonEncode(store));
        return true;
      case 'getLocalStorage':
        return _readStore()['${data['key'] ?? ''}'] ?? '';
      case 'getAppLocation':
        if (!await _locationAllowed()) return null;
        final ms = (data['timeoutMs'] as num?)?.toInt() ?? 10000;
        return location!.current(accuracy: '${data['accuracy'] ?? 'medium'}', timeout: Duration(milliseconds: ms.clamp(1000, 30000)));
      case 'startAppLocationUpdates':
        if (!await _locationAllowed()) return false;
        await _locationSub?.cancel();
        _locationSub = location!
            .updates(accuracy: '${data['accuracy'] ?? 'medium'}', distanceFilter: ((data['distanceFilter'] as num?) ?? 0).toDouble())
            .listen((fix) => push?.call('appLocationChanged', fix), onError: (Object _) {});
        return true;
      case 'stopAppLocationUpdates':
        await _locationSub?.cancel();
        _locationSub = null;
        return true;
      case 'pickImageFromAlbum':
      case 'captureImageFromCamera':
        return null;
      case 'createStartUpPageContainer':
        if (ehp.validatePage(data).isNotEmpty || pageCreated) return 1;
        final f = features();
        f.holdHeartbeat = true;
        f.s.startHeartbeat();
        final pb = await _request(ehp.buildCreatePage(f.s.nextMagic(), data, widgetId: widgetId), 'eh-create');
        final code = ehp.ackCode(pb, ehp.cmdCreateAck) ?? 0; // no ack: assume success like the hub
        if (code == 0) {
          page = data;
          pageCreated = true;
        }
        return code;
      case 'rebuildPageContainer':
        if (ehp.validatePage(data).isNotEmpty) return false;
        if (!pageCreated) return (await _dispatch('createStartUpPageContainer', data)) == 0;
        final pb = await _request(ehp.buildRebuildPage(features().s.nextMagic(), data), 'eh-rebuild');
        final ok = ehp.ackCode(pb, ehp.cmdRebuildAck) == ehp.okCode[ehp.cmdRebuildAck];
        if (ok) page = data;
        return ok;
      case 'textContainerUpgrade':
        final pb = await _request(ehp.buildTextUpgrade(features().s.nextMagic(), data), 'eh-text');
        final code = ehp.ackCode(pb, ehp.cmdTextAck);
        return code == 0 || code == ehp.okCode[ehp.cmdTextAck];
      case 'updateImageRawData':
        Map? box;
        for (final c in (page?['imageObject'] as List? ?? const [])) {
          if (c is Map && c['containerID'] == data['containerID']) box = c;
        }
        if (box == null) return ehp.imgSendFailed;
        final w = (box['width'] as num).toInt(), h = (box['height'] as num).toInt();
        Uint8List? pix;
        try {
          final v = data['imageData'];
          final bytes = v is String ? base64Decode(v.contains(',') ? v.split(',').last : v) : [for (final x in (v as List? ?? const [])) (x as num).toInt() & 0xFF];
          final packed = decodeToGray4(bytes, w, h);
          // The firmware only takes a 4-bit BMP: wrap the packed pixels before fragmenting.
          pix = packed == null ? null : eh.encodeBmp4bpp(packed, w, h);
        } catch (_) {
          pix = null;
        }
        if (pix == null) return ehp.imgException;
        imageSession++;
        final f = features();
        for (var i = 0, n = 0; i < pix.length; i += ehp.imageFragmentBytes, n++) {
          final end = i + ehp.imageFragmentBytes > pix.length ? pix.length : i + ehp.imageFragmentBytes;
          final pb = await _request(
              eh.buildImageRawData(f.s.nextMagic(), (box['containerID'] as num).toInt(), (box['containerName'] ?? '').toString(), pix.length, n,
                  pix.sublist(i, end),
                  mapSessionId: imageSession),
              'eh-image');
          if (ehp.ackCode(pb, ehp.cmdImageAck) != ehp.okCode[ehp.cmdImageAck]) return ehp.imgSendFailed;
        }
        return ehp.imgOk;
      case 'audioControl':
        if ((data['source'] ?? 'glasses') != 'glasses') return false;
        final pb = await _request(eh.buildAudioControl(features().s.nextMagic(), data['isOpen'] == true), 'eh-audio');
        return pb != null;
      case 'imuControl':
        final en = (data['iMUReportEn'] ?? data['isOpen']) == true;
        final pb = await _request(eh.buildImuControl(features().s.nextMagic(), en, (data['reportFrq'] as num?)?.toInt() ?? 500), 'eh-imu');
        return pb != null;
      case 'shutDownPageContainer':
        final mode = (data['exitMode'] as num?)?.toInt() ?? 0;
        final pb = await _request(ehp.buildShutdown(features().s.nextMagic(), mode), 'eh-shutdown');
        final code = ehp.ackCode(pb, ehp.cmdShutdownAck);
        if (mode == 0) onExit?.call('shutdown');
        return code == 0 || code == ehp.okCode[ehp.cmdShutdownAck];
    }
    log?.call('[$pid] unhandled method $method');
    return null;
  }

  /// Location is given only to apps that declare it, and only when the user allowed it for
  /// G2 Hub (apps run hidden, so they never trigger a permission prompt themselves).
  Future<bool> _locationAllowed() async {
    if (location == null) return false;
    if (!declaresLocation(app)) {
      log?.call('[$pid] asked for the location but does not declare the "location" permission');
      return false;
    }
    if (!await location!.allowed()) {
      log?.call('[$pid] asked for the location: allow location for G2 Hub (Apps → EvenHub apps)');
      return false;
    }
    return true;
  }

  /// The app stopped: no more location updates.
  Future<void> dispose() async {
    await _locationSub?.cancel();
    _locationSub = null;
  }

  Map<String, Object?> _readStore() {
    try {
      return (jsonDecode(_storage.readAsStringSync()) as Map).cast<String, Object?>();
    } catch (_) {
      return {};
    }
  }

  Future<Object?> deliverEvent(Map<String, Object?> event) async {
    final d = ehp.sdkEvent(event);
    if (d == null || push == null) return null;
    await push!('evenHubEvent', d);
    if (event['type'] == 'sys-event' && ehp.exitEvents.contains(event['event_type'])) onExit?.call((event['event_name'] ?? 'exit').toString());
    return d;
  }
}

/// Serves one app's files on 127.0.0.1 (random port) for the WebView.
class AppHost {
  AppHost(this.dist, this.entry, {this.appId = 0, this.network = true});
  final Directory dist;
  final String entry;
  final int appId;

  /// false: a Content-Security-Policy keeps the page off the network (no 'network' permission).
  final bool network;
  HttpServer? _server;
  String get url => 'http://127.0.0.1:${_server!.port}/$entry';

  static const _types = {
    'html': 'text/html; charset=utf-8', 'htm': 'text/html; charset=utf-8', 'js': 'application/javascript', //
    'mjs': 'application/javascript', 'css': 'text/css', 'json': 'application/json', 'png': 'image/png',
    'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'gif': 'image/gif', 'svg': 'image/svg+xml', 'webp': 'image/webp',
    'woff': 'font/woff', 'woff2': 'font/woff2', 'ttf': 'font/ttf', 'wasm': 'application/wasm', 'txt': 'text/plain',
  };

  Future<void> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = s;
    final root = dist.absolute.path;
    s.listen((req) async {
      final host = req.headers.host ?? '';
      if (host != '127.0.0.1' && host != 'localhost') {
        req.response.statusCode = 403;
        await req.response.close();
        return;
      }
      var rel = Uri.decodeComponent(req.uri.path).replaceFirst(RegExp(r'^/+'), '');
      if (rel.isEmpty) rel = entry;
      final f = File('$root/$rel');
      final ok = !rel.split('/').contains('..') && f.absolute.path.startsWith(root) && f.existsSync();
      if (!ok) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final ext = rel.split('.').last.toLowerCase();
      req.response.headers.set('Content-Type', _types[ext] ?? 'application/octet-stream');
      if (!network) {
        req.response.headers.set('Content-Security-Policy',
            "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob:; connect-src 'self'; img-src 'self' data: blob:");
      }
      if (ext == 'html' || ext == 'htm') {
        req.response.write(injectShim(f.readAsStringSync(), appId));
      } else {
        await req.response.addStream(f.openRead());
      }
      await req.response.close();
    });
  }

  Future<void> stop() async => _server?.close(force: true);
}

/// window.flutter_inappwebview.callHandler over the 'G2Bridge' JavaScript channel; the host
/// answers with window.__g2Resolve(id, ok, value).
const String shimJs = r'''(function () {
  if (window.__G2HUB_EVENHUB__) return;
  window.__G2HUB_EVENHUB__ = true;
  var pending = {}, next = 0;
  window.flutter_inappwebview = window.flutter_inappwebview || {};
  window.flutter_inappwebview.callHandler = function (name) {
    var args = Array.prototype.slice.call(arguments, 1);
    return new Promise(function (resolve, reject) {
      var id = ++next;
      pending[id] = {resolve: resolve, reject: reject};
      G2Bridge.postMessage(JSON.stringify({id: id, handler: name, args: args}));
    });
  };
  window.__g2Resolve = function (id, ok, value) {
    var p = pending[id];
    if (!p) return;
    delete pending[id];
    if (ok) p.resolve(value); else p.reject(new Error(String(value)));
  };
  window.addEventListener('error', function (e) {
    try { G2Bridge.postMessage(JSON.stringify({id: 0, handler: 'evenHubRuntimeUncaughtException',
      args: [{message: String(e && e.message), fatal: true}]})); } catch (x) {}
  });
})();''';

/// Put the shim (and the app id) first in `head`, like the hub's inject_shim.
String injectShim(String html, int appId) {
  final tag = '<script>window.__EVEN_HUB_APP_ID__ = $appId;\n$shimJs</script>';
  final m = RegExp(r'<head[^>]*>', caseSensitive: false).firstMatch(html);
  if (m != null) return html.replaceRange(m.end, m.end, tag);
  return '$tag$html';
}

/// One running app (hidden WebView + host + bridge) at a time.
class EvenHubRuntime extends ChangeNotifier {
  EvenHubRuntime({required this.registry, required this.features, this.log, this.batteryLevel, this.location = const GeolocatorAppLocation()});
  final AppRegistry registry;
  final G2Features? Function() features;
  final void Function(String m)? log;
  final int? Function()? batteryLevel;
  final AppLocationProvider? location;

  Map<String, Object?>? current;
  EvenHubBridge? bridge;
  AppHost? _host;
  WebViewController? _web;
  StreamSubscription<Map<String, Object?>>? _events;

  bool get running => current != null;

  /// Listen to the connection's EvenHub events (menu launches, clicks).
  void attach(G2Features f) {
    _events?.cancel();
    _events = f.evenHubEvents.listen(_onEvent);
  }

  void detach() {
    _events?.cancel();
    _events = null;
    unawaited(stop());
  }

  Future<void> _onEvent(Map<String, Object?> event) async {
    try {
      await _handleEvent(event);
    } catch (e) {
      // From the glasses (a stream listener): report, never throw into the stream.
      log?.call('EvenHub: ${event['type']} failed: $e');
    }
  }

  Future<void> _handleEvent(Map<String, Object?> event) async {
    if (event['type'] == 'menu-startup') {
      final wid = (event['widget_id'] as num?)?.toInt() ?? 0;
      final app = registry.get(wid);
      log?.call('EvenHub: menu launch widgetId=$wid → ${app?['package_id'] ?? 'unknown'}');
      final f = features();
      if (app == null) {
        if (f != null) {
          final m = f.s.nextMagic();
          await f.evenHubRequest(ehp.buildMenuStartupFailed(m), m, label: 'menu-startup-failed', timeout: const Duration(seconds: 1));
        }
        return;
      }
      await launch(app['package_id'] as String, widgetId: wid, launchSource: 'glassesMenu');
      return;
    }
    await bridge?.deliverEvent(event);
  }

  Future<void> launch(String pid, {int? widgetId, String launchSource = 'appMenu'}) async {
    final app = registry.get(pid);
    final f = features();
    if (app == null) throw StateError('not installed: $pid');
    if (f == null) throw StateError('glasses not connected');
    await stop();
    final dist = Directory('${registry.appDir(pid).path}/dist');
    final network = (app['permissions'] as List? ?? const []).any((p) => p is Map && p['name'] == 'network');
    final host = AppHost(dist, (app['entrypoint'] ?? 'index.html') as String, appId: app['app_id'] as int, network: network);
    await host.start();
    _host = host;
    final b = EvenHubBridge(app, () => features()!, registry.storageDir,
        widgetId: widgetId ?? (app['app_id'] as int),
        push: _push,
        onExit: (r) => unawaited(stop()),
        log: log,
        batteryLevel: batteryLevel,
        location: location);
    bridge = b;
    current = app;
    notifyListeners();
    final web = WebViewController();
    _web = web;
    await web.setJavaScriptMode(JavaScriptMode.unrestricted);
    await web.addJavaScriptChannel('G2Bridge', onMessageReceived: (m) async {
      Map msg;
      try {
        msg = jsonDecode(m.message) as Map;
      } catch (_) {
        return;
      }
      final id = msg['id'];
      Object? result;
      var ok = true;
      try {
        result = await b.handle((msg['handler'] ?? '').toString(), (msg['args'] as List?) ?? const []);
      } catch (e) {
        ok = false;
        result = '$e';
      }
      if (id is int && id > 0 && identical(_web, web)) {
        await web.runJavaScript('window.__g2Resolve($id, $ok, ${jsonEncode(result)});');
      }
    });
    await web.setNavigationDelegate(NavigationDelegate(onPageFinished: (_) async {
      await _push('evenAppLaunchSource', {'launchSource': launchSource});
      await _push('deviceStatusChanged', b.deviceStatus());
    }));
    await web.loadRequest(Uri.parse(host.url));
    log?.call('EvenHub: launched $pid (widgetId ${b.widgetId})');
  }

  /// Uninstall [pid]; a running copy is stopped first (its files are about to disappear).
  Future<bool> uninstall(String pid) async {
    if (current?['package_id'] == pid) await stop(closePage: true);
    return registry.uninstall(pid);
  }

  Future<void> _push(String method, Object? data) async {
    final msg = jsonEncode({'type': 'listen_even_app_data', 'method': method, 'data': data});
    await _web?.runJavaScript('window._listenEvenAppMessage && window._listenEvenAppMessage($msg);');
  }

  Future<void> stop({bool closePage = false}) async {
    final b = bridge;
    if (current == null) return;
    current = null;
    bridge = null;
    await b?.dispose();
    final f = features();
    if (closePage && b != null && b.pageCreated && f != null) {
      final m = f.s.nextMagic();
      await f.evenHubRequest(ehp.buildShutdown(m), m, label: 'eh-shutdown', timeout: const Duration(seconds: 2));
    }
    f?.releaseEvenHub();
    try {
      await _web?.loadRequest(Uri.parse('about:blank'));
    } catch (_) {}
    _web = null;
    await _host?.stop();
    _host = null;
    notifyListeners();
  }
}
