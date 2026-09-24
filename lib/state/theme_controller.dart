import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Light by default — the web POS's default. The topbar's sun/moon button
/// flips this and the choice persists (the web stores it on the document
/// element; we store it in prefs).
///
/// Fully idiomatic Riverpod: the [ThemeMode] itself is the state, so there
/// is no controller object to expose — `ref.watch(themeModeProvider)` and
/// `ref.read(themeModeProvider.notifier).toggle()` are the whole API.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    _restore();
    return ThemeMode.light;
  }

  /// Picks up the persisted choice. Runs once when the provider is first
  /// read (MaterialApp's build) — a beat after boot, like the old
  /// `ThemeController()..load()` fire-and-forget.
  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = (prefs.getString('fufut.pos.theme') == 'dark')
          ? ThemeMode.dark
          : ThemeMode.light;
    } catch (_) {
      // Unreadable prefs: stay light.
    }
  }

  void toggle() {
    final next = state == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    state = next;
    SharedPreferences.getInstance().then((p) =>
        p.setString('fufut.pos.theme', next == ThemeMode.dark ? 'dark' : 'light'));
  }
}

final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);
