/// Small HTTP layer for the public data the phone fetches (Open-Meteo, RSS, Jina Reader, ICS,
/// Yahoo chart, Nominatim, OSRM). Injectable so tests never touch the network.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class NetError implements Exception {
  NetError(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class Net {
  /// GET → body text; throws [NetError] (non-200, too large, timeout, offline).
  Future<String> getText(Uri url, {Map<String, String>? headers, Duration timeout = const Duration(seconds: 15), int maxBytes = 5000000});

  Future<Object?> getJson(Uri url, {Map<String, String>? headers, Duration timeout = const Duration(seconds: 15)}) async =>
      jsonDecode(await getText(url, headers: headers, timeout: timeout));
}

class HttpNet extends Net {
  HttpNet([http.Client? client]) : _c = client ?? http.Client();
  final http.Client _c;

  @override
  Future<String> getText(Uri url, {Map<String, String>? headers, Duration timeout = const Duration(seconds: 15), int maxBytes = 5000000}) async {
    try {
      final req = http.Request('GET', url)..headers.addAll({'User-Agent': 'G2Hub-mobile/1.0', ...?headers});
      final resp = await _c.send(req).timeout(timeout);
      if (resp.statusCode != 200) {
        await resp.stream.drain<void>();
        throw NetError('server answered HTTP ${resp.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in resp.stream.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) throw NetError('response too large');
      }
      return utf8.decode(bytes, allowMalformed: true);
    } on NetError {
      rethrow;
    } on TimeoutException {
      throw NetError('timed out');
    } catch (e) {
      throw NetError('network error (${e.runtimeType})');
    }
  }
}
