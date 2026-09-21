/// Role-flavored dashboards — the web POS `DashboardView.vue` `buildKpis()`
/// branch, native.
///
/// Every role lands on a dashboard shaped for its own work, computed from the
/// same endpoints the web uses:
///  * manager / accountant — the full trading picture (ManagerDashboard).
///  * head-waiter — Ready to Serve · Active Tables · Open Orders · Today's
///    Reservations (`/api/orders`, `/api/tables`, `/api/reservations`).
///  * head-chef / assistant-chef — New · In Progress · Ready, straight off
///    today's kitchen tickets.
///  * cashier — Today's Sales · Cash · Digital · Avg · Tips, the live till
///    float card and the bill-request queue (`/api/reports/dashboard`,
///    `/api/cashdrawer`, `/api/tables`).
///  * delivery-staff — Pending Pickups · In Transit · Delivered Today
///    (`/api/delivery`).
///  * cleaner — Tables to Clean · Occupied · Waste Logged Today
///    (`/api/tables`, `/api/waste`).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/roles.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';
import 'manager_dashboard.dart';

/// The device-local `YYYY-MM-DD` stamp — server rows carry local-time
/// strings, never UTC, so "today" is computed the same way the web's
/// `TODAY()` does.
String _today() {
  final n = DateTime.now();
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${n.year}-${two(n.month)}-${two(n.day)}';
}

/// "asked 4m ago" / "3h ago" — the web's timeAgo, coarse-grained.
String timeAgo(String? stamp) {
  if (stamp == null || stamp.isEmpty) return '';
  final t = DateTime.tryParse(stamp);
  if (t == null) return stamp;
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// Entry point — dispatches on the signed-in role.
class RoleDashboard extends StatelessWidget {
  final ValueChanged<NavKey>? onNavigate;

  const RoleDashboard({super.key, this.onNavigate});

  @override
  Widget build(BuildContext context) {
    final role = context.watch<AppState>().roleKey ?? '';
    switch (role) {
      case 'head-waiter':
        return WaiterDashboard(onNavigate: onNavigate);
      case 'head-chef':
      case 'assistant-chef':
      case 'barista':
        return ChefDashboard(onNavigate: onNavigate);
      case 'cashier':
        return CashierDashboard(onNavigate: onNavigate);
      case 'delivery-staff':
        return DriverDashboard(onNavigate: onNavigate);
      case 'cleaner':
        return CleanerDashboard(onNavigate: onNavigate);
      default:
        // manager + accountant keep the full trading picture; unknown roles
        // land there too rather than on a blank pane.
        return ManagerDashboard(onNavigate: onNavigate);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Head waiter
// ─────────────────────────────────────────────────────────────────────────────

class WaiterDashboard extends StatefulWidget {
  final ValueChanged<NavKey>? onNavigate;
  const WaiterDashboard({super.key, this.onNavigate});

  @override
  State<WaiterDashboard> createState() => _WaiterDashboardState();
}

class _WaiterDashboardState extends State<WaiterDashboard> {
  List<FufutOrder> _orders = [];
  List<CafeTable> _tables = [];
  List<Reservation> _reservations = [];
  bool _loading = true;
  Object? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 45), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        app.api.orders(),
        app.api.tables(),
        app.api.reservations(),
      ]);
      if (!mounted) return;
      setState(() {
        _orders = results[0] as List<FufutOrder>;
        _tables = results[1] as List<CafeTable>;
        _reservations = results[2] as List<Reservation>;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) {
        await app.sessionExpired();
        return;
      }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _orders.isEmpty) return const DashboardSkeleton();
    if (_error != null && _orders.isEmpty) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final pal = Pal.of(context);
    final today = _today();

    // The web head-waiter branch: Ready to Serve · Active Tables · Open
    // Orders · Today Reservations.
    final readyToServe =
        _orders.where((o) => o.status.toLowerCase() == 'ready').length;
    final activeTables =
        _tables.where((t) => t.status != 'available').length;
    final seatedGuests = _tables
        .where((t) => t.status == 'occupied')
        .fold<int>(0, (s, t) => s + (int.tryParse(t.guests ?? '') ?? 0));
    final openOrders = _orders
        .where((o) => !o.isClosed &&
            o.status.toLowerCase() != 'cancelled' &&
            !o.isPaid)
        .length;
    final todayReservations = _reservations
        .where((r) => r.date == today && r.status.toLowerCase() != 'cancelled')
        .toList();

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          _quickActions(),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: KpiCard(
                label: 'Ready to Serve',
                value: '$readyToServe',
                icon: Icons.room_service_outlined,
                valueColor: readyToServe > 0 ? pal.primary : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                label: 'Active Tables',
                value: '$activeTables/${_tables.length}',
                icon: Icons.table_restaurant_outlined,
                sub: seatedGuests > 0 ? '$seatedGuests guests seated' : null,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: KpiCard(
                label: 'Open Orders',
                value: '$openOrders',
                icon: Icons.receipt_long,
                valueColor: openOrders > 0 ? pal.warning : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                label: 'Reservations',
                value: '${todayReservations.length}',
                icon: Icons.event_available_outlined,
                sub: 'today',
              ),
            ),
          ]),
          const SizedBox(height: 12),
          _reservationsCard(todayReservations),
          const SizedBox(height: 10),
          _openChecksCard(),
        ],
      ),
    );
  }

  Widget _quickActions() {
    void go(NavKey k) => widget.onNavigate?.call(k);
    return GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 0.95,
      children: [
        QuickAction(icon: Icons.grid_view, label: 'Floor Plan', onTap: () => go(NavKey.tables)),
        QuickAction(icon: Icons.add_shopping_cart, label: 'New Order', onTap: () => go(NavKey.menuView)),
        QuickAction(icon: Icons.receipt_long, label: 'Orders', onTap: () => go(NavKey.orders)),
        QuickAction(icon: Icons.credit_card, label: 'Open Checks', onTap: () => go(NavKey.openChecks)),
      ],
    );
  }

  Widget _reservationsCard(List<Reservation> rows) {
    return SectionCard(
      title: "Today's Reservations",
      trailing: Icon(Icons.event_available, size: 15, color: Pal.of(context).faint),
      children: [
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text('Nothing booked for today',
                  style: TextStyle(
                      fontFamily: kFontBody, fontSize: 11.5, color: Pal.of(context).faint)),
            ),
          )
        else
          for (final r in rows.take(6))
            ListRow(
              head: r.name,
              rest: [if ((r.time ?? '').isNotEmpty) r.time!, if (r.guests > 0) '${r.guests} guests']
                  .join(' · '),
              trailing: r.status.isEmpty ? '' : r.status,
            ),
      ],
    );
  }

  Widget _openChecksCard() {
    final unpaid = _orders
        .where((o) => !o.isClosed && o.status.toLowerCase() != 'cancelled' && !o.isPaid)
        .take(6)
        .toList();
    return SectionCard(
      title: 'Checks on the Floor',
      trailing: TextButton(
        onPressed: () => widget.onNavigate?.call(NavKey.openChecks),
        style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 6)),
        child: const Text('View all'),
      ),
      children: [
        if (unpaid.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text('No open checks — floor is clear',
                  style: TextStyle(
                      fontFamily: kFontBody, fontSize: 11.5, color: Pal.of(context).faint)),
            ),
          )
        else
          for (final o in unpaid)
            ListRow(
              head: o.tableNum != null && o.tableNum!.isNotEmpty
                  ? 'Table ${o.tableNum}'
                  : shortId(o.id),
              rest: o.itemsRaw,
              trailing: money(o.total),
            ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Kitchen — head chef / assistant chef / barista
// ─────────────────────────────────────────────────────────────────────────────

class ChefDashboard extends StatefulWidget {
  final ValueChanged<NavKey>? onNavigate;
  const ChefDashboard({super.key, this.onNavigate});

  @override
  State<ChefDashboard> createState() => _ChefDashboardState();
}

class _ChefDashboardState extends State<ChefDashboard> {
  List<FufutOrder> _orders = [];
  bool _loading = true;
  Object? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 45), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final rows = await app.api.orders();
      if (!mounted) return;
      setState(() { _orders = rows; _loading = false; });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) {
        await app.sessionExpired();
        return;
      }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _orders.isEmpty) return const DashboardSkeleton();
    if (_error != null && _orders.isEmpty) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final pal = Pal.of(context);
    final today = _today();

    // The web head-chef branch — counters off today's real tickets only.
    bool isToday(FufutOrder o) => (o.created ?? '').startsWith(today);
    final todays = _orders.where(isToday).toList();
    final newCount = todays.where((o) => o.status.toLowerCase() == 'new').length;
    final inProgress =
        todays.where((o) => o.status.toLowerCase() == 'preparing').length;
    final ready = todays.where((o) => o.status.toLowerCase() == 'ready').length;
    final served = todays
        .where((o) => ['served', 'fulfilled', 'completed']
            .contains(o.status.toLowerCase()))
        .length;

    final live = _orders
        .where((o) => !o.isClosed && o.status.toLowerCase() != 'cancelled')
        .take(6)
        .toList();

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          _quickActions(),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: KpiCard(
                label: 'New Orders',
                value: '$newCount',
                icon: Icons.fiber_new,
                valueColor: newCount > 0 ? pal.info : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                label: 'In Progress',
                value: '$inProgress',
                icon: Icons.local_fire_department_outlined,
                valueColor: inProgress > 0 ? pal.warning : null,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: KpiCard(
                label: 'Ready to Serve',
                value: '$ready',
                icon: Icons.outbound,
                valueColor: ready > 0 ? pal.primary : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                label: 'Served Today',
                value: '$served',
                icon: Icons.check_circle_outline,
              ),
            ),
          ]),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Live Tickets',
            trailing: TextButton(
              onPressed: () => widget.onNavigate?.call(NavKey.kitchen),
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6)),
              child: const Text('Open board'),
            ),
            children: [
              if (live.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: Text('All quiet on the pass',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11.5,
                            color: pal.faint)),
                  ),
                )
              else
                for (final o in live)
                  ListRow(
                    head: shortId(o.id),
                    rest: [
                      if (o.tableNum != null && o.tableNum!.isNotEmpty)
                        'Table ${o.tableNum}'
                      else
                        o.customer ?? 'Walk-in',
                      o.itemsRaw,
                    ].join(' · '),
                    trailing: o.status,
                    trailingColor: _statusColor(o.status),
                  ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _quickActions() {
    void go(NavKey k) => widget.onNavigate?.call(k);
    final app = context.read<AppState>();
    final chef = app.roleKey == 'head-chef';
    return GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 0.95,
      children: [
        QuickAction(icon: Icons.restaurant, label: 'Kitchen', onTap: () => go(NavKey.kitchen)),
        QuickAction(icon: Icons.receipt_long, label: 'Orders', onTap: () => go(NavKey.orders)),
        if (chef)
          QuickAction(icon: Icons.delete_outline, label: 'Waste Log', onTap: () => go(NavKey.waste)),
        QuickAction(
            icon: Icons.schedule_outlined, label: 'Time Clock', onTap: () => go(NavKey.timeclock)),
      ],
    );
  }

  Color _statusColor(String status) {
    final pal = Pal.of(context);
    switch (status.toLowerCase()) {
      case 'new': return pal.info;
      case 'preparing': return pal.warning;
      case 'ready': return pal.primary;
      case 'cancelled': return pal.danger;
      default: return pal.success;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Cashier — sales tiles + live till float + bill requests
// ─────────────────────────────────────────────────────────────────────────────

class CashierDashboard extends StatefulWidget {
  final ValueChanged<NavKey>? onNavigate;
  const CashierDashboard({super.key, this.onNavigate});

  @override
  State<CashierDashboard> createState() => _CashierDashboardState();
}

class _CashierDashboardState extends State<CashierDashboard> {
  DashboardStats? _stats;
  CashDrawerState? _drawer;
  List<CafeTable> _tables = [];
  bool _loading = true;
  Object? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    // The web cashier dashboard polls every 30s; so does this one.
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        app.api.reportsDashboard(),
        app.api.cashdrawer(),
        app.api.tables(),
      ]);
      if (!mounted) return;
      setState(() {
        _stats = results[0] as DashboardStats;
        _drawer = results[1] as CashDrawerState;
        _tables = results[2] as List<CafeTable>;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) {
        await app.sessionExpired();
        return;
      }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  List<CafeTable> get _billRequests =>
      _tables.where((t) => t.billRequested).toList();

  @override
  Widget build(BuildContext context) {
    if (_loading && _stats == null) return const DashboardSkeleton();
    if (_error != null && _stats == null) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final app = context.read<AppState>();
    final s = _stats;
    final isManager = app.roleKey == 'manager';

    double cashTotal = 0, digitalTotal = 0;
    for (final p in s?.paymentMethods ?? const <PayMethod>[]) {
      final m = p.method.toLowerCase();
      if (m == 'cash') {
        cashTotal = p.total;
      } else if (['telebirr', 'cbe', 'bank', 'card', 'mobile'].contains(m)) {
        digitalTotal += p.total;
      }
    }

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          _quickActions(),
          const SizedBox(height: 12),
          _tillCard(),
          const SizedBox(height: 10),
          _billRequestsCard(isManager),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: KpiCard(
                label: 'Today Sales',
                value: money(s?.netSales ?? 0),
                icon: Icons.trending_up,
                sub: '${s?.orders ?? 0} orders',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                label: 'Cash Taken',
                value: money(cashTotal),
                icon: Icons.payments,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: KpiCard(
                label: 'Digital',
                value: money(digitalTotal),
                icon: Icons.phone_android,
                sub: 'telebirr · cbe · bank · card',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                label: 'Avg Order',
                value: money(s?.averageOrder ?? 0),
                icon: Icons.receipt_long,
                sub: 'tips ${money(s?.tips ?? 0)}',
              ),
            ),
          ]),
          const SizedBox(height: 10),
          _paymentMix(s),
        ],
      ),
    );
  }

  Widget _quickActions() {
    void go(NavKey k) => widget.onNavigate?.call(k);
    return GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 0.95,
      children: [
        QuickAction(icon: Icons.point_of_sale, label: 'Quick Sale', onTap: () => go(NavKey.menuView)),
        QuickAction(icon: Icons.payments, label: 'Till Mgmt', onTap: () => go(NavKey.cashdrawer)),
        QuickAction(icon: Icons.credit_card, label: 'Open Checks', onTap: () => go(NavKey.openChecks)),
        QuickAction(
            icon: Icons.insights_outlined, label: 'My Activity', onTap: () => go(NavKey.myActivity)),
      ],
    );
  }

  /// Live Till Float — the web dashboard's `.till-card`: open/closed dot,
  /// float, cash sales and what the drawer should count out to.
  Widget _tillCard() {
    final pal = Pal.of(context);
    final active = _drawer?.active;
    final open = active != null;
    return SectionCard(
      title: 'Live Till Float',
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: open ? pal.success : pal.faint),
        ),
        const SizedBox(width: 5),
        Text(open ? 'Drawer open' : 'Drawer closed',
            style: TextStyle(
                fontFamily: kFontBody,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: open ? pal.success : pal.faint)),
      ]),
      children: [
        Row(children: [
          Expanded(
            child: KpiCard(
              label: 'Float',
              value: money(active?.openingBal ?? 0),
              icon: Icons.account_balance_wallet_outlined,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: KpiCard(
              label: 'Cash Sales',
              value: money(active?.cashSales ?? 0),
              icon: Icons.point_of_sale,
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: KpiCard(
              label: 'Expected',
              value: money(active?.expected ?? 0),
              icon: Icons.fact_check_outlined,
              sub: 'float + cash sales + paid in − paid out',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  height: 36,
                  child: FilledButton.icon(
                    onPressed: () => widget.onNavigate?.call(NavKey.cashdrawer),
                    icon: const Icon(Icons.payments_outlined, size: 16),
                    label: const Text('Count & Close',
                        style: TextStyle(fontSize: 11.5)),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 36,
                  child: OutlinedButton.icon(
                    onPressed: () => widget.onNavigate?.call(NavKey.cashdrawer),
                    icon: const Icon(Icons.list_alt, size: 16),
                    label: const Text('Till Mgmt', style: TextStyle(fontSize: 11.5)),
                  ),
                ),
              ],
            ),
          ),
        ]),
      ],
    );
  }

  /// Bill Requests — tables where the party asked for the bill. The waiter
  /// stamps the table; this card is where the cashier sees it.
  Widget _billRequestsCard(bool isManager) {
    final pal = Pal.of(context);
    final rows = _billRequests;
    if (rows.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: 'Bill Requests',
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
            color: pal.dangerBg, borderRadius: BorderRadius.circular(99)),
        child: Text('${rows.length}',
            style: TextStyle(
                fontFamily: kFontMono,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: pal.danger)),
      ),
      children: [
        for (final t in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.notifications_active,
                    size: 15, color: pal.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(TextSpan(
                    text: 'Table ${t.number}',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: pal.heading),
                    children: [
                      TextSpan(
                          text: '  ·  asked ${timeAgo(t.billRequestedAt)}',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 11,
                              color: pal.muted)),
                    ],
                  )),
                ),
                SizedBox(
                  height: 30,
                  child: FilledButton.tonal(
                    onPressed: () =>
                        widget.onNavigate?.call(NavKey.openChecks),
                    style: FilledButton.styleFrom(
                        textStyle: const TextStyle(fontSize: 11)),
                    child: const Text('Settle'),
                  ),
                ),
                if (isManager) ...[
                  const SizedBox(width: 6),
                  SizedBox(
                    height: 30,
                    child: OutlinedButton(
                      onPressed: () async {
                        final app = context.read<AppState>();
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          await app.api.cancelBillRequest(t.id);
                          showInfoOn(messenger,
                              'Bill request for table ${t.number} dismissed');
                          await _load(quiet: true);
                        } catch (e) {
                          showErrorOn(messenger, e);
                        }
                      },
                      style: OutlinedButton.styleFrom(
                          textStyle: const TextStyle(fontSize: 11)),
                      child: const Text('Dismiss'),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _paymentMix(DashboardStats? s) {
    if (s == null || s.paymentMethods.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: 'Payment Mix',
      trailing: Text('${s.orders} orders',
          style: TextStyle(
              fontFamily: kFontMono,
              fontSize: 10.5,
              color: Pal.of(context).faint)),
      children: [
        for (final p in s.paymentMethods.take(6))
          ListRow(
            head: _methodLabel(p.method),
            rest: '${p.count}×',
            trailing: money(p.total),
          ),
      ],
    );
  }

  static String _methodLabel(String m) {
    switch (m.toLowerCase()) {
      case 'cash': return 'Cash';
      case 'card': return 'Card';
      case 'mobile': return 'Mobile';
      case 'telebirr': return 'Telebirr';
      case 'cbe': return 'CBE Birr';
      case 'bank': return 'Bank';
      default: return m.isEmpty ? 'Other' : m;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Delivery staff
// ─────────────────────────────────────────────────────────────────────────────

class DriverDashboard extends StatefulWidget {
  final ValueChanged<NavKey>? onNavigate;
  const DriverDashboard({super.key, this.onNavigate});

  @override
  State<DriverDashboard> createState() => _DriverDashboardState();
}

class _DriverDashboardState extends State<DriverDashboard> {
  List<DeliveryJob> _jobs = [];
  bool _loading = true;
  Object? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 45), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final rows = await app.api.deliveries();
      if (!mounted) return;
      setState(() { _jobs = rows; _loading = false; });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) {
        await app.sessionExpired();
        return;
      }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _jobs.isEmpty) return const DashboardSkeleton();
    if (_error != null && _jobs.isEmpty) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final pal = Pal.of(context);

    // The web delivery-staff branch. Statuses arrive dash-normalized.
    const pickup = {'new', 'confirmed', 'preparing', 'ready', 'assigned'};
    const transit = {'picked-up', 'out-for-delivery'};
    final today = _today();
    final pending = _jobs.where((j) => pickup.contains(j.status)).length;
    final inTransit = _jobs.where((j) => transit.contains(j.status)).length;
    final deliveredToday = _jobs
        .where((j) =>
            j.status == 'delivered' && (j.created ?? '').startsWith(today))
        .length;
    final active = _jobs
        .where((j) => pickup.contains(j.status) || transit.contains(j.status))
        .take(6)
        .toList();

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.95,
            children: [
              QuickAction(
                  icon: Icons.local_shipping,
                  label: 'Delivery Run',
                  onTap: () => widget.onNavigate?.call(NavKey.delivery)),
              QuickAction(
                  icon: Icons.schedule_outlined,
                  label: 'Time Clock',
                  onTap: () => widget.onNavigate?.call(NavKey.timeclock)),
            ],
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: KpiCard(
                label: 'Pending Pickups',
                value: '$pending',
                icon: Icons.takeout_dining_outlined,
                valueColor: pending > 0 ? pal.warning : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                label: 'In Transit',
                value: '$inTransit',
                icon: Icons.route_outlined,
                valueColor: inTransit > 0 ? pal.info : null,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: KpiCard(
                label: 'Delivered Today',
                value: '$deliveredToday',
                icon: Icons.check_circle_outline,
                valueColor: deliveredToday > 0 ? pal.success : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                label: 'Total Runs',
                value: '${_jobs.length}',
                icon: Icons.local_shipping_outlined,
              ),
            ),
          ]),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Active Runs',
            trailing: TextButton(
              onPressed: () => widget.onNavigate?.call(NavKey.delivery),
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6)),
              child: const Text('Open run list'),
            ),
            children: [
              if (active.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: Text('No active deliveries',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11.5,
                            color: pal.faint)),
                  ),
                )
              else
                for (final j in active)
                  ListRow(
                    head: j.customer ?? 'Customer',
                    rest: [
                      if ((j.address ?? '').isNotEmpty) j.address!,
                      if (j.total > 0) money(j.total),
                    ].join(' · '),
                    trailing: j.status.replaceAll('-', ' '),
                  ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Cleaner
// ─────────────────────────────────────────────────────────────────────────────

class CleanerDashboard extends StatefulWidget {
  final ValueChanged<NavKey>? onNavigate;
  const CleanerDashboard({super.key, this.onNavigate});

  @override
  State<CleanerDashboard> createState() => _CleanerDashboardState();
}

class _CleanerDashboardState extends State<CleanerDashboard> {
  List<CafeTable> _tables = [];
  List<WasteEntry> _waste = [];
  bool _loading = true;
  Object? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(minutes: 1), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        app.api.tables(),
        app.api.wasteLog(),
      ]);
      if (!mounted) return;
      setState(() {
        _tables = results[0] as List<CafeTable>;
        _waste = results[1] as List<WasteEntry>;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) {
        await app.sessionExpired();
        return;
      }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _tables.isEmpty && _waste.isEmpty) {
      return const DashboardSkeleton();
    }
    if (_error != null && _tables.isEmpty && _waste.isEmpty) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final pal = Pal.of(context);
    final today = _today();

    // The web cleaner branch.
    final toClean = _tables.where((t) => t.status == 'cleaning').length;
    final occupied = _tables.where((t) => t.status == 'occupied').length;
    final todaysWaste = _waste
        .where((w) => (w.date ?? '').startsWith(today))
        .toList();
    final wasteCost =
        todaysWaste.fold<double>(0, (s, w) => s + w.cost);
    final last = _waste.isEmpty ? null : _waste.first;

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.95,
            children: [
              QuickAction(
                  icon: Icons.delete_outline,
                  label: 'Waste Log',
                  onTap: () => widget.onNavigate?.call(NavKey.waste)),
              QuickAction(
                  icon: Icons.schedule_outlined,
                  label: 'Time Clock',
                  onTap: () => widget.onNavigate?.call(NavKey.timeclock)),
            ],
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: KpiCard(
                label: 'Tables to Clean',
                value: '$toClean',
                icon: Icons.cleaning_services_outlined,
                valueColor: toClean > 0 ? pal.warning : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                label: 'Occupied Tables',
                value: '$occupied',
                icon: Icons.table_restaurant_outlined,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: KpiCard(
                label: 'Waste Today',
                value: money(wasteCost),
                icon: Icons.delete_outline,
                sub: '${todaysWaste.length} entries',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                label: 'Last Entry',
                value: last == null ? '—' : timeAgo(last.date ?? last.loggedBy),
                icon: Icons.history,
                sub: last?.item,
              ),
            ),
          ]),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Waste Logged Today',
            children: [
              if (todaysWaste.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: Text('Nothing wasted today — spotless',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11.5,
                            color: pal.faint)),
                  ),
                )
              else
                for (final w in todaysWaste.take(6))
                  ListRow(
                    head: w.item,
                    rest: w.reason,
                    trailing: money(w.cost),
                  ),
            ],
          ),
        ],
      ),
    );
  }
}
