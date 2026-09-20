import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/theme_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'orders_screen.dart';
import 'register_screen.dart';
import 'settings_screen.dart';

/// Which screen the shell shows. The PWA's cashier chrome in miniature:
/// Menu View, Orders, Open Checks + a "More" sheet holding Settings.
enum ShellTab { menuView, orders, openChecks, settings }

/// App chrome, ported from the web POS `AppLayout.vue`:
///  * ≥ 900px wide — fixed 240px teal-gradient sidebar (brand row, sectioned
///    nav with gold active edge, red-tinted sign out) beside a 60px topbar.
///  * narrower — topbar + Material-3 bottom navigation bar
///    (Menu View · Orders · Open Checks · More) with the PWA's bottom sheet
///    for the overflow screens.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  ShellTab _tab = ShellTab.menuView;

  static const _titles = {
    ShellTab.menuView: 'Menu View',
    ShellTab.orders: 'Orders',
    ShellTab.openChecks: 'Open Checks',
    ShellTab.settings: 'Settings',
  };

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 900;
    final body = IndexedStack(
      index: _tab.index,
      children: const [
        RegisterScreen(),
        OrdersScreen(),
        OrdersScreen(openOnlyDefault: true),
        SettingsScreen(),
      ],
    );

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            _Sidebar(selected: _tab, onSelect: (t) => setState(() => _tab = t)),
            Expanded(
              child: Column(
                children: [
                  _TopBar(title: _titles[_tab]!),
                  Expanded(child: body),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Column(
        children: [
          _TopBar(
            title: _titles[_tab]!,
            showMenuButton: true,
            onMenu: () => _openDrawer(context),
          ),
          Expanded(child: body),
        ],
      ),
      bottomNavigationBar: _BottomNav(
        selected: _tab,
        onSelect: (t) => t == ShellTab.settings
            ? _openMoreSheet(context)
            : setState(() => _tab = t),
      ),
    );
  }

  // ── Phone navigation ───────────────────────────────────────────────────────

  void _openDrawer(BuildContext context) {
    final selected = _tab;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _NavSheet(
        selected: selected,
        onSelect: (t) {
          Navigator.of(context).pop();
          setState(() => _tab = t);
        },
      ),
    );
  }

  void _openMoreSheet(BuildContext context) {
    final selected = _tab;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MoreSheet(
        selected: selected,
        onSelect: (t) {
          Navigator.of(context).pop();
          setState(() => _tab = t);
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Topbar — 60px, title left; theme toggle + mono date right.
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
      height: 60,
      color: pal.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          if (widget.showMenuButton) ...[
            IconButton(
              onPressed: widget.onMenu,
              icon: const Icon(Icons.menu, size: 20),
              color: pal.body,
              tooltip: 'All screens',
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(widget.title,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 13.4,
                    fontWeight: FontWeight.w600,
                    color: pal.heading)),
          ),
          IconButton(
            onPressed: () => context.read<ThemeController>().toggle(),
            icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                size: 18),
            color: pal.muted,
            tooltip: dark ? 'Light theme' : 'Dark theme',
          ),
          const SizedBox(width: 4),
          Text(_date,
              style: TextStyle(
                  fontFamily: kFontMono, fontSize: 10.0, color: pal.muted)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sidebar — the PWA's 240px teal gradient rail.
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
      width: 240,
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Brand row — logo, FU FUT, gold "Name • Role" eyebrow.
          Container(
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset('assets/images/logo.webp',
                      width: 38, height: 38, fit: BoxFit.cover),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('FU FUT',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 12.8,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              letterSpacing: 0.5)),
                      Text(
                        '${app.user?.firstName ?? app.user?.displayName ?? ''}'
                        '${app.user == null ? '' : ' • '}'
                        '${_titleCase(app.user?.role ?? '')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 10.0,
                            fontWeight: FontWeight.w500,
                            color: pal.goldLight,
                            letterSpacing: 1.0),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
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
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: TextButton.icon(
                onPressed: () => _confirmSignOut(context),
                icon: const Icon(Icons.logout, size: 15),
                label: const Text('Sign Out'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFDC2F2F),
                  backgroundColor: const Color(0xFFDC2F2F).withValues(alpha: 0.15),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  minimumSize: const Size(44, 44),
                ),
              ),
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
          height: 44,
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
                  size: 18,
                  color: Colors.white.withValues(alpha: active ? 1 : 0.6)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: T.navItem.copyWith(
                    color: Colors.white.withValues(alpha: active ? 1 : 0.72),
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
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
// Bottom nav (phone) — M3 bar: sunken bg, 64×32 pill indicator.
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
              Container(
                width: 64,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSel ? pal.tintBg : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(isSel ? activeIcon : icon, size: 22, color: color),
              ),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 10.0,
                      fontWeight: FontWeight.w500,
                      color: color)),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: pal.sunken,
        boxShadow: [
          BoxShadow(
              color: const Color(0xFF073735).withValues(alpha: 0.05),
              blurRadius: 20,
              offset: const Offset(0, -4)),
        ],
      ),
      padding: EdgeInsets.only(
          left: 8, right: 8, top: 8, bottom: 10 + MediaQuery.of(context).padding.bottom),
      child: Row(
        children: [
          item(ShellTab.menuView, Icons.menu_book_outlined, Icons.menu_book,
              'Menu View'),
          item(ShellTab.orders, Icons.shopping_cart_outlined, Icons.shopping_cart,
              'Orders'),
          item(ShellTab.openChecks, Icons.credit_card_outlined, Icons.credit_card,
              'Open Checks'),
          item(ShellTab.settings, Icons.expand_more, Icons.expand_more, 'More'),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// "More" sheet — PWA style: 28px top radius, drag handle, "All screens",
// 2-col grid grouped by section.
// ─────────────────────────────────────────────────────────────────────────────

class _MoreSheet extends StatelessWidget {
  final ShellTab selected;
  final ValueChanged<ShellTab> onSelect;

  const _MoreSheet({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.72),
        decoration: BoxDecoration(
          color: pal.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('All screens',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 13.4,
                      fontWeight: FontWeight.w600,
                      color: pal.heading)),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _gridHeader(context, 'Sales'),
                    Row(
                      children: [
                        _tile(context, Icons.menu_book_outlined, 'Menu View',
                            ShellTab.menuView),
                        const SizedBox(width: 10),
                        _tile(context, Icons.shopping_cart_outlined, 'Orders',
                            ShellTab.orders),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _tile(context, Icons.credit_card_outlined, 'Open Checks',
                            ShellTab.openChecks),
                      ],
                    ),
                    _gridHeader(context, 'System'),
                    Row(
                      children: [
                        _tile(context, Icons.settings_outlined, 'Settings',
                            ShellTab.settings),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _gridHeader(BuildContext context, String label) {
    final pal = Pal.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Text(label.toUpperCase(),
          style: T.navHeader.copyWith(color: pal.muted, fontSize: 9.5)),
    );
  }

  Widget _tile(BuildContext context, IconData icon, String label, ShellTab tab) {
    final pal = Pal.of(context);
    final active = selected == tab;
    return Expanded(
      child: InkWell(
        onTap: () => onSelect(tab),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
          decoration: BoxDecoration(
            color: active ? pal.tintBg : pal.sunken.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: active ? pal.primary : pal.border),
          ),
          child: Row(
            children: [
              Icon(icon, size: 17,
                  color: active ? pal.primary : pal.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: active ? pal.primary : pal.body)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Same content as the sidebar, in a drawer sheet for phones.
class _NavSheet extends StatelessWidget {
  final ShellTab selected;
  final ValueChanged<ShellTab> onSelect;

  const _NavSheet({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [pal.sidebarTop, pal.sidebarBottom],
          ),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.asset('assets/images/logo.webp',
                        width: 38, height: 38, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('FU FUT',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 12.8,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                        Text(
                          '${app.user?.firstName ?? ''} • ${app.user?.role ?? ''}',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 10.0,
                              color: pal.goldLight),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
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
            _SideItem(
                icon: Icons.settings_outlined,
                label: 'Settings',
                active: selected == ShellTab.settings,
                onTap: () => onSelect(ShellTab.settings)),
            const SizedBox(height: 8),
          ],
        ),
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
