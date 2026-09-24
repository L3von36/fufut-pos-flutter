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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/fufut_api.dart';
import '../models/models.dart';

/// The production API. A Pages proxy keeps browser cookies first-party, so
/// the web build talks to its own origin (relative `/api/...` — the same
/// arrangement the web POS ships with); a native app has no such constraint
/// and talks to the Worker directly.
const String kDefaultBaseUrl = kIsWeb
    ? ''
    : 'https://fufut-api.fufutcoffee.workers.dev';

/// Session + settings state. Mutable by design: the whole app holds one
/// instance and calls its methods (`app.login(...)`, `app.sessionExpired()`)
/// the same way it did under `package:provider`. The Riverpod wiring lives
/// in [AppStateNotifier] below — mutations funnel through [_onChanged] (the
/// old `notifyListeners()`), which the notifier maps to `ref.notifyListeners`
/// so every `ref.watch(appStateProvider)` repaints.
class AppState {
  /// Invoked after every state mutation. Assigned by [AppStateNotifier] on
  /// build; stays null only for bare unit-test instances that nobody
  /// watches.
  void Function()? _onChanged;

  late ApiClient client;
  late FufutApi api;

  String baseUrl = kDefaultBaseUrl;
  StaffUser? user;
  String? roleKey;
  bool mustChangePassword = false;

  /// True while the identity came from the local cache and the server has
  /// not confirmed it (offline boot, flaky Wi-Fi at open).
  bool offlineIdentity = false;

  /// Menu-name → category, the station router's lookup table ("Ginger with
  /// Honey" is a drink only through its HOT DRINKS category). Fetched once
  /// per session on first need; screens that already load the menu (the
  /// boards) adopt their fresh copy here so every screen classifies alike.
  Map<String, String> _catByName = {};
  bool _catsTried = false;
  Map<String, String> get catByName => _catByName;

  Future<void> ensureCategories() async {
    if (_catsTried) return;
    _catsTried = true; // one try per session; failures fall back to name regex
    try {
      adoptCategories(await api.menu());
    } catch (_) {
      // Offline or parse hiccup — the name-regex fallback still routes.
    }
  }

  void adoptCategories(List<MenuItem> menu) {
    _catByName = {for (final m in menu) m.name.toLowerCase(): m.category};
    _catsTried = true;
  }

  bool _booted = false;
  bool get booted => _booted;

  bool get isLoggedIn => user != null;

  // ── The service laws' shared state: is the till open? ────────────────────
  // Ordering (cart → Send) and settlement (checkout, the settle sheet) are
  // refused by the server while the drawer is closed; this cached read lets
  // every screen show the WHY up front without holding a cashdrawer grant
  // (GET /api/venue/status carries till_open for any signed-in role).
  // Null = unknown (probe failed or never ran): screens then allow the
  // action and let the server's law speak if it must — fail-open, the same
  // direction the server probe takes on its own errors.
  bool? _tillOpen;
  bool? get tillOpen => _tillOpen;

  /// Re-read the till state from the server and repaint every listener.
  /// Called on shell focus, after drawer open/close, and before gates render.
  Future<void> refreshTill() async {
    try {
      final v = await api.venueStatus();
      _tillOpen = v.tillOpen;
    } catch (_) {
      // Unreachable or refused: keep the last known value.
    }
    _notifyListeners();
  }

  SharedPreferences? _prefs;

  static const _kBaseUrl = 'fufut.pos.baseUrl';
  static const _kSession = 'fufut.pos.session';
  static const _kIdentity = 'fufut.pos.identity';

  AppState({void Function()? onChanged}) : _onChanged = onChanged {
    client = ApiClient(baseUrl: baseUrl);
    api = FufutApi(client);
  }

  void _notifyListeners() => _onChanged?.call();

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
    _notifyListeners();
    // The till gate needs a fresh answer for the shell's screens.
    if (savedSession != null) refreshTill();
  }

  Future<void> _revalidateSession() async {
    try {
      final fresh = await api.me();
      if (fresh != null) {
        user = fresh.user;
        roleKey = _normalizeRole(fresh.user.role);
        mustChangePassword = fresh.mustChangePassword;
        offlineIdentity = false;
        _rememberIdentity();
      } else {
        // The server answered and said no — the session is over.
        await _clearSession();
      }
      _notifyListeners();
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
    _notifyListeners();
  }

  Future<void> login(String account, String password) async {
    final res = await api.login(account, password);
    user = res.user;
    roleKey = _normalizeRole(res.user.role);
    mustChangePassword = res.mustChangePassword;
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
    refreshTill(); // the shell's gates read this
    _notifyListeners();
  }

  Future<void> logout() async {
    try {
      await api.logout();
    } catch (_) {
      // The local sign-out must happen regardless.
    }
    await _clearSession();
    _notifyListeners();
  }

  Future<void> _clearSession() async {
    user = null;
    roleKey = null;
    mustChangePassword = false;
    offlineIdentity = false;
    _tillOpen = null;
    client.sessionToken = null;
    await _prefs?.remove(_kSession);
    await _prefs?.remove(_kIdentity);
  }

  /// Replace a manager-issued password. The server flips the flag off with
  /// the same call; mirror it locally so the router releases the account into
  /// the shell — the web clears mustChangePassword on the identical success
  /// path (auth.js changePassword).
  Future<void> changePassword(String current, String next) async {
    await api.changePassword(current, next);
    mustChangePassword = false;
    _notifyListeners();
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
    _notifyListeners();
  }
}

/// Riverpod wiring for [AppState]. The notifier keeps one [AppState] alive
/// for the app's lifetime — `ref.keepAlive()` pins it under Riverpod 3's
/// autoDispose default — and lends it `ref.notifyListeners` as the
/// mutation bell.
///
/// Tests that script a fake API build their own [AppState] first (client,
/// identity, role) and hand it over as a seed:
/// `appStateProvider.overrideWith(() => AppStateNotifier(seed: app))`.
class AppStateNotifier extends Notifier<AppState> {
  AppStateNotifier({AppState? seed}) : _seed = seed;
  final AppState? _seed;

  @override
  AppState build() {
    ref.keepAlive();
    final s = _seed ?? AppState();
    s._onChanged = ref.notifyListeners;
    return s;
  }
}

final appStateProvider =
    NotifierProvider<AppStateNotifier, AppState>(AppStateNotifier.new);
