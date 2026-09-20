/// Session + settings state.
///
/// What persists across app restarts:
///  * the API base URL (a deployment can move; the field on the login screen
///    pre-fills from here),
///  * the session token (30-day cookie semantics — the server is the expiry
///    authority, we simply stop using it the first time it answers 401),
///  * the last signed-in identity, so the app can show *who* it was while the
///    network decides whether that still holds.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/fufut_api.dart';
import '../models/models.dart';

/// The production API. A Pages proxy keeps browser cookies first-party; a
/// native app has no such constraint and talks to the Worker directly.
const String kDefaultBaseUrl = 'https://fufut-api.fufutcoffee.workers.dev';

class AppState extends ChangeNotifier {
  late ApiClient client;
  late FufutApi api;

  String baseUrl = kDefaultBaseUrl;
  StaffUser? user;
  String? roleKey;
  bool mustChangePassword = false;

  /// True while the identity came from the local cache and the server has
  /// not confirmed it (offline boot, flaky Wi-Fi at open).
  bool offlineIdentity = false;

  bool _booted = false;
  bool get booted => _booted;

  bool get isLoggedIn => user != null;

  SharedPreferences? _prefs;

  static const _kBaseUrl = 'fufut.pos.baseUrl';
  static const _kSession = 'fufut.pos.session';
  static const _kIdentity = 'fufut.pos.identity';

  AppState() {
    client = ApiClient(baseUrl: baseUrl);
    api = FufutApi(client);
  }

  Future<void> boot() async {
    if (_booted) return;
    _prefs = await SharedPreferences.getInstance();
    final p = _prefs!;
    final savedUrl = p.getString(_kBaseUrl);
    if (savedUrl != null && savedUrl.isNotEmpty) baseUrl = savedUrl;

    final savedSession = p.getString(_kSession);
    final savedIdentity = p.getString(_kIdentity);

    client.baseUrl = baseUrl;
    client.sessionToken = savedSession;

    if (savedSession != null) {
      if (savedIdentity != null) {
        try {
          final j = jsonDecode(savedIdentity) as Map<String, dynamic>;
          user = StaffUser.fromJson(j);
          roleKey = _normalizeRole(user?.role ?? '');
          offlineIdentity = true; // until /auth/me says otherwise
        } catch (_) {
          // A corrupt cache is a forgotten cache, not a crash.
        }
      }
      // Confirm against the server in the background.
      _revalidateSession();
    }
    _booted = true;
    notifyListeners();
  }

  Future<void> _revalidateSession() async {
    try {
      final fresh = await api.me();
      if (fresh != null) {
        user = fresh;
        roleKey = _normalizeRole(fresh.role);
        offlineIdentity = false;
        _rememberIdentity();
      } else {
        // The server answered and said no — the session is over.
        await _clearSession();
      }
      notifyListeners();
    } on ApiError {
      // Unreachable: keep the cached identity, stay on the current screen.
      // The next real request will surface auth errors if the cookie died.
    }
  }

  Future<void> setBaseUrl(String url) async {
    var clean = url.trim();
    if (clean.endsWith('/')) clean = clean.substring(0, clean.length - 1);
    baseUrl = clean;
    client.baseUrl = clean;
    await _prefs?.setString(_kBaseUrl, clean);
    notifyListeners();
  }

  Future<void> login(String account, String password) async {
    final res = await api.login(account, password);
    user = res;
    roleKey = _normalizeRole(res.role);
    offlineIdentity = false;
    // The login POST's Set-Cookie carries the session; the client captured it.
    // On Flutter web the browser keeps the cookie itself (same-origin proxy
    // flow) and hides Set-Cookie from XHR — so a null token there is normal.
    final token = client.sessionToken;
    if ((token == null || token.isEmpty) && !kIsWeb) {
      // Defensive: without a cookie every subsequent call 401s. Fail loudly
      // rather than half-sign-in.
      user = null;
      throw ApiError('Login succeeded but no session was returned — try again');
    }
    if (token != null && token.isNotEmpty) {
      await _prefs?.setString(_kSession, token);
    }
    _rememberIdentity();
    notifyListeners();
  }

  Future<void> logout() async {
    try {
      await api.logout();
    } catch (_) {
      // The local sign-out must happen regardless.
    }
    await _clearSession();
    notifyListeners();
  }

  Future<void> _clearSession() async {
    user = null;
    roleKey = null;
    offlineIdentity = false;
    client.sessionToken = null;
    await _prefs?.remove(_kSession);
    await _prefs?.remove(_kIdentity);
  }

  void _rememberIdentity() {
    if (user == null) return;
    _prefs?.setString(_kIdentity, jsonEncode({
          'id': user!.id,
          'name': user!.name,
          'first_name': user!.firstName,
          'last_name': user!.lastName,
          'email': user!.email,
          'role': user!.role,
        }));
  }

  /// The server sends role display names ("Head Chef"); the app compares
  /// normalized keys ("head-chef"), same as the web POS does.
  static String _normalizeRole(String role) =>
      role.toLowerCase().trim().replaceAll(RegExp(r'\s+'), '-');

  /// Called on any ApiError with 401/403 from a data request: the session
  /// died server-side. Clears state so the router lands on Login.
  Future<void> sessionExpired() async {
    await _clearSession();
    notifyListeners();
  }
}
