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
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../api/api_client.dart';
import '../state/app_state.dart';
import '../state/app_time.dart' show timeAgo, todayKey;
import '../state/catalog_providers.dart';
import '../state/clock.dart';
import '../state/live_feeds.dart';
import '../state/roles.dart';
import 'cashdrawer_screen.dart' show cashDrawerFeedProvider;
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';
import 'manager_dashboard.dart';

/// Every transfer still sitting at 'recorded' — the guest says the money is
/// sent; the till has not confirmed it. The cashier's verify queue: check
/// the telebirr / bank app, match the reference, tap Verify. Refreshed by
/// pull-to-refresh and after every verify (the server's SSE does not push
/// payment rows, so this stays a plain FutureProvider).
final paymentsToVerifyProvider =
    FutureProvider<List<FufutPayment>>((ref) async {
  final app = ref.read(appStateProvider);
  return app.api.paymentsToVerify();
});

/// The device-local `YYYY-MM-DD` stamp — delegated to app_time's
/// [todayKey]; "today" is computed the same way the web's `TODAY()` does.
String _today() => todayKey();

/// Entry point — dispatches on the signed-in role.
class RoleDashboard extends ConsumerWidget {
  final ValueChanged<NavKey>? onNavigate;

  const RoleDashboard({super.key, this.onNavigate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(appStateProvider).roleKey ?? '';
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

class WaiterDashboard extends ConsumerStatefulWidget {
  final ValueChanged<NavKey>? onNavigate;
  const WaiterDashboard({super.key, this.onNavigate});

  @override
  ConsumerState<WaiterDashboard> createState() => _WaiterDashboardState();
}

class _WaiterDashboardState extends ConsumerState<WaiterDashboard> {
  // Live feeds: the floor's orders (shared kitchen feed) and tables (shared
  // tables feed) — this dashboard used to poll three endpoints on its own
  // 45s clock; now the feeds push and only the reservations tile refreshes
  // on the shared minute cadence.
  List<FufutOrder> get _orders => ref.read(kitchenFeedProvider).orders;
  List<CafeTable> get _tables => ref.read(tablesFeedProvider).tables;
  List<Reservation> get _reservations =>
      ref.read(reservationsProvider).value ?? const <Reservation>[];

  void _refresh() {
    ref.invalidate(reservationsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final feedOrders = ref.watch(kitchenFeedProvider);
    final feedTables = ref.watch(tablesFeedProvider);
    final reservationsAsync = ref.watch(reservationsProvider);
    ref.listen(minuteClockProvider, (_, __) => _refresh());
    final loading = feedOrders.loading || feedTables.loading;
    final error = reservationsAsync.hasError
        ? reservationsAsync.error
        : (feedOrders.error ?? feedTables.error);
    if (loading && _orders.isEmpty && _tables.isEmpty) {
      return const DashboardSkeleton();
    }
    if (error != null && _orders.isEmpty) {
      return LoadError(error: error, onRetry: () => _refresh());
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
      onRefresh: () async => _refresh(),
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

class ChefDashboard extends ConsumerStatefulWidget {
  final ValueChanged<NavKey>? onNavigate;
  const ChefDashboard({super.key, this.onNavigate});

  @override
  ConsumerState<ChefDashboard> createState() => _ChefDashboardState();
}

class _ChefDashboardState extends ConsumerState<ChefDashboard> {
  // The shared kitchen feed IS the data — live push instead of the 45s poll.
  List<FufutOrder> get _orders => ref.read(kitchenFeedProvider).orders;

  Future<void> _refresh() async {} // live feed — nothing to invalidate

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(kitchenFeedProvider);
    final loading = feed.loading;
    final error = feed.error;
    if (loading && _orders.isEmpty) return const DashboardSkeleton();
    if (error != null && _orders.isEmpty) {
      return LoadError(error: error, onRetry: () {});
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
      onRefresh: () async => _refresh(),
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
    final app = ref.read(appStateProvider);
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
        // The floor the kitchen cooks for — table states and bill requests
        // live there. (Time Clock left with the HR screens in the
        // least-privilege pass; a dead button bounces off the nav guard.)
        QuickAction(icon: Icons.grid_view_outlined, label: 'Floor Plan', onTap: () => go(NavKey.tables)),
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

class CashierDashboard extends ConsumerStatefulWidget {
  final ValueChanged<NavKey>? onNavigate;
  const CashierDashboard({super.key, this.onNavigate});

  @override
  ConsumerState<CashierDashboard> createState() => _CashierDashboardState();
}

class _CashierDashboardState extends ConsumerState<CashierDashboard> {
  // The till feed (shared with the Cash Drawer screen) carries the stats
  // and the live float; the shared tables feed carries the bill requests.
  // The dashboard's own 30s poll is gone — the till feed already polls.
  DashboardStats? get _stats => ref.read(cashDrawerFeedProvider).stats;
  CashDrawerState? get _drawer => ref.read(cashDrawerFeedProvider).drawer;
  List<CafeTable> get _tables => ref.read(tablesFeedProvider).tables;

  List<CafeTable> get _billRequests =>
      _tables.where((t) => t.billRequested).toList();

  Future<void> _refresh() async =>
      ref.invalidate(cashDrawerFeedProvider);
  @override
  Widget build(BuildContext context) {
    final till = ref.watch(cashDrawerFeedProvider);
    final floor = ref.watch(tablesFeedProvider);
    final loading = till.loading || floor.loading;
    final error = till.error ?? floor.error;
    if (loading && _stats == null && _tables.isEmpty) {
      return const DashboardSkeleton();
    }
    if (error != null && _stats == null) {
      return LoadError(error: error, onRetry: () {});
    }
    final app = ref.read(appStateProvider);
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
      onRefresh: () async => _refresh(),
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
          _transfersToVerifyCard(),
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
        // The book (My Activity left with the HR screens; a dead tile just
        // bounces off the nav guard).
        QuickAction(
            icon: Icons.calendar_today_outlined,
            label: 'Reservations',
            onTap: () => go(NavKey.reservations)),
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
                          text:
                              '  ·  asked ${timeAgo(t.billRequestedAt)}${(t.billMethod ?? '').isNotEmpty ? '  ·  ${t.billMethod}' : ''}',
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
                        final app = ref.read(appStateProvider);
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          await app.api.cancelBillRequest(t.id);
                          showInfoOn(messenger,
                              'Bill request for table ${t.number} dismissed');
                          await ref.read(cashDrawerFeedProvider.notifier).refresh();
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

  /// The verify queue — every transfer recorded but not yet confirmed.
  /// This is the cashier's "did the money actually go through?" screen:
  /// open the telebirr / bank app, find the matching amount and reference,
  /// tap Verify. Verified here, the payment turns green on every device.
  Widget _transfersToVerifyCard() {
    final pal = Pal.of(context);
    final async = ref.watch(paymentsToVerifyProvider);
    final rows = async.value ?? const <FufutPayment>[];
    if (!async.hasValue || rows.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: 'Transfers to verify',
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
            color: pal.warningBg, borderRadius: BorderRadius.circular(99)),
        child: Text('${rows.length}',
            style: TextStyle(
                fontFamily: kFontMono,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: pal.warning)),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
              'The guest says the money is sent. Check your telebirr or bank '
              'app for the amount, then confirm it landed.',
              style: TextStyle(
                  fontFamily: kFontBody, fontSize: 11, color: pal.muted)),
        ),
        for (final p in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.phone_android_rounded,
                    size: 15, color: pal.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          text: '${_methodLabel(p.method)} · ${money(p.amount)}',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: pal.heading),
                          children: [
                            TextSpan(
                                text:
                                    '  ·  check ${p.orderId.length > 8 ? p.orderId.substring(0, 8) : p.orderId}',
                                style: TextStyle(
                                    fontFamily: kFontMono,
                                    fontSize: 10,
                                    color: pal.muted)),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if ((p.reference ?? '').isNotEmpty)
                        Text('Ref: ${p.reference}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 10.5,
                                color: pal.muted)),
                    ],
                  ),
                ),
                SizedBox(
                  height: 30,
                  child: AsyncButton(
                    onPressed: () async {
                      final app = ref.read(appStateProvider);
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        await app.api.verifyPayment(p.id);
                        ref.invalidate(paymentsToVerifyProvider);
                        showInfoOn(messenger,
                            'Confirmed — ${money(p.amount)} via ${_methodLabel(p.method)}');
                      } on ApiError catch (e) {
                        if (e.isAuthError) await app.sessionExpired();
                        showErrorOn(messenger, e);
                      } catch (e) {
                        showErrorOn(messenger, e);
                      }
                    },
                    icon: Icons.task_alt_rounded,
                    label: 'Verify',
                    height: 30,
                  ),
                ),
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

class DriverDashboard extends ConsumerStatefulWidget {
  final ValueChanged<NavKey>? onNavigate;
  const DriverDashboard({super.key, this.onNavigate});

  @override
  ConsumerState<DriverDashboard> createState() => _DriverDashboardState();
}

class _DriverDashboardState extends ConsumerState<DriverDashboard> {
  // The shared deliveries feed — one fetch for the dashboard AND the run
  // list screen. The 45s poll becomes a refresh on the shared minute clock.
  List<DeliveryJob> get _jobs =>
      ref.read(deliveriesProvider).value ?? const <DeliveryJob>[];

  Future<void> _refresh() async => ref.invalidate(deliveriesProvider);

  @override
  Widget build(BuildContext context) {
    final jobsAsync = ref.watch(deliveriesProvider);
    ref.listen(minuteClockProvider,
        (_, __) => ref.invalidate(deliveriesProvider));
    final loading = jobsAsync.isLoading;
    final error = jobsAsync.hasError ? jobsAsync.error : null;
    if (loading && _jobs.isEmpty) return const DashboardSkeleton();
    if (error != null && _jobs.isEmpty) {
      return LoadError(error: error, onRetry: () {});
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
      onRefresh: () async => _refresh(),
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

class CleanerDashboard extends ConsumerStatefulWidget {
  final ValueChanged<NavKey>? onNavigate;
  const CleanerDashboard({super.key, this.onNavigate});

  @override
  ConsumerState<CleanerDashboard> createState() => _CleanerDashboardState();
}

class _CleanerDashboardState extends ConsumerState<CleanerDashboard> {
  // Shared tables feed (live) + shared waste log (minute refresh) — the
  // dashboard and the Waste screen read the same providers now.
  List<CafeTable> get _tables => ref.read(tablesFeedProvider).tables;
  List<WasteEntry> get _waste =>
      ref.read(wasteLogProvider).value ?? const <WasteEntry>[];

  Future<void> _refresh() async => ref.invalidate(wasteLogProvider);

  @override
  Widget build(BuildContext context) {
    final floor = ref.watch(tablesFeedProvider);
    final wasteAsync = ref.watch(wasteLogProvider);
    ref.listen(minuteClockProvider,
        (_, __) => ref.invalidate(wasteLogProvider));
    final loading = floor.loading || wasteAsync.isLoading;
    final error = wasteAsync.hasError ? wasteAsync.error : null;
    if (loading && _tables.isEmpty && _waste.isEmpty) {
      return const DashboardSkeleton();
    }
    if (error != null && _tables.isEmpty && _waste.isEmpty) {
      return LoadError(error: error, onRetry: () {});
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
      onRefresh: () async => _refresh(),
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
