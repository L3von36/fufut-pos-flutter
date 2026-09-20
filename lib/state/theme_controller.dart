import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Light by default — the web POS's default. The topbar's sun/moon button
/// flips this and the choice persists (the web stores it on the document
/// element; we store it in prefs).
class ThemeController extends ChangeNotifier {
  ThemeMode _mode = ThemeMode.light;
  ThemeMode get mode => _mode;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = (prefs.getString('fufut.pos.theme') == 'dark')
        ? ThemeMode.dark
        : ThemeMode.light;
    notifyListeners();
  }

  void toggle() {
    _mode = _mode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    SharedPreferences.getInstance().then((p) =>
        p.setString('fufut.pos.theme', _mode == ThemeMode.dark ? 'dark' : 'light'));
    notifyListeners();
  }
}
