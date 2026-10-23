/// HTTP plumbing shared by the providers: JSON POST/GET with timeouts, retries on transient
/// failures (429 / 5xx / 529 / network, honouring retry-after), and readable errors that
/// never echo request headers (keys stay out of logs and messages).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, HandshakeException;
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'llm.dart';

typedef Sleep = Future<void> Function(Duration);

class HttpJson {
  HttpJson(this.client, {this.provider = 'API', this.maxRetries = 2, Sleep? sleep, this.timeout = const Duration(seconds: 60)})
      : _sleep = sleep ?? ((d) => Future<void>.delayed(d));

  final http.Client client;
  final String provider;
  final int maxRetries;
  final Duration timeout;
  final Sleep _sleep;

  Future<Map<String, Object?>> postJson(Uri url, Map<String, String> headers, Object body) =>
      _send(() => client.post(url, headers: {'content-type': 'application/json', ...headers}, body: jsonEncode(body)));

  Future<Map<String, Object?>> getJson(Uri url, Map<String, String> headers) => _send(() => client.get(url, headers: headers));

  Future<Map<String, Object?>> send(Future<http.Response> Function() request) => _send(request);

  Future<Map<String, Object?>> _send(Future<http.Response> Function() request) async {
    for (var attempt = 0;; attempt++) {
      http.Response r;
      try {
        r = await request().timeout(timeout);
      } on TimeoutException {
        if (attempt < maxRetries) {
          await _sleep(_backoff(attempt, null));
          continue;
        }
        throw AiError('$provider: request timed out', retryable: true);
      } on SocketException catch (e) {
        if (attempt < maxRetries) {
          await _sleep(_backoff(attempt, null));
          continue;
        }
        throw AiError('$provider: network error (${e.osError?.message ?? e.message})', retryable: true);
      } on HandshakeException {
        throw AiError('$provider: TLS handshake failed (check the URL / certificate)');
      } on http.ClientException catch (e) {
        if (attempt < maxRetries) {
          await _sleep(_backoff(attempt, null));
          continue;
        }
        throw AiError('$provider: network error (${e.message})', retryable: true);
      } on AiError {
        rethrow;
      } catch (e) {
        // e.g. a FormatException for a header value the HTTP stack rejects: its message
        // contains the header (the API key), so it is never echoed.
        throw AiError('$provider: the request could not be sent (${e.runtimeType}); check the URL and the API key');
      }
      final transient = r.statusCode == 429 || r.statusCode == 408 || r.statusCode == 409 || r.statusCode >= 500;
      if (transient && attempt < maxRetries) {
        await _sleep(_backoff(attempt, r.headers['retry-after']));
        continue;
      }
      Object? decoded;
      try {
        decoded = r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
      } catch (_) {
        decoded = null;
      }
      if (r.statusCode < 200 || r.statusCode >= 300) {
        throw AiError(describeError(provider, r.statusCode, decoded, r.body), status: r.statusCode, retryable: transient);
      }
      if (decoded is Map) return decoded.cast<String, Object?>();
      if (decoded is List) return {'data': decoded};
      throw AiError('$provider: unexpected reply (not JSON)');
    }
  }

  Duration _backoff(int attempt, String? retryAfter) {
    final ra = double.tryParse(retryAfter ?? '');
    if (ra != null && ra >= 0 && ra <= 30) return Duration(milliseconds: (ra * 1000).round());
    return Duration(milliseconds: (500 * math.pow(2, attempt)).round().clamp(500, 8000));
  }
}

/// "Claude: invalid API key (401)" style messages from any provider's error JSON.
String describeError(String provider, int status, Object? body, String rawBody) {
  String? msg;
  if (body is Map) {
    final e = body['error'];
    if (e is Map) msg = (e['message'] ?? e['type'])?.toString();
    if (e is String) msg = e;
    msg ??= (body['message'] ?? body['err_msg'] ?? body['detail'])?.toString();
  } else if (body is List && body.isNotEmpty && body.first is Map) {
    final e = (body.first as Map)['error'];
    if (e is Map) msg = e['message']?.toString();
  }
  msg ??= rawBody.length > 160 ? '${rawBody.substring(0, 160)}…' : rawBody;
  final what = switch (status) {
    401 || 403 => 'invalid or unauthorised API key',
    404 => 'not found (check the base URL and model name)',
    429 => 'rate limited, try again shortly',
    529 => 'overloaded, try again shortly',
    >= 500 => 'server error',
    _ => 'request rejected',
  };
  return '$provider: $what ($status)${msg.trim().isEmpty ? '' : ': ${msg.trim()}'}';
}

/// Parse a provider reply; anything that is not the documented shape becomes a readable
/// [AiError] (so fallbacks take over) instead of a TypeError.
T parseOrFail<T>(String provider, T Function() parse) {
  try {
    return parse();
  } on AiError {
    rethrow;
  } catch (_) {
    throw AiError('$provider: unexpected reply (not the documented format)');
  }
}

/// Null if [url] is a usable http(s) endpoint, else what is wrong with it.
String? badEndpoint(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null || !(u.isScheme('https') || u.isScheme('http')) || u.host.isEmpty) {
    return 'the endpoint URL must start with https:// (or http:// for a server on your network)';
  }
  return null;
}

/// Join a base URL and a path without doubling slashes.
Uri joinUrl(String base, String path, [Map<String, String>? query]) {
  var b = base.trim();
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  final p = path.startsWith('/') ? path : '/$path';
  final u = Uri.parse('$b$p');
  return query == null || query.isEmpty ? u : u.replace(queryParameters: {...u.queryParameters, ...query});
}
