import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../services/order_journal.dart';
import '../state/app_state.dart';
import '../state/live_feeds.dart';
import '../state/order_scope.dart';
import '../state/roles.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'checkout_sheet.dart' show PaymentResult, PaymentSheet;
import 'order_history_screen.dart';

/// Order history + open checks — the waiter dashboard.
///
/// One screen serves two nav destinations: *Orders* (today's tickets —
/// everything older lives on [OrderHistoryScreen]) and *Open Checks*
/// (`?open=1` — what the floor settles from, previous-day tabs grouped at
/// the bottom so the day's work leads).
///
/// Android-native layout: a KPI strip (open / ready / unpaid / on-tabs),
/// a sticky search field with a horizontally-scrolling status filter row,
/// then ticket cards whose left accent bar carries the status color.
class OrdersScreen extends ConsumerStatefulWidget {
  final bool openOnlyDefault;

  const OrdersScreen({super.key, this.openOnlyDefault = false});

  @override
  ConsumerState<OrdersScreen> createState() => _OrdersScreenState();
}

/// The screen's scoped order list — one FutureProvider per mode (`true` =
/// Open Checks, `false` = today's Orders). All the scoping rules live here:
/// role scoping runs before the status/search filters, exactly like the web
/// OrdersView (a barista filtering "new" must not conjure the kitchen's
/// tickets back into their list); the head-waiter's table context comes
/// from /api/tables; station roles classify lines by category via the
/// shared menu; and the Orders mode reads the live service day while Open
/// Checks stays un-windowed (an unpaid tab is money owed whatever day it
/// was run up). The kitchen feed's push debounces an invalidate — a settle
/// on the till or a serve on the floor repaints this list within seconds.
final ordersFeedProvider =
    FutureProvider.family<List<FufutOrder>, bool>((ref, openOnly) async {
  // READ, never watch: AppState is one mutable object with a single
  // notify bell, and this fetch itself pings it (refreshTill) — watching
  // here would rebuild the provider on its own echo (infinite loop).
  final app = ref.read(appStateProvider);
  // The till gate renders from live state — refresh it alongside the list
  // (cheap public read) so an open/close elsewhere flips this screen too.
  app.refreshTill();
  final needsTables = app.roleKey == 'head-waiter';
  final stationRole =
      const {'barista', 'head-chef', 'assistant-chef'}.contains(app.roleKey);
  if (stationRole) await app.ensureCategories();
  final todayKey = localTodayKey();
  final results = await Future.wait([
    app.api.orders(
      openOnly: openOnly,
      from: openOnly ? null : todayKey,
      to: openOnly ? null : todayKey,
    ),
    if (needsTables) app.api.tables(),
  ]);
  final rows = results[0] as List<FufutOrder>;
  final tables =
      needsTables ? results[1] as List<CafeTable> : const <CafeTable>[];
  final myTables = {for (final t in tables) t.number.toString()};
  return rows
      .where((o) => orderVisibleToRole(o, app.roleKey,
          myId: app.user?.id, myTables: myTables, catByName: app.catByName))
      .where((o) => openOnly || orderIsToday(o))
      .toList();
});

class _OrdersScreenState extends ConsumerState<OrdersScreen> {
  late bool _openOnly = widget.openOnlyDefault;
  String _query = '';
  String _statusFilter = 'all';
  bool _showOlder = false;
  final _search = TextEditingController();

  /// Live push — a settle on the till, a serve on the floor or a new ticket
  /// from a menu view repaints this list within seconds. The shared kitchen
  /// feed carries every active order, so a change there debounces (400ms)
  /// an invalidate of this screen's scoped GET — role scoping, day window
  /// and search stay in one place, and the screen owns no socket.
  Timer? _debounce;

  Future<void> _reload() async => ref.invalidate(ordersFeedProvider(_openOnly));

  void _debouncedReload() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _reload();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// build() watches the provider for the current mode — this getter reads
  /// the same snapshot in the KPI math and filters below.
  List<FufutOrder> get _orders =>
      ref.read(ordersFeedProvider(_openOnly)).value ?? const <FufutOrder>[];

  static const _statuses = [
    'all',
    'new',
    'preparing',
    'ready',
    'served',
    'fulfilled',
    'cancelled'
  ];

  /// Status → card accent color (the `.badge-*` hues).
  static Color _accentFor(BuildContext context, String status) {
    final pal = Pal.of(context);
    switch (status.toLowerCase()) {
      case 'new':
        return pal.info;
      case 'preparing':
      case 'pending':
        return pal.warning;
      case 'ready':
        return const Color(0xFF6366F1);
      case 'served':
        return pal.gold;
      case 'fulfilled':
      case 'completed':
        return pal.success;
      case 'cancelled':
        return pal.danger;
      default:
        return pal.borderStrong;
    }
  }

  List<FufutOrder> get _filtered {
    final q = _query.trim().toLowerCase();
    // The main list is today's service. In Open Checks mode previous-day
    // tabs live in [_olderOrders] below; in Orders mode the day window
    // already cut them, so this is the whole set.
    return _orders.where(orderIsToday).where((o) {
      if (_statusFilter != 'all' && o.status.toLowerCase() != _statusFilter) {
        return false;
      }
      if (q.isEmpty) return true;
      return o.id.toLowerCase().contains(q) ||
          (o.customer ?? '').toLowerCase().contains(q) ||
          (o.tableNum ?? '').toLowerCase().contains(q) ||
          o.itemsRaw.toLowerCase().contains(q);
    }).toList();
  }

  /// Unpaid tabs from previous days — Open Checks mode only. Never hidden
  /// from the KPIs (the money owed does not care which day it was run up),
  /// but grouped under the day's work.
  List<FufutOrder> get _olderOrders =>
      _orders.where((o) => !orderIsToday(o)).toList();

  // ── KPI math — computed over the currently loaded scope ────────────────────

  static const _openStatuses = {'new', 'preparing', 'ready', 'served'};

  bool _isOpen(FufutOrder o) => _openStatuses.contains(o.status.toLowerCase());

  int get _openCount => _orders.where(_isOpen).length;
  int get _readyCount =>
      _orders.where((o) => o.status.toLowerCase() == 'ready').length;
  int get _unpaidCount => _orders
      .where((o) => !o.isPaid && o.status.toLowerCase() != 'cancelled')
      .length;
  double get _onTabs => _orders
      .where((o) => _isOpen(o) && !o.isPaid)
      .fold(0.0, (s, o) => s + o.total);

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = ref.watch(appStateProvider);
    final roleKey = app.roleKey;
    // The scoped list for the current mode; kitchen-feed pushes debounce an
    // invalidate so the list stays honest without owning a socket.
    final ordersAsync = ref.watch(ordersFeedProvider(_openOnly));
    ref.listen(kitchenFeedProvider, (_, __) => _debouncedReload());
    final loading = ordersAsync.isLoading;
    final error = ordersAsync.hasError ? '' : null;
    final rows = _filtered;
    // Previous-day open checks surface only in Open Checks mode; in Orders
    // mode the day window already cut everything older.
    final older = _openOnly ? _olderOrders : const <FufutOrder>[];
    // Service law 2 — the till owns the money. A cashier looking at orders
    // with the drawer closed sees the WHY, not a queue they cannot act on;
    // the manager still sees the list with a banner (they can open the till
    // themselves and keep working).
    final tillClosed = app.tillOpen == false;
    final cashierBlocked = tillClosed && roleKey == 'cashier';
    return Scaffold(
      backgroundColor: pal.bg,
      body: Column(
        children: [
          // ── Header ────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text('Orders',
                    style: T.screenTitle.copyWith(color: pal.heading)),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: pal.tintBg,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text('${rows.length}',
                      style: TextStyle(
                          fontFamily: kFontMono,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: pal.primary)),
                ),
                const Spacer(),
                // Everything older than today — the day screens stay lean.
                _IconAction(icon: Icons.history_rounded, onTap: _openHistory),
                _IconAction(icon: Icons.refresh_rounded, onTap: _reload),
              ],
            ),
          ),
          // ── Scope toggle + search + status chips ─────────────────────────
          if (!widget.openOnlyDefault)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  _ScopeChip(
                    label: 'Open checks',
                    icon: Icons.timelapse_rounded,
                    active: _openOnly,
                    onTap: () {
                      setState(() => _openOnly = true);
                    },
                  ),
                  const SizedBox(width: 6),
                  _ScopeChip(
                    label: 'All recent',
                    icon: Icons.receipt_long_outlined,
                    active: !_openOnly,
                    onTap: () {
                      setState(() => _openOnly = false);
                    },
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: _SearchField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              children: [
                for (final s in _statuses)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _StatusFilterChip(
                      label: s == 'all' ? 'All' : _cap(s),
                      count: s == 'all'
                          ? _orders.length
                          : _orders
                              .where((o) =>
                                  o.status.toLowerCase() == s.toLowerCase())
                              .length,
                      active: _statusFilter == s,
                      onTap: () => setState(() => _statusFilter = s),
                    ),
                  ),
              ],
            ),
          ),
          // ── KPI strip ────────────────────────────────────────────────────
          if (!loading && error == null && _orders.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: _KpiStrip(
                open: _openCount,
                ready: _readyCount,
                unpaid: _unpaidCount,
                onTabs: _onTabs,
              ),
            ),
          // ── List ─────────────────────────────────────────────────────────
          Expanded(
            child: cashierBlocked
                ? ListView(children: [
                    const SizedBox(height: 60),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 18),
                      child: InfoBanner(
                        'The till is closed — orders come back the moment '
                        'the drawer opens. Open the till from the Cash '
                        'Drawer screen to start settling.',
                        severity: InfoSeverity.warning,
                        icon: Icons.lock_outline_rounded,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const EmptyState(
                      icon: Icons.lock_outline_rounded,
                      title: 'Till closed',
                      hint: 'The cashier\'s settle queue unlocks when the '
                          'till opens.',
                    ),
                  ])
                : tillClosed && canCheckout(roleKey)
                    ? ListView(children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(12, 6, 12, 0),
                          child: InfoBanner(
                            'The till is closed — settlements are refused '
                            'until the drawer opens.',
                            severity: InfoSeverity.warning,
                            icon: Icons.lock_outline_rounded,
                          ),
                        ),
                        for (final o in rows)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _OrderTile(
                              order: o,
                              accent: _accentFor(context, o.status),
                              showCheckActions: _openOnly && _isActionable(o),
                              onSplit: () => _splitFlow(o),
                              onMove: () => _moveFlow(o),
                              onMerge: () => _mergeFlow(o),
                              onChanged: _reload,
                            ),
                          ),
                      ])
                    : loading
                        ? const Center(child: CircularProgressIndicator())
                        : error != null
                            ? _ErrorPane(message: error, onRetry: _reload)
                            : (rows.isEmpty && older.isEmpty)
                                ? EmptyState(
                                    icon: Icons.receipt_long,
                                    title: 'No orders yet',
                                    hint: emptyOrdersHint(roleKey),
                                  )
                                : RefreshIndicator(
                                    onRefresh: _reload,
                                    child: ListView(
                                      physics:
                                          const AlwaysScrollableScrollPhysics(),
                                      padding: const EdgeInsets.fromLTRB(
                                          12, 6, 12, 20),
                                      children: [
                                        if (rows.isEmpty && older.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                bottom: 6),
                                            child: Text(
                                              'No checks opened today — '
                                              '${older.length} older unpaid below.',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: pal.muted),
                                            ),
                                          ),
                                        for (final o in rows)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                bottom: 8),
                                            child: _OrderTile(
                                              order: o,
                                              accent:
                                                  _accentFor(context, o.status),
                                              showCheckActions:
                                                  _openOnly && _isActionable(o),
                                              onSplit: () => _splitFlow(o),
                                              onMove: () => _moveFlow(o),
                                              onMerge: () => _mergeFlow(o),
                                              onChanged: _reload,
                                            ),
                                          ),
                                        // ── Previous-day open checks (Open
                                        // Checks mode): grouped under the
                                        // day's work, one tap away — never
                                        // unreachable. An unpaid tab is
                                        // money owed whatever day it was run
                                        // up.
                                        if (older.isNotEmpty)
                                          Padding(
                                            padding:
                                                const EdgeInsets.only(top: 4),
                                            child: _OlderGroupHeader(
                                              count: older.length,
                                              expanded: _showOlder,
                                              onTap: () => setState(() =>
                                                  _showOlder = !_showOlder),
                                            ),
                                          ),
                                        if (older.isNotEmpty && _showOlder)
                                          for (final o in older)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                  bottom: 8),
                                              child: _OrderTile(
                                                order: o,
                                                accent: _accentFor(
                                                    context, o.status),
                                                showCheckActions:
                                                    _isActionable(o),
                                                onSplit: () => _splitFlow(o),
                                                onMove: () => _moveFlow(o),
                                                onMerge: () => _mergeFlow(o),
                                                olderThanToday: true,
                                                onChanged: _reload,
                                              ),
                                            ),
                                      ],
                                    ),
                                  ),
          ),
        ],
      ),
    );
  }

  static String _cap(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1).toLowerCase()}';

  void _openHistory() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const OrderHistoryScreen()));
  }

  /// Split / Move / Merge ride open, unpaid checks only — a settled or
  /// cancelled ticket is money already counted.
  bool _isActionable(FufutOrder o) =>
      !o.isClosed && !o.isPaid && o.status.toLowerCase() != 'cancelled';

  // ── Check operations — the web OpenChecksView's Split | Move | Merge ────

  Future<void> _splitFlow(FufutOrder order) async {
    final seats = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Pal.of(context).surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _SplitSheet(order: order),
    );
    if (seats == null || !mounted) return;
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final legs = await app.api.splitCheck(order.id, seats);
      showInfoOn(messenger, 'Check split into $legs — reload to see the legs');
      _reload();
    } on ApiError catch (e) {
      if (e.isAuthError && mounted) {
        await app.sessionExpired();
        return;
      }
      showErrorOn(messenger, e);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Future<void> _moveFlow(FufutOrder order) async {
    final app = ref.read(appStateProvider);
    List<CafeTable> tables = const [];
    try {
      tables = await app.api.tables();
    } catch (_) {
      // The sheet still renders with an inline error.
    }
    if (!mounted) return;
    final target = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Pal.of(context).surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      constraints: BoxConstraints(
          maxWidth: 680, maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      builder: (_) => _MoveTableSheet(order: order, tables: tables),
    );
    if (target == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.transferCheck(order.id, target);
      showInfoOn(messenger, 'Check moved to Table $target');
      _reload();
    } on ApiError catch (e) {
      if (e.isAuthError && mounted) {
        await app.sessionExpired();
        return;
      }
      showErrorOn(messenger, e);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Future<void> _mergeFlow(FufutOrder order) async {
    final others = _orders
        .where((o) =>
            o.id != order.id &&
            !o.isClosed &&
            !o.isPaid &&
            o.status.toLowerCase() != 'cancelled')
        .toList();
    if (others.isEmpty) {
      showInfo(context, 'No other open checks to merge with');
      return;
    }
    final target = await showModalBottomSheet<FufutOrder>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Pal.of(context).surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      constraints: BoxConstraints(
          maxWidth: 680, maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      builder: (_) => _MergeSheet(source: order, others: others),
    );
    if (target == null || !mounted) return;
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.mergeChecks(order.id, target.id);
      showInfoOn(messenger,
          'Check ${shortId(order.id)} merged into ${shortId(target.id)}');
      _reload();
    } on ApiError catch (e) {
      if (e.isAuthError && mounted) {
        await app.sessionExpired();
        return;
      }
      showErrorOn(messenger, e);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Header atoms
// ─────────────────────────────────────────────────────────────────────────────

/// 40px circular icon button used for the refresh action.
class _IconAction extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _IconAction({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Material(
      color: pal.sunken,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(icon, size: 17, color: pal.body),
        ),
      ),
    );
  }
}

/// Scope toggle — 'Open checks' vs 'All recent'.
class _ScopeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _ScopeChip({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(99),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: active ? pal.primary : pal.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: active ? pal.primary : pal.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: active ? Colors.white : pal.muted),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: active ? Colors.white : pal.body)),
          ],
        ),
      ),
    );
  }
}

/// 48px search field — surface card, rounded 13, trailing clear button.
class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _SearchField({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: pal.surface,
        border: Border.all(color: pal.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 17, color: pal.muted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: TextStyle(
                  fontFamily: kFontBody, fontSize: 12.5, color: pal.heading),
              decoration: InputDecoration(
                hintText: 'Search id, table, customer…',
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                suffixIcon: controller.text.isEmpty
                    ? null
                    : IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.close_rounded,
                            size: 16, color: pal.muted),
                        onPressed: () {
                          controller.clear();
                          onChanged('');
                        },
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Status filter — pill with live count, primary when active.
class _StatusFilterChip extends StatelessWidget {
  final String label;
  final int count;
  final bool active;
  final VoidCallback onTap;

  const _StatusFilterChip({
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(99),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
        decoration: BoxDecoration(
          color: active ? pal.primary : pal.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: active ? pal.primary : pal.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: active ? Colors.white : pal.body)),
            if (count > 0) ...[
              const SizedBox(width: 5),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 0.5),
                decoration: BoxDecoration(
                  color: active
                      ? Colors.white.withValues(alpha: 0.22)
                      : pal.sunken,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text('$count',
                    style: TextStyle(
                        fontFamily: kFontMono,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        color: active ? Colors.white : pal.muted)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// KPI strip — Open / Ready / Unpaid / On tabs, tinted mini cards.
// ─────────────────────────────────────────────────────────────────────────────

class _KpiStrip extends StatelessWidget {
  final int open;
  final int ready;
  final int unpaid;
  final double onTabs;

  const _KpiStrip({
    required this.open,
    required this.ready,
    required this.unpaid,
    required this.onTabs,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Dark mode: wash the accent at 16% over the card instead of a solid
    // fill — a saturated block with same-hue text is unreadable.
    Color tint(Color base, Color bg) =>
        dark ? base.withValues(alpha: 0.16) : bg;

    final cells = [
      (
        label: 'OPEN',
        value: '$open',
        bg: tint(pal.warning, pal.warningBg),
        fg: dark ? pal.warning : const Color(0xFF92400E),
      ),
      (
        label: 'READY',
        value: '$ready',
        bg: tint(const Color(0xFF6366F1), const Color(0xFFEEF2FF)),
        fg: dark ? const Color(0xFFA5B4FC) : const Color(0xFF3730A3),
      ),
      (
        label: 'UNPAID',
        value: '$unpaid',
        bg: tint(pal.danger, pal.dangerBg),
        fg: dark ? pal.danger : const Color(0xFF991B1B),
      ),
      (
        label: 'ON TABS',
        value: moneyGroup(onTabs),
        bg: tint(pal.primary, pal.tintBg),
        fg: dark ? pal.primary : pal.primary,
      ),
    ];

    return Row(
      children: [
        for (var i = 0; i < cells.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
              decoration: BoxDecoration(
                color: cells[i].bg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  Text(cells[i].value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: kFontMono,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: cells[i].fg)),
                  const SizedBox(height: 1),
                  Text(cells[i].label,
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: cells[i].fg.withValues(alpha: 0.75))),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Ticket card — status accent bar, id + badges, items, money, icon meta row.
// ─────────────────────────────────────────────────────────────────────────────

/// Collapsible divider for previous-day open checks — the Flutter twin of the
/// web OpenChecksView's "Older open checks (N)" toggle.
class _OlderGroupHeader extends StatelessWidget {
  final int count;
  final bool expanded;
  final VoidCallback onTap;
  const _OlderGroupHeader({
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: pal.warning.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: pal.warning.withValues(alpha: 0.45)),
        ),
        child: Row(
          children: [
            Icon(Icons.history_rounded,
                size: 15, color: pal.warning.withValues(alpha: 0.9)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Older open checks ($count) — from previous days',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: pal.heading),
              ),
            ),
            AnimatedRotation(
              turns: expanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 150),
              child:
                  Icon(Icons.expand_more_rounded, size: 18, color: pal.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderTile extends ConsumerWidget {
  final FufutOrder order;
  final Color accent;
  final bool showCheckActions;
  final VoidCallback? onSplit;
  final VoidCallback? onMove;
  final VoidCallback? onMerge;

  /// Called after the detail sheet mutates the order (advance, settle) —
  /// the list repaints from the server instead of waiting for a manual
  /// refresh (the owner's stale-settle report, 2026-09).
  final VoidCallback? onChanged;

  /// True inside the previous-day open-checks group: renders an amber left
  /// bar (the web's `.oc-check.is-older`) so an aged tab reads as aged.
  final bool olderThanToday;

  const _OrderTile({
    required this.order,
    required this.accent,
    this.showCheckActions = false,
    this.onSplit,
    this.onMove,
    this.onMerge,
    this.onChanged,
    this.olderThanToday = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pal = Pal.of(context);
    final type = order.type ?? '';
    final table = order.tableNum != null && order.tableNum!.isNotEmpty
        ? 'Table ${order.tableNum}'
        : '';
    final customer = order.customer != null && order.customer != 'Walk-in'
        ? order.customer!
        : '';

    return InkWell(
      onTap: () => _openDetail(context),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: pal.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: pal.border),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 4, color: olderThanToday ? pal.warning : accent),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(11),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Line 1: id + status + pay
                      Row(
                        children: [
                          Expanded(
                            child: Text('Order #${order.id}',
                                style: T.mono.copyWith(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: pal.heading)),
                          ),
                          StatusBadge(status: order.status),
                          const SizedBox(width: 5),
                          PayBadge(paid: order.isPaid),
                        ],
                      ),
                      // Line 2: items
                      if (order.itemsRaw.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          order.items.isNotEmpty
                              ? order.items
                                  .map((l) => l.qty > 1
                                      ? '${l.qty}× ${l.name}'
                                      : l.name)
                                  .join(', ')
                              : order.itemsRaw,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 11.5,
                              height: 1.35,
                              color: pal.muted),
                        ),
                      ],
                      const SizedBox(height: 6),
                      // Line 3: money + method + type
                      Row(
                        children: [
                          Text(money(order.total),
                              style: T.mono.copyWith(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                  color: pal.heading)),
                          if (order.tip > 0) ...[
                            const SizedBox(width: 5),
                            _Tag(
                              text: '+${money(order.tip)}',
                              bg: pal.tintBg,
                              fg: pal.primary,
                            ),
                          ],
                          if (order.discount > 0) ...[
                            const SizedBox(width: 5),
                            _Tag(
                              text: '-${money(order.discount)}',
                              bg: pal.successBg,
                              fg: pal.success,
                            ),
                          ],
                          const Spacer(),
                          if ((order.payment ?? '').isNotEmpty)
                            Text(_title(order.payment!),
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 11,
                                    color: pal.muted)),
                          if ((order.payment ?? '').isNotEmpty &&
                              type.isNotEmpty)
                            Text('  ·  ',
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 11,
                                    color: pal.faint)),
                          if (type.isNotEmpty)
                            Text(_title(type),
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 11,
                                    color: pal.muted)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // Line 4: table · customer · date — with icons
                      Row(
                        children: [
                          if (table.isNotEmpty) ...[
                            Icon(Icons.table_restaurant_outlined,
                                size: 11, color: pal.faint),
                            const SizedBox(width: 3),
                            Text(table,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 10.5,
                                    color: pal.faint)),
                            const SizedBox(width: 8),
                          ],
                          if (customer.isNotEmpty) ...[
                            Icon(Icons.person_outline,
                                size: 11.5, color: pal.faint),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(customer,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontFamily: kFontBody,
                                      fontSize: 10.5,
                                      color: pal.faint)),
                            ),
                            const SizedBox(width: 8),
                          ],
                          if (order.created != null) ...[
                            Icon(Icons.schedule, size: 11, color: pal.faint),
                            const SizedBox(width: 3),
                            Text(order.created!,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 10.5,
                                    color: pal.faint)),
                          ],
                        ],
                      ),
                      // Line 5: Split | Move | Merge — open checks only,
                      // exactly the web OpenChecksView's action row.
                      if (showCheckActions) ...[
                        const SizedBox(height: 8),
                        Row(children: [
                          _CheckAction(
                              icon: Icons.call_split,
                              label: 'Split',
                              onTap: onSplit),
                          const SizedBox(width: 6),
                          _CheckAction(
                              icon: Icons.open_with,
                              label: 'Move',
                              onTap: onMove),
                          const SizedBox(width: 6),
                          _CheckAction(
                              icon: Icons.merge,
                              label: 'Merge',
                              onTap: onMerge),
                        ]),
                      ],
                    ],
                  ),
                ),
              ),
              // Tap affordance — subtle chevron like a native list tile.
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.chevron_right_rounded,
                      size: 18, color: pal.faint),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _title(String s) => s.isEmpty
      ? s
      : s
          .split(RegExp(r'[\s_-]+'))
          .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
          .join(' ');

  void _openDetail(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: false,
      isScrollControlled: true,
      backgroundColor: Pal.of(context).surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      constraints: BoxConstraints(
          maxWidth: 680, maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      builder: (_) => OrderDetailSheet(order: order, onChanged: onChanged),
    );
  }
}

/// Small inline tag (tip/discount chips).
class _Tag extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  const _Tag({required this.text, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(text,
          style: T.mono
              .copyWith(fontSize: 10, fontWeight: FontWeight.w700, color: fg)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Detail sheet — lines, money rows, and the stage's action buttons.
// ─────────────────────────────────────────────────────────────────────────────

class OrderDetailSheet extends ConsumerWidget {
  final FufutOrder order;

  /// Parent refresh hook — fired after every successful mutation so the
  /// list behind the sheet is already new when the sheet closes.
  final VoidCallback? onChanged;
  const OrderDetailSheet({super.key, required this.order, this.onChanged});

  /// The kitchen pipeline's prep stages — the web's row actions, and the
  /// web's gate with them: OrdersView shows "Start Prep" (new → preparing)
  /// and "Ready" (preparing → ready) only to the two chef roles. This map
  /// only feeds those two stages; "Complete" below is everyone's.
  static const _prepNext = {
    'new': 'preparing',
    'preparing': 'ready',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pal = Pal.of(context);
    final app = ref.watch(appStateProvider);
    final status = order.status.toLowerCase();
    // Chef work sits behind the chef grant — the waiter reads the ticket,
    // the kitchen moves it: "Start Prep" (new → preparing) and "Ready"
    // (preparing → ready) only to the two chef roles.
    final prep = canAdvancePrep(app.roleKey) ? _prepNext[status] : null;
    // Owner's flow (2026-09): the kitchen hands off, the floor serves.
    //   ready → fulfilled is the chef's "picked up by waiter" — the pass is
    //   clear once the floor takes the tray;
    //   fulfilled → served is the floor's moment, never the chef's — the
    //   guests say it was served, not the kitchen. The till joins the serve
    //   set so takeaway hands over at the counter.
    final pickup =
        canAdvancePrep(app.roleKey) && status == 'ready' ? 'fulfilled' : null;
    final serve =
        canMarkServed(app.roleKey) && status == 'fulfilled' ? 'served' : null;
    // Money moves only with the checkout grant (manager, cashier) — and only
    // when the order has actually been served (owner's rule, 2026-09): a
    // ticket nobody has cooked, let alone served, cannot be settled. Service
    // law 2 adds the till: a closed drawer refuses settlement outright.
    final maySettle = canCheckout(app.roleKey) &&
        !order.isPaid &&
        status == 'served' &&
        app.tillOpen != false;
    // Station roles read only their own lines — barista the drinks, chefs
    // the food; null shows the ticket unchanged.
    final scoped = orderLinesForRole(order, app.roleKey,
        catByName: ref.read(appStateProvider).catByName);
    final visibleLines = scoped ?? order.items;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text('Order #${order.id}',
                      style: T.mono.copyWith(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: pal.heading)),
                ),
                StatusBadge(status: order.status),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              [
                if ((order.type ?? '').isNotEmpty) order.type!,
                if (order.tableNum != null && order.tableNum!.isNotEmpty)
                  'Table ${order.tableNum}',
                if (order.customer != null && order.customer != 'Walk-in')
                  order.customer!,
                if (order.created != null) order.created!,
              ].join('  ·  '),
              style: TextStyle(
                  fontFamily: kFontBody, fontSize: 11, color: pal.faint),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (visibleLines.isNotEmpty)
                      for (final l in visibleLines)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 26,
                                alignment: Alignment.center,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                  color: pal.sunken,
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text('${l.qty}×',
                                    style: T.mono.copyWith(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w700,
                                        color: pal.body)),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(_lineLabel(l),
                                    style: TextStyle(
                                        fontFamily: kFontBody,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w500,
                                        height: 1.3,
                                        color: pal.heading)),
                              ),
                              const SizedBox(width: 8),
                              Text(money(l.lineTotal),
                                  style: T.mono
                                      .copyWith(fontSize: 12, color: pal.body)),
                            ],
                          ),
                        )
                    else
                      Text(
                          order.itemsRaw.isEmpty
                              ? 'No line detail (legacy order)'
                              : order.itemsRaw,
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 11.5,
                              color: pal.body)),
                    if (scoped != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        app.roleKey == 'barista'
                            ? 'Drink lines only — food routes to the kitchen.'
                            : 'Food lines only — drinks route to the bar.',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 10.5,
                            fontStyle: FontStyle.italic,
                            color: pal.faint),
                      ),
                    ],
                    if ((order.notes ?? '').isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: pal.sunken,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.sticky_note_2_outlined,
                                size: 14, color: pal.muted),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text('Notes: ${order.notes}',
                                  style: TextStyle(
                                      fontFamily: kFontBody,
                                      fontSize: 11.5,
                                      color: pal.body)),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.only(top: 10),
                      decoration: BoxDecoration(
                          border: Border(top: BorderSide(color: pal.border))),
                      child: Column(
                        children: [
                          _moneyRow(context, 'Subtotal', order.subtotal),
                          if (order.discount > 0)
                            _moneyRow(context, 'Discount', -order.discount),
                          if (order.tip > 0)
                            _moneyRow(context, 'Tip', order.tip),
                          if (order.deliveryFee > 0)
                            _moneyRow(context, 'Delivery', order.deliveryFee),
                          _moneyRow(context, 'Total', order.total, bold: true),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            if (maySettle)
              AsyncButton(
                onPressed: () => _settle(context, ref),
                icon: Icons.payments_outlined,
                label: 'Settle — take payment',
              ),
            if (prep != null) ...[
              const SizedBox(height: 9),
              AsyncButton(
                onPressed: () => _advance(context, ref, prep),
                icon: Icons.arrow_forward_rounded,
                label: 'Mark ${_title(prep)}',
                outlined: true,
              ),
            ],
            if (pickup != null) ...[
              const SizedBox(height: 9),
              AsyncButton(
                onPressed: () => _advance(context, ref, pickup),
                icon: Icons.outbox_rounded,
                label: 'Picked up by waiter',
                outlined: true,
              ),
            ],
            if (serve != null) ...[
              const SizedBox(height: 9),
              AsyncButton(
                onPressed: () => _advance(context, ref, serve),
                icon: Icons.room_service_rounded,
                label: 'Mark served',
              ),
            ],
            if (!maySettle &&
                prep == null &&
                pickup == null &&
                serve == null) ...[
              const SizedBox(height: 14),
              Text(
                order.isPaid
                    ? 'This check is settled.'
                    : status != 'served' && canCheckout(app.roleKey)
                        ? 'Settle opens once the order is served.'
                        : app.tillOpen == false && canCheckout(app.roleKey)
                            ? 'The till is closed — open the till to settle.'
                            : 'No actions for your role on this stage.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 11.5, color: pal.faint),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _title(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1).toLowerCase()}';

  /// "2x Macchiato [Extra shot] (no sugar)" — what the kitchen actually
  /// cooks, on one line.
  String _lineLabel(OrderItemLine l) {
    final sb = StringBuffer(l.name);
    final mods = l.modifiers
        .map((m) => (m['name'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .join(', ');
    if (mods.isNotEmpty) sb.write(' [$mods]');
    if (l.notes != null && l.notes!.isNotEmpty) sb.write(' (${l.notes})');
    return sb.toString();
  }

  Widget _moneyRow(BuildContext context, String label, double value,
      {bool bold = false}) {
    final pal = Pal.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label,
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 12,
                  color: pal.muted,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
          const Spacer(),
          Text(money(value),
              style: T.mono.copyWith(
                  fontSize: bold ? 14.5 : 12,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                  color: bold ? pal.heading : pal.body)),
        ],
      ),
    );
  }

  Future<void> _advance(
      BuildContext context, WidgetRef ref, String status) async {
    final app = ref.read(appStateProvider);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Service law 4 — the kitchen's buttons move the kitchen's lines: prep
      // and pickup from this sheet are scoped to the food (drinks have their
      // own board and their own handoff). The floor's "Mark served" stays
      // whole-ticket by design.
      final station = canAdvancePrep(app.roleKey) ? 'kitchen' : null;
      await app.api.updateStatus(order, status, station: station);
      // The acting device stamps the stage exactly — the Order Log's clock.
      OrderJournal.instance.record(order.id, _journalStage(status),
          by: app.user?.displayName,
          note: (order.tableNum ?? '').isNotEmpty
              ? 'Table ${order.tableNum}'
              : null);
      onChanged?.call();
      navigator.pop();
      showInfoOn(messenger, 'Marked $status');
    } on ApiError catch (e) {
      if (e.isAuthError) {
        await app.sessionExpired();
      }
      showErrorOn(messenger, e);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  static OrderStage _journalStage(String status) {
    switch (status.toLowerCase()) {
      case 'preparing':
        return OrderStage.preparing;
      case 'ready':
        return OrderStage.ready;
      case 'fulfilled':
        return OrderStage.pickedUp;
      case 'served':
        return OrderStage.served;
      default:
        return OrderStage.created;
    }
  }

  Future<void> _settle(BuildContext context, WidgetRef ref) async {
    final app = ref.read(appStateProvider);
    // fixedTotal: the bill is already on the server — the sheet must not
    // read the cart (there is none in this flow). Tip stays available, and
    // the split-bill legs ride the same breakdown.
    final result = await showModalBottomSheet<PaymentResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Pal.of(context).surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      constraints: BoxConstraints(
          maxWidth: 680, maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      builder: (_) => PaymentSheet(fixedTotal: order.total),
    );
    if (result == null || !context.mounted) return;
    final line = result.primary;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    // The payment sheet is gone; the PUT is still in flight — the processing
    // barrier is the button's busy state, carried past the pop.
    final hideOverlay =
        await showProcessingOverlay(context, 'Taking the payment…');
    try {
      await app.api.settleOrder(order, line.method, line,
          tip: result.tip, breakdown: result.breakdown);
      // Money moved: stamp the bill-cleared leg of the Order Log timeline.
      OrderJournal.instance.record(order.id, OrderStage.paid,
          by: app.user?.displayName,
          note: '\${line.method} · \${money(line.amount)}');
      onChanged?.call(); // the settled tab leaves the list behind the sheet
      // Money moved on THIS device — flip every surface now instead of
      // waiting for the push: the floor's pay badge, the pending panel and
      // the kitchen feed all read the payment state.
      ref.read(tablesFeedProvider.notifier).refreshTables();
      ref.read(pendingOrdersProvider.notifier).refresh();
      navigator.pop();
      showInfoOn(
          messenger, 'Tab settled — ${money(line.amount)} via ${line.method}');
    } on ApiError catch (e) {
      if (e.isAuthError) {
        await app.sessionExpired();
      }
      showErrorOn(messenger, e);
    } catch (e) {
      showErrorOn(messenger, e);
    } finally {
      await hideOverlay();
    }
  }
}

class _ErrorPane extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorPane({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 32, color: pal.faint),
            const SizedBox(height: 10),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 12.5, color: pal.body)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Check operations — Split · Move · Merge sheets (the web OpenChecksView).
// ─────────────────────────────────────────────────────────────────────────────

/// Compact inline action button of the check's action row.
class _CheckAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _CheckAction({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Expanded(
      child: SizedBox(
        height: 28,
        child: OutlinedButton.icon(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            side: BorderSide(color: pal.border),
            textStyle: const TextStyle(
                fontFamily: kFontBody,
                fontSize: 10.5,
                fontWeight: FontWeight.w600),
          ),
          icon: Icon(icon, size: 12, color: pal.primary),
          label: Text(label, style: TextStyle(color: pal.body)),
        ),
      ),
    );
  }
}

/// Split: pick the number of seats / splits (2–10), preview the per-seat
/// share, then `POST /api/orders/:id/split {seatCount}`.
class _SplitSheet extends StatefulWidget {
  final FufutOrder order;
  const _SplitSheet({required this.order});

  @override
  State<_SplitSheet> createState() => _SplitSheetState();
}

class _SplitSheetState extends State<_SplitSheet> {
  int _seats = 2;

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final perHead = widget.order.total / _seats;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            const SizedBox(height: 6),
            Text('Split Check',
                style: T.screenTitle.copyWith(color: pal.heading)),
            Text('${shortId(widget.order.id)} · ${money(widget.order.total)}',
                style: TextStyle(
                    fontFamily: kFontMono, fontSize: 11.5, color: pal.muted)),
            const SizedBox(height: 14),
            Text('NUMBER OF SEATS / SPLITS',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: pal.muted)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var n = 2; n <= 10; n++)
                  ChoiceChip(
                    label: Text('$n'),
                    selected: _seats == n,
                    labelStyle: TextStyle(
                        fontFamily: kFontMono,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _seats == n ? Colors.white : pal.body),
                    selectedColor: pal.primary,
                    backgroundColor: pal.sunken,
                    side: BorderSide(
                        color: _seats == n ? pal.primary : pal.border),
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => _seats = n),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: pal.tintBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('PER SEAT',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                              color: pal.muted)),
                      const SizedBox(height: 2),
                      Text(money(perHead),
                          style: TextStyle(
                              fontFamily: kFontMono,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: pal.primary)),
                    ],
                  ),
                ),
                Text('$_seats checks',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 11.5,
                        color: pal.muted)),
              ]),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 40,
              child: FilledButton.icon(
                onPressed: () => Navigator.pop(context, _seats),
                icon: const Icon(Icons.call_split, size: 17),
                label: Text('Split into $_seats'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Move: pick the destination table, then
/// `POST /api/orders/:id/transfer {tableNumber}`.
class _MoveTableSheet extends StatelessWidget {
  final FufutOrder order;
  final List<CafeTable> tables;

  const _MoveTableSheet({required this.order, required this.tables});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            const SizedBox(height: 6),
            Text('Move Check',
                style: T.screenTitle.copyWith(color: pal.heading)),
            Text(
                '${shortId(order.id)} · ${order.tableNum != null && order.tableNum!.isNotEmpty ? 'from Table ${order.tableNum}' : money(order.total)}',
                style: TextStyle(
                    fontFamily: kFontMono, fontSize: 11.5, color: pal.muted)),
            const SizedBox(height: 12),
            Flexible(
              child: tables.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Center(
                        child: Text('Tables could not be loaded',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 11.5,
                                color: pal.faint)),
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final t in tables)
                          if (t.number != order.tableNum)
                            InkWell(
                              onTap: () => Navigator.pop(context, t.number),
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 8, horizontal: 4),
                                child: Row(children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: t.status == 'available'
                                            ? pal.success
                                            : (t.status == 'occupied'
                                                ? pal.warning
                                                : pal.info)),
                                  ),
                                  const SizedBox(width: 9),
                                  Expanded(
                                    child: Text(
                                        'Table ${t.number}'
                                        '${(t.section ?? '').isNotEmpty ? ' — ${t.section}' : ''}'
                                        '${t.seats != null ? ' (${t.seats} seats)' : ''}',
                                        style: TextStyle(
                                            fontFamily: kFontBody,
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600,
                                            color: pal.heading)),
                                  ),
                                  Text(t.status,
                                      style: TextStyle(
                                          fontFamily: kFontBody,
                                          fontSize: 10.5,
                                          color: pal.muted)),
                                ]),
                              ),
                            ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Merge: pick the target check, then
/// `POST /api/orders/merge {sourceOrderId, targetOrderId}`.
class _MergeSheet extends StatelessWidget {
  final FufutOrder source;
  final List<FufutOrder> others;

  const _MergeSheet({required this.source, required this.others});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            const SizedBox(height: 6),
            Text('Merge Into…',
                style: T.screenTitle.copyWith(color: pal.heading)),
            Text(
                'moves ${shortId(source.id)} (${money(source.total)}) onto the check you pick',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 11, color: pal.muted)),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final o in others)
                    InkWell(
                      onTap: () => Navigator.pop(context, o),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 4),
                        child: Row(children: [
                          Icon(Icons.credit_card, size: 15, color: pal.primary),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                    '${shortId(o.id)} · ${o.tableNum != null && o.tableNum!.isNotEmpty ? 'Table ${o.tableNum}' : (o.customer ?? 'Walk-in')}',
                                    style: TextStyle(
                                        fontFamily: kFontBody,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                        color: pal.heading)),
                                Text(o.itemsRaw,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontFamily: kFontBody,
                                        fontSize: 10.5,
                                        color: pal.muted)),
                              ],
                            ),
                          ),
                          Text(money(o.total),
                              style: T.mono.copyWith(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: pal.heading)),
                        ]),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
