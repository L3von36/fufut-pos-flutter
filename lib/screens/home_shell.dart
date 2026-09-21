import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/roles.dart';
import '../state/theme_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'cashdrawer_screen.dart';
import 'delivery_screen.dart';
import 'kitchen_board.dart';
import 'my_activity_screen.dart';
import 'my_payslips_screen.dart';
import 'orders_screen.dart';
import 'register_screen.dart';
import 'reports_screen.dart';
import 'role_dashboard.dart';
import 'settings_screen.dart';
import 'tables_screen.dart';
import 'timeclock_screen.dart';
import 'waste_screen.dart';

/// App chrome — the web POS `AppLayout.vue`, re-thought as a native app.
///
/// The nav is per-role: each role signs in to its own home screen and sees
/// only the destinations its server grant backs — the manager to the
/// Dashboard, the chef to the Kitchen board, the waiter to the Tables floor,
/// the cashier to the Cash Drawer, the driver to the Delivery run, the
/// cleaner to the Waste log, the accountant to Reports (mapping in
/// `state/roles.dart`, mirroring the web's ROLE_DEFAULT_VIEW).
///
///  * Phone — an Android `Drawer` (edge swipe, scrim, teal gradient, user
///    header) behind a 52px app bar, with a Material-3 bottom navigation bar
///    carrying the role's hottest screens; "More" opens the drawer.
///  * ≥ 900px wide — fixed teal-gradient sidebar (brand row, sectioned nav
///    with gold active edge, red-tinted sign out) beside a 52px topbar.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late List<NavEntry> _nav;
  late NavKey _tab;
  String? _roleSeen;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Screens built on first visit and kept alive afterwards — an
  /// IndexedStack would eagerly build every role screen (and fire its API
  /// calls) at sign-in; this stays lazy without losing scroll position.
  final Map<NavKey, Widget> _built = {};

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _roleSeen = app.roleKey;
    _nav = navForRole(app.roleKey);
    _tab = defaultViewFor(app.roleKey);
  }

  /// Re-point the nav if the role changed underneath us (session revalidated
  /// as a different account, role edited server-side).
  void _syncRole(AppState app) {
    if (_roleSeen == app.roleKey) return;
    _roleSeen = app.roleKey;
    _built.clear();
    _nav = navForRole(app.roleKey);
    _tab = defaultViewFor(app.roleKey);
  }

  /// Permission guard for the *current* tab, not just new selections. A
  /// mid-shift role edit (or a stale identity the server just corrected) can
  /// leave the shell pointing at a screen the grant no longer covers — the
  /// same bounce the web guard performs on every navigation.
  void _guardTab(AppState app) {
    if (_nav.any((e) => e.key == _tab)) return;
    _tab = defaultViewFor(app.roleKey);
    if (!_nav.any((e) => e.key == _tab)) {
      _tab = _nav.isNotEmpty ? _nav.first.key : NavKey.settings;
    }
  }

  void _select(NavKey t) {
    // If the drawer is open (this is a drawer tap), close it first — even
    // when the destination does not change.
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
    if (t == _tab) return;
    HapticFeedback.selectionClick();
    setState(() => _tab = t);
  }

  Widget _screenFor(NavKey key) {
    return _built.putIfAbsent(key, () {
      switch (key) {
        case NavKey.dashboard:
          return RoleDashboard(onNavigate: _select);
        case NavKey.kitchen:
          return const KitchenBoard();
        case NavKey.barista:
          return const KitchenBoard(baristaMode: true);
        case NavKey.tables:
          return TablesScreen(onNavigate: _select);
        case NavKey.menuView:
          return const RegisterScreen();
        case NavKey.orders:
          return const OrdersScreen();
        case NavKey.openChecks:
          return const OrdersScreen(openOnlyDefault: true);
        case NavKey.cashdrawer:
          return CashDrawerScreen(onNavigate: _select);
        case NavKey.delivery:
          return const DeliveryScreen();
        case NavKey.waste:
          return const WasteScreen();
        case NavKey.reports:
          return const ReportsScreen();
        case NavKey.timeclock:
          return const TimeClockScreen();
        case NavKey.myPay:
          return const MyPayslipsScreen();
        case NavKey.myActivity:
          return const MyActivityScreen();
        case NavKey.settings:
          return const SettingsScreen();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    _syncRole(app);
    _guardTab(app);

    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 900;
    final dark = Theme.of(context).brightness == Brightness.dark;

    // Keep-alive stack of visited screens, only the active one painted.
    // The active tab is always built (that is what seeds [_built]); the ones
    // already visited keep their state, the rest stay unbuilt so their API
    // calls never fire until they are actually opened.
    final body = Stack(
      children: [
        for (final e in _nav)
          if (_built.containsKey(e.key) || e.key == _tab)
            Offstage(offstage: e.key != _tab, child: _screenFor(e.key)),
      ],
    );

    final scaffold = wide
        ? Scaffold(
            body: Row(
              children: [
                _Sidebar(selected: _tab, nav: _nav, onSelect: _select),
                Expanded(
                  child: SafeArea(
                    top: true,
                    bottom: false,
                    child: Column(
                      children: [
                        _TopBar(title: titleFor(_tab)),
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
            drawer: AppDrawer(selected: _tab, nav: _nav, onSelect: _select),
            drawerEdgeDragWidth: 72,
            onDrawerChanged: (open) {
              if (open) HapticFeedback.selectionClick();
            },
            body: SafeArea(
              // Top only: the bottom nav bar sits in the Scaffold's own
              // inset handling, and double-padding it would strand the
              // gesture bar area in page background.
              top: true,
              bottom: false,
              child: Column(
                children: [
                  _TopBar(
                    title: titleFor(_tab),
                    showMenuButton: true,
                    onMenu: () => _scaffoldKey.currentState?.openDrawer(),
                  ),
                  Expanded(child: body),
                ],
              ),
            ),
            bottomNavigationBar: _BottomNav(
              nav: _nav,
              selected: _tab,
              onSelect: (t) {
                if (t == NavKey.settings) {
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
// Topbar — 52px, title left; theme toggle + mono date right. Sits inside a
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
      height: 52,
      color: pal.surface,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          if (widget.showMenuButton) ...[
            IconButton(
              onPressed: widget.onMenu,
              icon: const Icon(Icons.menu_rounded, size: 20),
              color: pal.body,
              visualDensity: VisualDensity.compact,
              tooltip: 'All screens',
            ),
            const SizedBox(width: 2),
          ],
          Expanded(
            child: Text(widget.title,
                style: T.screenTitle.copyWith(color: pal.heading)),
          ),
          IconButton(
            onPressed: () => context.read<ThemeController>().toggle(),
            icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                size: 18),
            color: pal.muted,
            visualDensity: VisualDensity.compact,
            tooltip: dark ? 'Light theme' : 'Dark theme',
          ),
          const SizedBox(width: 2),
          Text(_date,
              style: TextStyle(
                  fontFamily: kFontMono, fontSize: 10.0, color: pal.muted)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sidebar — the PWA's teal gradient rail, sized for touch (42dp rows),
// sectioned by the entries' own section labels.
// ─────────────────────────────────────────────────────────────────────────────

class _Sidebar extends StatelessWidget {
  final NavKey selected;
  final List<NavEntry> nav;
  final ValueChanged<NavKey> onSelect;

  const _Sidebar({required this.selected, required this.nav, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    return Container(
      width: 232,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [pal.sidebarTop, pal.sidebarBottom],
        ),
        boxShadow: [
          BoxShadow(
              color: const Color(0xFF073735).withValues(alpha: 0.12),
              blurRadius: 6,
              offset: const Offset(2, 0)),
        ],
      ),
      child: SafeArea(
        top: true,
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _BrandHeader(app: app),
                  ..._navRows(nav, selected, onSelect),
                ],
              ),
            ),
            // Sign out — the PWA's red-tinted footer button.
            Padding(
              padding: const EdgeInsets.all(10),
              child: TextButton.icon(
                onPressed: () => _confirmSignOut(context),
                icon: const Icon(Icons.logout, size: 15),
                label: const Text('Sign Out'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFFF8A8A),
                  backgroundColor: const Color(0xFFDC2F2F).withValues(alpha: 0.2),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  minimumSize: const Size(48, 38),
                  textStyle: const TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The teal-rail rows shared by the wide sidebar and the phone drawer:
/// a section header whenever the group label changes, then the destination
/// row itself.
List<Widget> _navRows(
    List<NavEntry> nav, NavKey selected, ValueChanged<NavKey> onSelect) {
  final rows = <Widget>[];
  String? lastSection;
  for (final e in nav) {
    if (e.section.isNotEmpty && e.section != lastSection) {
      rows.add(NavSectionHeader(label: e.section));
      lastSection = e.section;
    }
    rows.add(_SideItem(
      entry: e,
      active: selected == e.key,
      onTap: () => onSelect(e.key),
    ));
  }
  return rows;
}

/// Brand + user block shared by the wide sidebar and the phone drawer.
class _BrandHeader extends StatelessWidget {
  final AppState app;
  const _BrandHeader({required this.app});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final name = app.user?.firstName ?? app.user?.displayName ?? '';
    final role = roleTitle(app.user?.role ?? '');
    final initials = name.isEmpty
        ? 'FU'
        : name.trim().split(RegExp(r'\s+')).map((w) => w[0]).take(2).join().toUpperCase();

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset('assets/images/logo.webp',
                width: 36, height: 36, fit: BoxFit.cover),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('FU FUT',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: 0.5)),
                const SizedBox(height: 2),
                if (app.user != null) ...[
                  Row(
                    children: [
                      Container(
                        width: 16,
                        height: 16,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: pal.gold,
                        ),
                        child: Text(initials,
                            style: const TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 8,
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
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: pal.goldLight,
                                letterSpacing: 0.4)),
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
}

class _SideItem extends StatelessWidget {
  final NavEntry entry;
  final bool active;
  final VoidCallback onTap;

  const _SideItem({
    required this.entry,
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
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 16),
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
              Icon(entry.icon,
                  size: 18,
                  color: Colors.white.withValues(alpha: active ? 1 : 0.6)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  entry.label,
                  style: T.navItem.copyWith(
                    color: Colors.white.withValues(alpha: active ? 1 : 0.72),
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              if (active)
                Icon(Icons.chevron_right,
                    size: 16, color: Colors.white.withValues(alpha: 0.9)),
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
  final NavKey selected;
  final List<NavEntry> nav;
  final ValueChanged<NavKey> onSelect;

  const AppDrawer({
    super.key,
    required this.selected,
    required this.nav,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Drawer(
      backgroundColor: Colors.transparent,
      elevation: 8,
      width: 284,
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
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    ..._navRows(nav, selected, onSelect),
                  ],
                ),
              ),
              _SideItem(
                entry: NavEntry(
                    NavKey.settings,
                    dark
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined,
                    Icons.light_mode_outlined,
                    dark ? 'Light theme' : 'Dark theme'),
                active: false,
                onTap: () => context.read<ThemeController>().toggle(),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: TextButton.icon(
                  onPressed: () => _confirmSignOut(context),
                  icon: const Icon(Icons.logout, size: 15),
                  label: const Text('Sign Out'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFFF8A8A),
                    backgroundColor:
                        const Color(0xFFDC2F2F).withValues(alpha: 0.2),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    minimumSize: const Size(48, 38),
                    textStyle: const TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600),
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
// Bottom nav (phone) — M3 bar: sunken bg, pill indicator, 11dp labels.
// Carries the role's first three destinations; "More" opens the drawer with
// everything else.
// ─────────────────────────────────────────────────────────────────────────────

class _BottomNav extends StatelessWidget {
  final List<NavEntry> nav;
  final NavKey selected;
  final ValueChanged<NavKey> onSelect;

  const _BottomNav({
    required this.nav,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    // Bar slots: the first three non-settings screens of the role. The home
    // screen leads by construction — kRolePermissions orders it first.
    final bar = nav.where((e) => e.key != NavKey.settings).take(3).toList();

    Widget item(NavEntry e, bool isSel) {
      final color = isSel ? pal.primary : pal.muted;
      return Expanded(
        child: InkWell(
          onTap: () => onSelect(e.key),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                width: 56,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSel ? pal.tintBg : Colors.transparent,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(isSel ? e.activeIcon : e.icon, size: 20, color: color),
              ),
              const SizedBox(height: 2),
              Text(e.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 10.5,
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
      ),
      padding: EdgeInsets.only(
          left: 8, right: 8, top: 8, bottom: 8 + MediaQuery.of(context).padding.bottom),
      child: Row(
        children: [
          for (final e in bar) item(e, selected == e.key),
          // More — the drawer, which carries every remaining destination.
          Expanded(
            child: InkWell(
              onTap: () => onSelect(NavKey.settings),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 56,
                    height: 30,
                    alignment: Alignment.center,
                    child: Icon(Icons.menu_rounded, size: 20,
                        color: selected == NavKey.settings
                            ? pal.primary
                            : pal.muted),
                  ),
                  const SizedBox(height: 2),
                  Text('More',
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                          color: selected == NavKey.settings
                              ? pal.primary
                              : pal.muted)),
                ],
              ),
            ),
          ),
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
