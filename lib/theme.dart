/// FU FUT POS theme — a 1:1 port of the web POS design tokens
/// (`fufut-management/pos/src/assets/styles.css`).
///
/// Every color, radius and shadow here is copied from the PWA's `:root`
/// (light) and `[data-theme="dark"]` blocks, so the native app reads as the
/// same till on a different screen. The PWA renders at an 80% base zoom
/// (`html { font-size: 12.8px }`) — sizes in this file are the resulting
/// effective pixels, which is exactly what floor staff see in the browser.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Palette
// ─────────────────────────────────────────────────────────────────────────────

/// One palette instance (light or dark). Reached from widgets through
/// [Pal.of], which reads it out of the ambient [ThemeData] extension.
@immutable
class Pal extends ThemeExtension<Pal> {
  const Pal({
    required this.bg,
    required this.surface,
    required this.sunken,
    required this.border,
    required this.borderStrong,
    required this.heading,
    required this.body,
    required this.muted,
    required this.faint,
    required this.primary,
    required this.primaryHover,
    required this.tintBg,
    required this.tintBorder,
    required this.gold,
    required this.goldDark,
    required this.goldLight,
    required this.sidebarTop,
    required this.sidebarBottom,
    required this.success,
    required this.successBg,
    required this.successBorder,
    required this.warning,
    required this.warningBg,
    required this.warningBorder,
    required this.danger,
    required this.dangerBg,
    required this.dangerBorder,
    required this.info,
    required this.infoBg,
    required this.infoBorder,
    required this.overlay,
  });

  final Color bg; // page background      (--bg)
  final Color surface; // cards / sheets    (--surface)
  final Color sunken; // wells, cart lines  (--neutral-50)
  final Color border; // hairlines          (--border)
  final Color borderStrong; //               (--border-strong)
  final Color heading; //                    (--text-heading)
  final Color body; //                       (--text-body)
  final Color muted; //                      (--text-muted)
  final Color faint; // placeholders          (--neutral-400)
  final Color primary; // #0F7B78            (--primary)
  final Color primaryHover; // #0C5F5B       (--primary-hover)
  final Color tintBg; // teal-50             (--primary-light)
  final Color tintBorder; // teal-200        (--border-brand)
  final Color gold; // #D6B36A              (--accent)
  final Color goldDark; // #AD8A47          (--accent-dark)
  final Color goldLight; // #E4CB99         (--accent-light)
  final Color sidebarTop; // #0A4A47        (--teal-800)
  final Color sidebarBottom; // #073735     (--teal-900)
  final Color success; // #2E7D32           (--success)
  final Color successBg; // #F0FDF4
  final Color successBorder; // #BBF7D0
  final Color warning; // #B5651D           (--warning)
  final Color warningBg; // #FFFBEB
  final Color warningBorder; // #FDE68A
  final Color danger; // #D32F2F            (--danger)
  final Color dangerBg; // #FEF2F2
  final Color dangerBorder; // #FECACA
  final Color info; // #2563EB              (--info)
  final Color infoBg; // #EFF6FF
  final Color infoBorder; // #BFDBFE
  final Color overlay; // modal scrim

  static const light = Pal(
    bg: Color(0xFFFAFAF8),
    surface: Color(0xFFFFFFFF),
    sunken: Color(0xFFF4F3F0),
    border: Color(0xFFE9E7E1),
    borderStrong: Color(0xFFD1CEC5),
    heading: Color(0xFF221F1A),
    body: Color(0xFF524F47),
    muted: Color(0xFF5E5A50),
    faint: Color(0xFF9A9589),
    primary: Color(0xFF0F7B78),
    primaryHover: Color(0xFF0C5F5B),
    tintBg: Color(0xFFEDF8F8),
    tintBorder: Color(0xFFA8DFE0),
    gold: Color(0xFFD6B36A),
    goldDark: Color(0xFFAD8A47),
    goldLight: Color(0xFFE4CB99),
    sidebarTop: Color(0xFF0A4A47),
    sidebarBottom: Color(0xFF073735),
    success: Color(0xFF2E7D32),
    successBg: Color(0xFFF0FDF4),
    successBorder: Color(0xFFBBF7D0),
    warning: Color(0xFFB5651D),
    warningBg: Color(0xFFFFFBEB),
    warningBorder: Color(0xFFFDE68A),
    danger: Color(0xFFD32F2F),
    dangerBg: Color(0xFFFEF2F2),
    dangerBorder: Color(0xFFFECACA),
    info: Color(0xFF2563EB),
    infoBg: Color(0xFFEFF6FF),
    infoBorder: Color(0xFFBFDBFE),
    overlay: Color(0x8C1C1917), // rgba(28,25,23,.55)
  );

  // Effective dark values: the later `[data-theme=dark]` block in the PWA
  // stylesheet wins wherever the two dark declarations overlap.
  static const dark = Pal(
    bg: Color(0xFF1A1A1A),
    surface: Color(0xFF262626),
    sunken: Color(0xFF2A2A2A),
    border: Color(0xFF404040),
    borderStrong: Color(0xFF4A4A4A),
    heading: Color(0xFFEEEEEE),
    body: Color(0xFFCCCCCC),
    muted: Color(0xFF9A9A9A),
    faint: Color(0xFF888888),
    primary: Color(0xFF0F7B78),
    primaryHover: Color(0xFF0C5F5B),
    tintBg: Color(0xFF0A2E2C),
    tintBorder: Color(0xFF0F504C),
    gold: Color(0xFFD6B36A),
    goldDark: Color(0xFFAD8A47),
    goldLight: Color(0xFFE4CB99),
    sidebarTop: Color(0xFF0A4A47),
    sidebarBottom: Color(0xFF073735),
    success: Color(0xFF4CAF50),
    successBg: Color(0x2622C55E), // rgba(34,197,94,.15)
    successBorder: Color(0x3322C55E),
    warning: Color(0xFFE09A4A),
    warningBg: Color(0x26F59E0B), // rgba(245,158,11,.15)
    warningBorder: Color(0x33F59E0B),
    danger: Color(0xFFF26C6C),
    dangerBg: Color(0x26EF4444), // rgba(239,68,68,.15)
    dangerBorder: Color(0x33EF4444),
    info: Color(0xFF6B9BFF),
    infoBg: Color(0x263B82F6), // rgba(59,130,246,.15)
    infoBorder: Color(0x333B82F6),
    overlay: Color(0x8C1C1917),
  );

  static Pal of(BuildContext context) =>
      Theme.of(context).extension<Pal>() ?? Pal.light;

  @override
  Pal lerp(Pal? other, double t) => other == null
      ? this
      : Pal(
          bg: Color.lerp(bg, other.bg, t)!,
          surface: Color.lerp(surface, other.surface, t)!,
          sunken: Color.lerp(sunken, other.sunken, t)!,
          border: Color.lerp(border, other.border, t)!,
          borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
          heading: Color.lerp(heading, other.heading, t)!,
          body: Color.lerp(body, other.body, t)!,
          muted: Color.lerp(muted, other.muted, t)!,
          faint: Color.lerp(faint, other.faint, t)!,
          primary: Color.lerp(primary, other.primary, t)!,
          primaryHover: Color.lerp(primaryHover, other.primaryHover, t)!,
          tintBg: Color.lerp(tintBg, other.tintBg, t)!,
          tintBorder: Color.lerp(tintBorder, other.tintBorder, t)!,
          gold: Color.lerp(gold, other.gold, t)!,
          goldDark: Color.lerp(goldDark, other.goldDark, t)!,
          goldLight: Color.lerp(goldLight, other.goldLight, t)!,
          sidebarTop: Color.lerp(sidebarTop, other.sidebarTop, t)!,
          sidebarBottom: Color.lerp(sidebarBottom, other.sidebarBottom, t)!,
          success: Color.lerp(success, other.success, t)!,
          successBg: Color.lerp(successBg, other.successBg, t)!,
          successBorder: Color.lerp(successBorder, other.successBorder, t)!,
          warning: Color.lerp(warning, other.warning, t)!,
          warningBg: Color.lerp(warningBg, other.warningBg, t)!,
          warningBorder: Color.lerp(warningBorder, other.warningBorder, t)!,
          danger: Color.lerp(danger, other.danger, t)!,
          dangerBg: Color.lerp(dangerBg, other.dangerBg, t)!,
          dangerBorder: Color.lerp(dangerBorder, other.dangerBorder, t)!,
          info: Color.lerp(info, other.info, t)!,
          infoBg: Color.lerp(infoBg, other.infoBg, t)!,
          infoBorder: Color.lerp(infoBorder, other.infoBorder, t)!,
          overlay: Color.lerp(overlay, other.overlay, t)!,
        );

  @override
  Pal copyWith({Brightness? brightness}) => this; // fields are final; lerp covers swaps
}

// ─────────────────────────────────────────────────────────────────────────────
// Typography
// ─────────────────────────────────────────────────────────────────────────────

const String kFontBody = 'Inter';
const String kFontMono = 'FiraCode';

/// Text styles used across the app.
///
/// Compact enterprise density (Linear/Stripe style): body 13, small 11-12,
/// titles tight and proportional. Use these instead of hand-rolled
/// TextStyles so a future size tweak stays one edit.
abstract final class T {
  static const navItem = TextStyle(
      fontFamily: kFontBody, fontSize: 12.5, fontWeight: FontWeight.w500);
  static const navHeader = TextStyle(
      fontFamily: kFontBody,
      fontSize: 10.0,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.4); // section eyebrows
  static const screenTitle = TextStyle(
      fontFamily: kFontBody, fontSize: 16.5, fontWeight: FontWeight.w700);
  static const cardName = TextStyle(
      fontFamily: kFontBody, fontSize: 13.0, fontWeight: FontWeight.w600);
  static const price = TextStyle(
      fontFamily: kFontMono, fontSize: 13.0, fontWeight: FontWeight.w700);
  static const priceBig = TextStyle(
      fontFamily: kFontMono, fontSize: 19.0, fontWeight: FontWeight.w700);
  static const mono = TextStyle(fontFamily: kFontMono);
  static const desc = TextStyle(fontFamily: kFontBody, fontSize: 11.5);
  static const chip = TextStyle(
      fontFamily: kFontBody, fontSize: 11.5, fontWeight: FontWeight.w500);
  static const badge = TextStyle(
      fontFamily: kFontBody,
      fontSize: 10.0,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4);
}

// ─────────────────────────────────────────────────────────────────────────────
// System chrome — edge-to-edge, Android-style
// ─────────────────────────────────────────────────────────────────────────────

/// Call once from `main()`. Draws the app behind the status and navigation
/// bars (transparent, theme-tinted icons) so the teal sidebar and gradient
/// header reach the screen edges like a native Android app.
Future<void> initSystemChrome() async {
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
}

/// Transparent status + nav bars whose icon brightness suits [brightness].
/// Applied per-screen through `AnnotatedRegion` so theme switches restyle
/// the bars instantly.
SystemUiOverlayStyle systemOverlay(Brightness brightness) {
  final darkIcons = brightness == Brightness.light;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: darkIcons ? Brightness.dark : Brightness.light,
    statusBarBrightness: darkIcons ? Brightness.light : Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness:
        darkIcons ? Brightness.dark : Brightness.light,
    systemNavigationBarContrastEnforced: false,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Money
// ─────────────────────────────────────────────────────────────────────────────

/// The PWA's money format: `'ETB ' + n.toFixed(0)` — whole birr, no
/// thousands separator (e.g. `ETB 840`).
String money(num v) => 'ETB ${v.toStringAsFixed(0)}';

/// Quick-tender labels use `toLocaleString()` on the web → grouped digits
/// (e.g. `ETB 1,000`).
String moneyGroup(num v) {
  final s = v.toStringAsFixed(0);
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final remaining = s.length - i;
    buf.write(s[i]);
    if (remaining > 1 && remaining % 3 == 1) buf.write(',');
  }
  return 'ETB $buf';
}

// ─────────────────────────────────────────────────────────────────────────────
// ThemeData
// ─────────────────────────────────────────────────────────────────────────────

ThemeData buildLightTheme() => _theme(Pal.light, Brightness.light);
ThemeData buildDarkTheme() => _theme(Pal.dark, Brightness.dark);

ThemeData _theme(Pal p, Brightness brightness) {
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.primary,
    onPrimary: Colors.white,
    secondary: const Color(0xFF18B4B7),
    onSecondary: Colors.white,
    error: p.danger,
    onError: Colors.white,
    surface: p.surface,
    onSurface: p.body,
    surfaceContainerHighest: p.sunken,
    outline: p.borderStrong,
    outlineVariant: p.border,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    extensions: [p],
    textTheme: const TextTheme().apply(
      fontFamily: kFontBody,
      bodyColor: p.body,
      displayColor: p.heading,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.surface,
      foregroundColor: p.heading,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
          fontFamily: kFontBody,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: p.heading),
    ),
    dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: p.border, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.bg,
      hintStyle: TextStyle(color: p.faint, fontSize: 13),
      labelStyle: TextStyle(color: p.muted, fontSize: 12.5),
      floatingLabelStyle: TextStyle(color: p.primary, fontSize: 11.5),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: p.border, width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: p.border, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: p.primary, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.primary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: p.primary.withValues(alpha: 0.5),
        minimumSize: const Size(56, 38),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        textStyle: const TextStyle(
            fontFamily: kFontBody, fontSize: 12.5, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.body,
        minimumSize: const Size(56, 38),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        side: BorderSide(color: p.borderStrong, width: 1),
        textStyle: const TextStyle(
            fontFamily: kFontBody, fontSize: 12.5, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.primary,
        textStyle: const TextStyle(
            fontFamily: kFontBody,
            fontSize: 12.5,
            fontWeight: FontWeight.w600),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.heading,
      contentTextStyle: TextStyle(
          fontFamily: kFontBody, fontSize: 12.5, color: p.bg),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.primary),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedForegroundColor: Colors.white,
        selectedBackgroundColor: p.primary,
        foregroundColor: p.body,
        backgroundColor: p.sunken,
        side: BorderSide(color: p.border),
        textStyle: const TextStyle(
            fontFamily: kFontBody, fontSize: 12, fontWeight: FontWeight.w600),
        minimumSize: const Size(56, 34),
        visualDensity: VisualDensity.compact,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      modalBackgroundColor: p.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      showDragHandle: false,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      titleTextStyle: TextStyle(
          fontFamily: kFontBody, fontSize: 16, fontWeight: FontWeight.w700, color: p.heading),
      contentTextStyle: TextStyle(fontFamily: kFontBody, fontSize: 13, color: p.body),
    ),
  );
}
