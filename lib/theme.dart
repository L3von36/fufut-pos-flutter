/// Fufut brand theme.
///
/// Seed `#0F7B78` is the POS's own theme-color from the web app, so the
/// native app reads as the same till on a different screen.
library;

import 'package:flutter/material.dart';

const Color kBrandTeal = Color(0xFF0F7B78);
const Color kBrandDark = Color(0xFF101816);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kBrandTeal,
    brightness: Brightness.dark,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kBrandDark,
    appBarTheme: const AppBarTheme(
      backgroundColor: kBrandDark,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: const Color(0xFF1A2624),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF1A2624),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: kBrandTeal, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kBrandTeal,
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 48),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        side: const BorderSide(color: Color(0xFF3A4A47)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: const Color(0xFF1A2624),
      selectedColor: kBrandTeal,
      labelStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// ETB money formatting without pulling intl everywhere: Ethiopian birr is
/// displayed with two decimals, thousands separated.
String money(num v) {
  final s = v.toStringAsFixed(2);
  final parts = s.split('.');
  final intPart = parts[0];
  final buf = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    final remaining = intPart.length - i;
    buf.write(intPart[i]);
    if (remaining > 1 && remaining % 3 == 1) buf.write(',');
  }
  return 'ETB ${buf.toString()}.${parts[1]}';
}
