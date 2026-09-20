/// HTTP client for the fufut-api Worker.
///
/// Mirrors the web POS `api/index.js` contract:
///  * a `session` cookie carried on every call (HttpOnly in a browser, but a
///    native app simply captures the Set-Cookie and resends it — that is all
///    HttpOnly ever meant);
///  * a browser-shaped User-Agent, because Cloudflare Bot Fight Mode sits in
///    front of the API and answers non-browser clients with error 1010
///    before the request ever reaches the Worker;
///  * two retries with backoff on 502/503/504/429 and on network hiccups,
///    never on 4xx refusals — a "no" from the server is an answer, and
///    replaying it just wastes the caller's time;
///  * error bodies parsed for the `error` field so screens can say something
///    actionable ("Table 7 is occupied") instead of "HTTP 409".
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiError implements Exception {
  final int? status;
  final String message;

  ApiError(this.message, [this.status]);

  bool get isAuthError => status == 401 || status == 403;

  @override
  String toString() => message;
}

/// Returned when the device never reached the server at all.
class NetworkError extends ApiError {
  NetworkError(super.message);
}

class ApiClient {
  /// Base URL, e.g. `https://fufut-api.fufutcoffee.workers.dev`. No trailing
  /// slash — callers append `/api/...`. Mutable: Settings lets a tablet
  /// re-point mid-shift.
  String baseUrl;

  /// The `session` token from login. Null until signed in.
  String? sessionToken;

  /// Allow tests / screens to observe raw traffic if they want.
  void Function(String method, String path, int status)? onRequest;

  ApiClient({required this.baseUrl, this.sessionToken});

  static const _timeout = Duration(seconds: 12);
  static const _maxRetries = 2;
  static const _retryable = {502, 503, 504, 429};

  /// Bot Fight Mode (Cloudflare, error 1010) only waves through
  /// browser-looking clients. The web POS inherits this for free because it
  /// runs in a browser; the native app has to ask for it explicitly.
  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/126.0.0.0 Mobile Safari/537.36';

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'User-Agent': _userAgent,
        'Accept': 'application/json',
        if (sessionToken != null) 'Cookie': 'session=$sessionToken',
      };

  Uri _uri(String endpoint) =>
      Uri.parse('$baseUrl/api/${endpoint.replaceAll(RegExp(r'^/'), '')}');

  // ── Verbs ─────────────────────────────────────────────────────────────────

  Future<dynamic> get(String endpoint) async {
    final r = await _send(() => http.get(_uri(endpoint), headers: _headers),
        'GET', endpoint);
    return r;
  }

  Future<dynamic> post(String endpoint, Map<String, dynamic> body) async {
    final r = await _send(
        () => http.post(_uri(endpoint),
            headers: _headers, body: jsonEncode(body)),
        'POST',
        endpoint);
    return r;
  }

  Future<dynamic> put(String endpoint, Map<String, dynamic> body) async {
    final r = await _send(
        () => http.put(_uri(endpoint),
            headers: _headers, body: jsonEncode(body)),
        'PUT',
        endpoint);
    return r;
  }

  Future<dynamic> patch(String endpoint, Map<String, dynamic> body) async {
    final r = await _send(
        () => http.patch(_uri(endpoint),
            headers: _headers, body: jsonEncode(body)),
        'PATCH',
        endpoint);
    return r;
  }

  // ── Core send loop with retries ───────────────────────────────────────────

  Future<dynamic> _send(
      Future<http.Response> Function() doRequest, String method,
      String endpoint,
      [int retriesLeft = _maxRetries]) async {
    http.Response r;
    try {
      r = await doRequest().timeout(_timeout);
    } on TimeoutException {
      throw NetworkError('$method $endpoint timed out');
    } catch (e) {
      // Network layer refused. Only reads retry automatically — the web POS
      // queues writes offline instead of replaying them, because a retried
      // POST (order creation) would fire a second ticket the kitchen cooks
      // for real. Writes fail fast here and the caller decides what to do.
      final isRead = method == 'GET' && !endpoint.startsWith('auth/');
      if (isRead && retriesLeft > 0) {
        await Future<void>.delayed(
            Duration(milliseconds: 500 * (_maxRetries - retriesLeft + 1)));
        return _send(doRequest, method, endpoint, retriesLeft - 1);
      }
      throw NetworkError('Cannot reach the server (${e.toString().split('\n').first})');
    }

    onRequest?.call(method, endpoint, r.statusCode);

    // Non-final: a JSON parse failure assigns null in the catch, and Dart
    // forbids a second assignment to a final local across try/catch.
    dynamic body;
    try {
      body = jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      body = null;
    }

    if (r.statusCode < 200 || r.statusCode >= 300) {
      final msg = (body is Map && body['error'] is String)
          ? body['error'] as String
          : '$method $endpoint failed (${r.statusCode})';
      final err = ApiError(msg, r.statusCode);
      // Transient server errors retry with backoff, exactly like the web POS.
      if (_retryable.contains(r.statusCode) && retriesLeft > 0) {
        await Future<void>.delayed(
            Duration(milliseconds: 500 * (_maxRetries - retriesLeft + 1)));
        return _send(doRequest, method, endpoint, retriesLeft - 1);
      }
      throw err;
    }

    // Capture the session token from any Set-Cookie the server hands us.
    final setCookie = r.headers['set-cookie'];
    if (setCookie != null) {
      final m = RegExp(r'session=([^;]+)').firstMatch(setCookie);
      if (m != null) sessionToken = m.group(1);
    }

    return body;
  }

  /// Extract the session token after login from the login response's
  /// `Set-Cookie` — some http stacks collapse headers; when the cookie never
  /// arrives we fall back to this being set by [_send] directly.
  void adoptSession(String token) => sessionToken = token;
}
