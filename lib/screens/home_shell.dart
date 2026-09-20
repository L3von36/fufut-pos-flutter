import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/theme_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'orders_screen.dart';
import 'register_screen.dart';
import 'settings_screen.dart';

/// Which screen the shell shows. The PWA's cashier chrome in miniature:
/// Menu View, Orders, Open Checks + a drawer holding Settings & sign-out.
enum ShellTab { menuView, orders, openChecks, settings }

/// App chrome — the web POS `AppLayout.vue`, re-thought as a native app:
///  * Phone — an Android `Drawer` (edge swipe, scrim, teal gradient, user
///    header) behind a 64px app bar, with a Material-3 bottom navigation bar
///    (Menu View · Orders · Open Checks · More) for the three hot screens.
///  * ≥ 900px wide — fixed 250px teal-gradient sidebar (brand row, sectioned
///    nav with gold active edge, red-tinted sign out) beside a 64px topbar.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  ShellTab _tab = ShellTab.menuView;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  static const _titles = {
    ShellTab.menuView: 'Menu View',
    ShellTab.orders: 'Orders',
    ShellTab.openChecks: 'Open Checks',
    ShellTab.settings: 'Settings',
  };

  void _select(ShellTab t) {
    // If the drawer is open (this is a drawer tap), close it first — even
    // when the destination does not change.
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
    if (t == _tab) return;
    HapticFeedback.selectionClick();
    setState(() => _tab = t);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 900;
    final dark = Theme.of(context).brightness == Brightness.dark;

    final body = IndexedStack(
      index: _tab.index,
      children: const [
        RegisterScreen(),
        OrdersScreen(),
        OrdersScreen(openOnlyDefault: true),
        SettingsScreen(),
      ],
    );

    final scaffold = wide
        ? Scaffold(
            body: Row(
              children: [
                _Sidebar(selected: _tab, onSelect: _select),
                Expanded(
                  child: SafeArea(
                    top: false,
                    bottom: false,
                    child: Column(
                      children: [
                        _TopBar(title: _titles[_tab]!),
                        Expanded(child: body),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          )
        : Scaffold(
            key: _scaffoldKey,
            drawer: AppDrawer(selected: _tab, onSelect: _select),
            drawerEdgeDragWidth: 72,
            onDrawerChanged: (open) {
              if (open) HapticFeedback.selectionClick();
            },
            body: Column(
              children: [
                _TopBar(
                  title: _titles[_tab]!,
                  showMenuButton: true,
                  onMenu: () => _scaffoldKey.currentState?.openDrawer(),
                ),
                Expanded(child: body),
              ],
            ),
            bottomNavigationBar: _BottomNav(
              selected: _tab,
              onSelect: (t) {
                if (t == ShellTab.settings) {
                  _scaffoldKey.currentState?.openDrawer();
                } else {
                  _select(t);
                }
              },
            ),
          );

    // Edge-to-edge status bar with theme-aware icons; the drawer and the
    // wide-layout sidebar draw under it by design.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemOverlay(dark ? Brightness.dark : Brightness.light),
      child: scaffold,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Topbar — 64px, title left; theme toggle + mono date right. Sits inside a
// SafeArea so the edge-to-edge status bar never overlaps it.
// ─────────────────────────────────────────────────────────────────────────────

class _TopBar extends StatefulWidget {
  final String title;
  final bool showMenuButton;
  final VoidCallback? onMenu;

  const _TopBar({required this.title, this.showMenuButton = false, this.onMenu});

  @override
  State<_TopBar> createState() => _TopBarState();
}

class _TopBarState extends State<_TopBar> {
  late String _date;

  @override
  void initState() {
    super.initState();
    _date = _fmt(DateTime.now());
    // The web topbar refreshes its date every 60s; same cadence here so a
    // tablet left on overnight never shows yesterday.
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _date = _fmt(DateTime.now()));
    });
  }

  late final Timer _clock;

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  static const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _mo = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  String _fmt(DateTime d) =>
      '${_wd[d.weekday - 1]}, ${_mo[d.month - 1]} ${d.day}, ${d.year}';

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: 64,
      color: pal.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          if (widget.showMenuButton) ...[
            IconButton(
              onPressed: widget.onMenu,
              icon: const Icon(Icons.menu_rounded, size: 24),
              color: pal.body,
              tooltip: 'All screens',
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(widget.title,
                style: T.screenTitle.copyWith(color: pal.heading)),
          ),
          IconButton(
            onPressed: () => context.read<ThemeController>().toggle(),
            icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                size: 21),
            color: pal.muted,
            tooltip: dark ? 'Light theme' : 'Dark theme',
          ),
          const SizedBox(width: 2),
          Text(_date,
              style: TextStyle(
                  fontFamily: kFontMono, fontSize: 11.0, color: pal.muted)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sidebar — the PWA's teal gradient rail, sized for touch (48dp rows).
// ─────────────────────────────────────────────────────────────────────────────

class _Sidebar extends StatelessWidget {
  final ShellTab selected;
  final ValueChanged<ShellTab> onSelect;

  const _Sidebar({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    return Container(
      width: 250,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [pal.sidebarTop, pal.sidebarBottom],
        ),
        boxShadow: [
          BoxShadow(
              color: const Color(0xFF073735).withValues(alpha: 0.15),
              blurRadius: 8,
              offset: const Offset(2, 0)),
        ],
      ),
      child: SafeArea(
        top: true,
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BrandHeader(app: app),
            const NavSectionHeader(label: 'Sales'),
            _SideItem(
              icon: Icons.menu_book_outlined,
              label: 'Menu View',
              active: selected == ShellTab.menuView,
              onTap: () => onSelect(ShellTab.menuView),
            ),
            _SideItem(
              icon: Icons.shopping_cart_outlined,
              label: 'Orders',
              active: selected == ShellTab.orders,
              onTap: () => onSelect(ShellTab.orders),
            ),
            _SideItem(
              icon: Icons.credit_card_outlined,
              label: 'Open Checks',
              active: selected == ShellTab.openChecks,
              onTap: () => onSelect(ShellTab.openChecks),
            ),
            const NavSectionHeader(label: 'System'),
            _SideItem(
              icon: Icons.settings_outlined,
              label: 'Settings',
              active: selected == ShellTab.settings,
              onTap: () => onSelect(ShellTab.settings),
            ),
            const Spacer(),
            // Sign out — the PWA's red-tinted footer button.
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextButton.icon(
                onPressed: () => _confirmSignOut(context),
                icon: const Icon(Icons.logout, size: 17),
                label: const Text('Sign Out'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFFF8A8A),
                  backgroundColor: const Color(0xFFDC2F2F).withValues(alpha: 0.2),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  minimumSize: const Size(48, 48),
                  textStyle: const TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Brand + user block shared by the wide sidebar and the phone drawer.
class _BrandHeader extends StatelessWidget {
  final AppState app;
  const _BrandHeader({required this.app});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final name = app.user?.firstName ?? app.user?.displayName ?? '';
    final role = _titleCase(app.user?.role ?? '');
    final initials = name.isEmpty
        ? 'FU'
        : name.trim().split(RegExp(r'\s+')).map((w) => w[0]).take(2).join().toUpperCase();

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.asset('assets/images/logo.webp',
                width: 44, height: 44, fit: BoxFit.cover),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('FU FUT',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: 0.5)),
                const SizedBox(height: 2),
                if (app.user != null) ...[
                  Row(
                    children: [
                      Container(
                        width: 18,
                        height: 18,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: pal.gold,
                        ),
                        child: Text(initials,
                            style: const TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF073735))),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text('$name • $role',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: pal.goldLight,
                                letterSpacing: 0.6)),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _titleCase(String role) {
    if (role.isEmpty) return '';
    return role
        .split(RegExp(r'[\s_-]+'))
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
        .join(' ');
  }
}

class _SideItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _SideItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Active: white text on rgba(255,255,255,.1) with a 3px gold left edge —
    // exactly the web sidebar's selected treatment.
    return Material(
      color: active ? Colors.white.withValues(alpha: 0.1) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                width: 3,
                color: active ? Pal.of(context).gold : Colors.transparent,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(icon,
                  size: 21,
                  color: Colors.white.withValues(alpha: active ? 1 : 0.6)),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: T.navItem.copyWith(
                    color: Colors.white.withValues(alpha: active ? 1 : 0.72),
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              if (active)
                Icon(Icons.chevron_right,
                    size: 18, color: Colors.white.withValues(alpha: 0.9)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AppDrawer — the phone's left navigation drawer: teal gradient, brand +
// user header, touch-sized nav rows with the gold active edge, a theme
// toggle row and the red sign-out footer. Opens by hamburger, edge swipe,
// or the bottom-bar "More".
// ─────────────────────────────────────────────────────────────────────────────

class AppDrawer extends StatelessWidget {
  final ShellTab selected;
  final ValueChanged<ShellTab> onSelect;

  const AppDrawer({super.key, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Drawer(
      backgroundColor: Colors.transparent,
      elevation: 8,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Pal.of(context).sidebarTop, Pal.of(context).sidebarBottom],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BrandHeader(app: app),
              const NavSectionHeader(label: 'Sales'),
              _SideItem(
                  icon: Icons.menu_book_outlined,
                  label: 'Menu View',
                  active: selected == ShellTab.menuView,
                  onTap: () => onSelect(ShellTab.menuView)),
              _SideItem(
                  icon: Icons.shopping_cart_outlined,
                  label: 'Orders',
                  active: selected == ShellTab.orders,
                  onTap: () => onSelect(ShellTab.orders)),
              _SideItem(
                  icon: Icons.credit_card_outlined,
                  label: 'Open Checks',
                  active: selected == ShellTab.openChecks,
                  onTap: () => onSelect(ShellTab.openChecks)),
              const NavSectionHeader(label: 'System'),
              _SideItem(
                  icon: Icons.settings_outlined,
                  label: 'Settings',
                  active: selected == ShellTab.settings,
                  onTap: () => onSelect(ShellTab.settings)),
              _SideItem(
                  icon: dark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                  label: dark ? 'Light theme' : 'Dark theme',
                  active: false,
                  onTap: () => context.read<ThemeController>().toggle()),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextButton.icon(
                  onPressed: () => _confirmSignOut(context),
                  icon: const Icon(Icons.logout, size: 17),
                  label: const Text('Sign Out'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFFF8A8A),
                    backgroundColor:
                        const Color(0xFFDC2F2F).withValues(alpha: 0.2),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    minimumSize: const Size(48, 48),
                    textStyle: const TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bottom nav (phone) — M3 bar: sunken bg, 64×34 pill indicator, 11dp labels.
// "More" opens the drawer.
// ─────────────────────────────────────────────────────────────────────────────

class _BottomNav extends StatelessWidget {
  final ShellTab selected;
  final ValueChanged<ShellTab> onSelect;

  const _BottomNav({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    Widget item(ShellTab tab, IconData icon, IconData activeIcon, String label) {
      final isSel = selected == tab;
      final color = isSel ? pal.primary : pal.muted;
      return Expanded(
        child: InkWell(
          onTap: () => onSelect(tab),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                width: 64,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSel ? pal.tintBg : Colors.transparent,
                  borderRadius: BorderRadius.circular(17),
                ),
                child: Icon(isSel ? activeIcon : icon, size: 23, color: color),
              ),
              const SizedBox(height: 3),
              Text(label,
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 11.0,
                      fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
                      color: color)),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: pal.surface,
        border: Border(top: BorderSide(color: pal.border)),
        boxShadow: [
          BoxShadow(
              color: const Color(0xFF073735).withValues(alpha: 0.05),
              blurRadius: 20,
              offset: const Offset(0, -4)),
        ],
      ),
      padding: EdgeInsets.only(
          left: 8, right: 8, top: 8, bottom: 8 + MediaQuery.of(context).padding.bottom),
      child: Row(
        children: [
          item(ShellTab.menuView, Icons.menu_book_outlined, Icons.menu_book,
              'Menu View'),
          item(ShellTab.orders, Icons.shopping_cart_outlined, Icons.shopping_cart,
              'Orders'),
          item(ShellTab.openChecks, Icons.credit_card_outlined, Icons.credit_card,
              'Open Checks'),
          item(ShellTab.settings, Icons.menu_rounded, Icons.menu_rounded, 'More'),
        ],
      ),
    );
  }
}

Future<void> _confirmSignOut(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Sign out?'),
      content:
          const Text('The cart on this device is cleared for the next shift.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out')),
      ],
    ),
  );
  if (ok == true && context.mounted) {
    await context.read<AppState>().logout();
  }
}
