/// P&L — the web `PnLView.vue`: profit & loss over a date range. Revenue
/// (net of tips) against expenses, the 30-day rev-vs-expense picture, the
/// expense breakdown and the recent ledgers on both sides.
///
/// Tier-2: orders + expenses arrive in one screen-scoped FutureProvider;
/// the date range below is applied in the UI, so the fetch itself is
/// unfiltered (same as the old _load). The session is READ inside the
/// provider, never watched (the fetch must not rebuild on its own echo).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/backoffice.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

final pnlProvider = FutureProvider<
    ({List<FufutOrder> orders, List<Expense> expenses})>((ref) async {
  final app = ref.read(appStateProvider);
  try {
    // Future.wait: every request keeps a listener even when a sibling
    // fails first — sequential awaits used to strand the losers as
    // unhandled async errors.
    final results =
        await Future.wait<dynamic>([app.api.orders(), app.api.expenses()]);
    return (
      orders: results[0] as List<FufutOrder>,
      expenses: results[1] as List<Expense>,
    );
  } on ApiError catch (e) {
    if (e.isAuthError) await app.sessionExpired();
    rethrow;
  }
});

class PnlScreen extends ConsumerStatefulWidget {
  const PnlScreen({super.key});

  @override
  ConsumerState<PnlScreen> createState() => _PnlScreenState();
}

class _PnlScreenState extends ConsumerState<PnlScreen> {
  String _from = '';
  String _to = '';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateRangeRow.fmt(now.add(const Duration(days: -29)));
    _to = DateRangeRow.fmt(now);
  }

  void _reload() => ref.invalidate(pnlProvider);

  bool _inRange(String? stamp) {
    final d = dayKey(stamp);
    if (d.length < 10) return false;
    if (_from.isNotEmpty && d.compareTo(_from) < 0) return false;
    if (_to.isNotEmpty && d.compareTo(_to) > 0) return false;
    return true;
  }

  List<FufutOrder> _ordersInRange(List<FufutOrder> orders) =>
      orders.where((o) {
        final s = o.status.toLowerCase();
        return s != 'cancelled' && s != 'voided' && _inRange(o.created);
      }).toList();

  List<Expense> _expensesInRange(List<Expense> expenses) =>
      expenses.where((e) => _inRange(e.date)).toList();

  @override
  Widget build(BuildContext context) {
    final dataAsync = ref.watch(pnlProvider);
    final allOrders = dataAsync.value?.orders ?? const <FufutOrder>[];
    final allExpenses = dataAsync.value?.expenses ?? const <Expense>[];
    if (dataAsync.isLoading && allOrders.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (dataAsync.hasError && allOrders.isEmpty) {
      return LoadError(error: dataAsync.error!, onRetry: _reload);
    }
    final pal = Pal.of(context);
    final orders = _ordersInRange(allOrders);
    final expenses = _expensesInRange(allExpenses);
    final revenue = orders.fold<double>(0, (s, o) => s + (o.total - o.tip));
    final expenseTotal = expenses.fold<double>(0, (s, e) => s + e.amount);
    final net = revenue - expenseTotal;

    // 30-day rev-vs-expense pairs (the web line chart, as paired bars).
    final days = <String>[];
    {
      final now = DateTime.now();
      for (var i = 29; i >= 0; i--) {
        days.add(DateRangeRow.fmt(now.add(Duration(days: -i))));
      }
    }
    double revFor(String d) {
      final t = orders
          .where((o) => dayKey(o.created) == d)
          .fold<double>(0, (s, o) => s + (o.total - o.tip));
      return t;
    }
    double expFor(String d) => expenses
        .where((e) => dayKey(e.date) == d)
        .fold<double>(0, (s, e) => s + e.amount);

    final byCat = <String, double>{};
    for (final e in expenses) {
      byCat[e.category] = (byCat[e.category] ?? 0) + e.amount;
    }
    final catEntries = byCat.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          DateRangeRow(
              from: _from, to: _to,
              onFrom: (v) => setState(() => _from = v),
              onTo: (v) => setState(() => _to = v)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: KpiCard(label: 'Revenue',
                    value: money(revenue),
                    valueColor: pal.success,
                    icon: Icons.trending_up_outlined)),
            const SizedBox(width: 8),
            Expanded(
                child: KpiCard(label: 'Expenses',
                    value: money(expenseTotal),
                    valueColor: pal.warning,
                    icon: Icons.account_balance_wallet_outlined)),
          ]),
          const SizedBox(height: 8),
          KpiCard(
              label: 'Net (${_netLabel(orders.length, expenses.length)})',
              value: money(net),
              valueColor: net >= 0 ? pal.success : pal.danger,
              icon: Icons.savings_outlined,
              sub: net >= 0 ? 'In the black' : 'Spending past revenue'),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Revenue vs expenses — 30 days',
            children: [
              VBarChart(
                height: 110,
                bars: [
                  for (final d in days)
                    VBar(d.substring(5), revFor(d) - expFor(d),
                        color: revFor(d) - expFor(d) >= 0
                            ? pal.success
                            : pal.danger),
                ],
              ),
              const SizedBox(height: 4),
              VBarLabels(labels: [
                for (var i = 0; i < days.length; i++)
                  i % 5 == 0 ? days[i].substring(5) : ''
              ]),
              const SizedBox(height: 6),
              Text('Daily net (revenue − expenses); bars below the line are loss days.',
                  style: TextStyle(
                      fontFamily: kFontBody, fontSize: 10, color: pal.faint)),
            ],
          ),
          const SizedBox(height: 10),
          SectionCard(
            title: 'Expense breakdown',
            children: [
              DonutChart(
                slices: [
                  for (final e in catEntries) DonutSlice(e.key, e.value),
                ],
                centerLabel: 'Expenses',
                centerValue: moneyGroup(expenseTotal),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SectionCard(
            title: 'Recent orders',
            children: [
              for (final o in orders.take(8))
                ListRow(
                    head: '#${shortId(o.id)}',
                    rest:
                        '${o.customer ?? 'Walk-in'}${o.tableNum != null ? ' · T${o.tableNum}' : ''}',
                    trailing: money(o.total - o.tip)),
              if (orders.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Center(
                      child: Text('No orders in range',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 11.5, color: pal.faint))),
                ),
            ],
          ),
          const SizedBox(height: 10),
          SectionCard(
            title: 'Recent expenses',
            children: [
              for (final e in expenses.take(8))
                ListRow(
                    head: e.description.isEmpty ? e.category : e.description,
                    rest: '${e.category} · ${dayKey(e.date)}',
                    trailing: money(e.amount)),
              if (expenses.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Center(
                      child: Text('No expenses in range',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 11.5, color: pal.faint))),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _netLabel(int o, int e) => '$o orders · $e expenses';
}
