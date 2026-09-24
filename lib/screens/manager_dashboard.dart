/// Manager dashboard — the web POS `DashboardView.vue`, native.
///
/// Greeting, quick actions, the day's KPIs from `GET /api/reports/dashboard`,
/// payment mix, recent orders and the operations counters. Refreshes on pull
/// and on a 60s timer, like the web's poll.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/roles.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

class ManagerDashboard extends ConsumerStatefulWidget {
  /// Lets quick actions jump to other screens of the shell.
  final ValueChanged<NavKey>? onNavigate;

  const ManagerDashboard({super.key, this.onNavigate});

  @override
  ConsumerState<ManagerDashboard> createState() => _ManagerDashboardState();
}

class _ManagerDashboardState extends ConsumerState<ManagerDashboard> {
  DashboardStats? _stats;
  List<FufutOrder> _recent = [];
  int _openChecks = 0;
  bool _loading = true;
  String _period = 'day';
  Object? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    // The web dashboard polls; sixty seconds keeps a tablet honest without
    // hammering the Worker.
    _poll = Timer.periodic(const Duration(minutes: 1), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final app = ref.read(appStateProvider);
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        app.api.reportsDashboard(period: _period),
        app.api.orders(),
      ]);
      if (!mounted) return;
      final all = results[1] as List<FufutOrder>;
      setState(() {
        _stats = results[0] as DashboardStats;
        _recent = all.take(6).toList();
        _openChecks = all.where((o) => !o.isClosed && !o.isPaid).length;
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

  Future<void> _refresh() async {
    await _load(quiet: true);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _stats == null) return const DashboardSkeleton();
    if (_error != null && _stats == null) {
      return LoadError(error: _error!, onRetry: _refresh);
    }
    final s = _stats;
    return RefreshIndicator(
      onRefresh: _refresh,
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
            _kpiGrid(s),
            const SizedBox(height: 10),
            _orderMix(s),
            const SizedBox(height: 10),
            _payMix(s),
            const SizedBox(height: 10),
            _opsCard(s),
            const SizedBox(height: 10),
          ],
          _recentOrders(),
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
                _load(quiet: true);
              },
            ),
          ),
      ],
    );
  }

  Widget _kpiGrid(DashboardStats s) {
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
              value: '$_openChecks',
              icon: Icons.credit_card,
              valueColor: _openChecks > 0 ? pal.warning : null,
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

  Widget _recentOrders() {
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
        if (_recent.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: Text('No orders yet',
                  style: TextStyle(
                      fontFamily: kFontBody, fontSize: 11.5, color: pal.faint)),
            ),
          )
        else
          for (final o in _recent)
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
