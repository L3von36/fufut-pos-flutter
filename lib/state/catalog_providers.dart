/// Catalog providers — the menu as a shared, watched resource.
///
/// Five screens used to each fetch the menu on their own (register, both
/// boards, analytics, menu management) and the boards additionally wrote
/// their copy into `AppState.adoptCategories` so the Orders screen's station
/// router could classify by category. One provider replaces all of it: the
/// first consumer triggers the fetch, every consumer shares the result, and
/// the session cache adoption happens exactly once, where the data lands.
///
/// Menu management invalidates this after a save; autoDispose re-fetches on
/// the next watch. A failed fetch is a real [AsyncError] — consumers decide
/// what degradation means for them (the boards fall back to the name-regex
/// classifier, `.value ?? const []`).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import 'app_state.dart';
import 'session_providers.dart';

/// The venue menu. KeepAlive is NOT set: the menu changes rarely, but
/// menu-management edits it — an autoDispose provider refetched on next
/// watch is the honest cache.
///
/// The session is READ, never watched: the fetch adopts its result into
/// AppState's category cache, which pings AppState's notify bell — watching
/// the session here would rebuild the provider on its own echo.
final menuProvider = FutureProvider<List<MenuItem>>((ref) async {
  final api = ref.read(fufutApiProvider);
  final app = ref.read(appStateProvider);
  try {
    final menu = await api.menu();
    // The station router's session cache (AppState.catByName) adopts the
    // fresh copy so EVERY screen classifies alike, not just the watchers.
    app.adoptCategories(menu);
    return menu;
  } on ApiError catch (e) {
    if (e.isAuthError) await app.sessionExpired();
    rethrow;
  }
});

/// The register screen's density toggle (grid ⇄ list), persisted per device
/// like the web's localStorage flag. true = list.
class MenuDensityNotifier extends Notifier<bool> {
  static const _key = 'fufut.pos.menuDensity';

  @override
  bool build() {
    _restore();
    return false;
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      state = prefs.getString(_key) == 'list';
    } catch (_) {
      // Unreadable prefs: stay in grid (the default).
    }
  }

  void toggle() {
    final next = !state;
    state = next;
    SharedPreferences.getInstance()
        .then((p) => p.setString(_key, next ? 'list' : 'grid'));
  }
}

final menuDensityProvider =
    NotifierProvider<MenuDensityNotifier, bool>(MenuDensityNotifier.new);

/// Tables for PICKERS — one shared fetch for every sheet that needs a table
/// dropdown (the cart's table picker, the review sheet, reservations).
/// Read, not watched: a picker refetches on invalidate() or remount, never
/// on the session object's every notify. A refused fetch (a role without
/// the tables grant) is a real error — the pickers degrade to free text.
final tablesOnceProvider = FutureProvider<List<CafeTable>>((ref) async {
  final api = ref.read(fufutApiProvider);
  return api.tables();
});

/// name → category, lowercased — the station router's lookup table
/// ("Ginger with Honey" is a drink only through its HOT DRINKS category).
/// Empty until the menu lands; consumers fall back to the name regex.
final catByNameProvider = Provider<Map<String, String>>((ref) {
  final menu = ref.watch(menuProvider).value;
  if (menu == null) {
    // Fall back to whatever the session cache already adopted (a board
    // that loaded before this provider existed) — else empty.
    return ref.watch(appStateProvider).catByName;
  }
  return {for (final m in menu) m.name.toLowerCase(): m.category};
});
