/// Manager dashboard — the web POS `DashboardView.vue`, native.
///
/// Greeting, quick actions, the day's KPIs from `GET /api/reports/dashboard`,
/// payment mix, recent orders and the operations counters. Refreshes on pull
/// and on the shared minute clock, like the web's poll.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/clock.dart';
import '../state/roles.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

/// One dashboard fetch for a period: the report plus the order list the
/// recent-orders card and the open-checks counter derive from.
final managerDashboardProvider = FutureProvider.family<
    ({DashboardStats stats, List<FufutOrder> recent, int openChecks}), String>(
  (ref, period) async {
    // Read, never watch: the fetch must not rebuild on its own session echo.
    final app = ref.read(appStateProvider);
    try {
      final results = await Future.wait([
        app.api.reportsDashboard(period: period),
        app.api.orders(),
      ]);
      final all = results[1] as List<FufutOrder>;
      return (
        stats: results[0] as DashboardStats,
        recent: all.take(6).toList(),
        openChecks: all.where((o) => !o.isClosed && !o.isPaid).length,
      );
    } on ApiError catch (e) {
      if (e.isAuthError) await app.sessionExpired();
      rethrow;
    }
  },
);

class ManagerDashboard extends ConsumerStatefulWidget {
  /// Lets quick actions jump to other screens of the shell.
  final ValueChanged<NavKey>? onNavigate;

  const ManagerDashboard({super.key, this.onNavigate});

  @override
  ConsumerState<ManagerDashboard> createState() => _ManagerDashboardState();
}

class _ManagerDashboardState extends ConsumerState<ManagerDashboard> {
  String _period = 'day';

  void _reload() => ref.invalidate(managerDashboardProvider(_period));

  @override
  Widget build(BuildContext context) {
    // The web dashboard polls; the shared minute clock keeps a tablet honest
    // without hammering the Worker.
    ref.listen(minuteClockProvider, (_, __) => _reload());
    final dashAsync = ref.watch(managerDashboardProvider(_period));
    final data = dashAsync.value;
    if (dashAsync.isLoading && data == null) return const DashboardSkeleton();
    if (dashAsync.hasError && data == null) {
      return LoadError(error: dashAsync.error!, onRetry: _reload);
    }
    final s = data?.stats;
    final recent = data?.recent ?? const <FufutOrder>[];
    final openChecks = data?.openChecks ?? 0;
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          _quickActions(),
          const SizedBox(height: 12),
          _periodChips(),
          const SizedBox(height: 10),
          if (s != null) ...[
            _kpiGrid(s, openChecks),
            const SizedBox(height: 10),
            _orderMix(s),
            const SizedBox(height: 10),
            _payMix(s),
            const SizedBox(height: 10),
            _opsCard(s),
            const SizedBox(height: 10),
          ],
          _recentOrders(recent),
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

  Widget _periodChips() {
    final pal = Pal.of(context);
    return Row(
      children: [
        for (final p in const [('day', 'Today'), ('week', '7 days'), ('month', '30 days')])
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text(p.$2),
              selected: _period == p.$1,
              labelStyle: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _period == p.$1 ? Colors.white : pal.body),
              selectedColor: pal.primary,
              backgroundColor: pal.sunken,
              side: BorderSide(color: _period == p.$1 ? pal.primary : pal.border),
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              onSelected: (_) {
                setState(() => _period = p.$1);
              },
            ),
          ),
      ],
    );
  }

  Widget _kpiGrid(DashboardStats s, int openChecks) {
    final pal = Pal.of(context);
    return Column(
      children: [
        Row(children: [
          Expanded(
            child: KpiCard(
              label: 'Net Sales',
              value: money(s.netSales),
              icon: Icons.trending_up,
              sub: 'tips ${money(s.tips)}',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: KpiCard(
              label: 'Orders',
              value: '${s.orders}',
              icon: Icons.receipt_long,
              sub: 'avg ${money(s.averageOrder)}',
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: KpiCard(
              label: 'Open Checks',
              value: '$openChecks',
              icon: Icons.credit_card,
              valueColor: openChecks > 0 ? pal.warning : null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: KpiCard(
              label: 'Gross of Expenses',
              value: money(s.grossOfExpenses),
              icon: Icons.account_balance_wallet_outlined,
              valueColor: s.grossOfExpenses < 0 ? pal.danger : pal.success,
              sub: 'expenses ${money(s.expenses)}',
            ),
          ),
        ]),
      ],
    );
  }

  Widget _orderMix(DashboardStats s) {
    return SectionCard(title: 'Order Mix', children: [
      ListRow(head: 'Dine-in', trailing: '${s.dineInOrders}'),
      ListRow(head: 'Takeaway', trailing: '${s.takeawayOrders}'),
      ListRow(head: 'Delivery', trailing: '${s.deliveryOrders}'),
      ListRow(head: 'Discounts', trailing: money(s.discounts)),
    ]);
  }

  Widget _payMix(DashboardStats s) {
    if (s.paymentMethods.isEmpty) {
      return const SizedBox.shrink();
    }
    return SectionCard(title: 'Payments', children: [
      for (final p in s.paymentMethods.take(5))
        ListRow(head: _methodLabel(p.method),
            rest: '${p.count}×', trailing: money(p.total)),
    ]);
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

  Widget _opsCard(DashboardStats s) {
    final pal = Pal.of(context);
    if (s.lowStockItems == 0 &&
        s.pendingKitchen == 0 &&
        s.pendingDeliveries == 0) {
      return const SizedBox.shrink();
    }
    return SectionCard(
      title: 'Needs Attention',
      children: [
        if (s.lowStockItems > 0)
          ListRow(
            head: 'Low stock items',
            trailing: '${s.lowStockItems}',
            trailingColor: pal.danger,
          ),
        if (s.pendingKitchen > 0)
          ListRow(
            head: 'Pending kitchen tickets',
            trailing: '${s.pendingKitchen}',
            trailingColor: pal.warning,
          ),
        if (s.pendingDeliveries > 0)
          ListRow(
            head: 'Pending deliveries',
            trailing: '${s.pendingDeliveries}',
            trailingColor: pal.info,
          ),
      ],
    );
  }

  Widget _recentOrders(List<FufutOrder> recent) {
    final pal = Pal.of(context);
    return SectionCard(
      title: 'Recent Orders',
      trailing: TextButton(
        onPressed: () => widget.onNavigate?.call(NavKey.orders),
        style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 6)),
        child: const Text('View all'),
      ),
      children: [
        if (recent.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: Text('No orders yet',
                  style: TextStyle(
                      fontFamily: kFontBody, fontSize: 11.5, color: pal.faint)),
            ),
          )
        else
          for (final o in recent)
            ListRow(
              head: '${shortId(o.id)} · ${o.customer ?? 'Walk-in'}',
              rest: o.itemsRaw.isEmpty ? null : o.itemsRaw,
              trailing: '${money(o.total)}  ${o.status}',
              trailingColor: _statusColor(o.status),
            ),
      ],
    );
  }

  Color _statusColor(String status) {
    final pal = Pal.of(context);
    switch (status.toLowerCase()) {
      case 'new': return pal.info;
      case 'preparing': case 'pending': return pal.warning;
      case 'ready': return pal.primary;
      case 'cancelled': return pal.danger;
      default: return pal.success;
    }
  }
}
