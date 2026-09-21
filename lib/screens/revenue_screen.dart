/// Revenue — the web `RevenueView.vue`: date-ranged revenue by day and
/// payment-method split. Tips are excluded — NET_SALES convention (the
/// guest's tip is the guest's money, never the restaurant's revenue).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/backoffice.dart';
import '../widgets/charts.dart';
import '../widgets/dashboard.dart';

class RevenueScreen extends StatefulWidget {
  const RevenueScreen({super.key});

  @override
  State<RevenueScreen> createState() => _RevenueScreenState();
}

class _RevenueScreenState extends State<RevenueScreen> {
  List<FufutOrder> _orders = [];
  bool _loading = true;
  Object? _error;
  String _from = '';
  String _to = '';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateRangeRow.fmt(now.add(const Duration(days: -13)));
    _to = DateRangeRow.fmt(now);
    _load();
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
      if (e.isAuthError) { await app.sessionExpired(); return; }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  /// Real orders only — the web `isRealOrder` (voided/cancelled rows are not
  /// revenue), then clipped to the range.
  List<FufutOrder> get _inRange {
    bool real(FufutOrder o) {
      final s = o.status.toLowerCase();
      return s != 'cancelled' && s != 'voided';
    }
    return _orders.where((o) {
      if (!real(o)) return false;
      final d = dayKey(o.created);
      if (d.length < 10) return false;
      if (_from.isNotEmpty && d.compareTo(_from) < 0) return false;
      if (_to.isNotEmpty && d.compareTo(_to) > 0) return false;
      return true;
    }).toList();
  }

  Map<String, double> get _byDay {
    final map = <String, double>{};
    for (final o in _inRange) {
      final d = dayKey(o.created);
      // Net of tip — the NET_SALES convention.
      map[d] = (map[d] ?? 0) + (o.total - o.tip);
    }
    return Map.fromEntries(
        map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  }

  Map<String, double> get _byMethod {
    final map = <String, double>{};
    for (final o in _inRange) {
      if (!o.isPaid) continue;
      // The web splits combined methods on '+' ("cash+card").
      for (final part in (o.payment ?? 'unpaid').split('+')) {
        final m = part.trim().toLowerCase();
        if (m == 'unpaid' || m.isEmpty) continue;
        map[m] = (map[m] ?? 0) + (o.total - o.tip) / (o.payment!.split('+').length);
      }
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _orders.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _orders.isEmpty) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final pal = Pal.of(context);
    final rows = _inRange;
    final byDay = _byDay;
    final byMethod = _byMethod;
    final revenue = rows.fold<double>(0, (s, o) => s + (o.total - o.tip));
    final avg = rows.isEmpty ? 0.0 : revenue / rows.length;
    final cash = byMethod['cash'] ?? 0;
    final digital = revenue - cash;

    final labels = byDay.keys.toList();
    final bars = [
      for (final d in labels)
        VBar(d.substring(5), byDay[d] ?? 0),
    ];

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
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
                    value: money(revenue), icon: Icons.trending_up_outlined)),
            const SizedBox(width: 8),
            Expanded(
                child: KpiCard(label: 'Orders',
                    value: '${rows.length}', icon: Icons.receipt_long_outlined)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: KpiCard(label: 'Avg order',
                    value: money(avg), icon: Icons.local_offer_outlined)),
            const SizedBox(width: 8),
            Expanded(
                child: KpiCard(
                    label: 'Cash · Digital',
                    value: '${moneyGroup(cash)} · ${moneyGroup(digital)}',
                    icon: Icons.payment_outlined)),
          ]),
          const SizedBox(height: 12),
          if (bars.isNotEmpty) ...[
            SectionCard(
              title: 'Daily revenue',
              trailing: Text('${labels.length} days',
                  style: TextStyle(
                      fontFamily: kFontMono, fontSize: 10.5, color: pal.faint)),
              children: [
                VBarChart(bars: bars),
                const SizedBox(height: 4),
                VBarLabels(labels: labels),
              ],
            ),
            const SizedBox(height: 10),
          ],
          SectionCard(
            title: 'Payment methods',
            trailing: Text('tips excluded',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 10, color: pal.faint)),
            children: [
              DonutChart(
                slices: [
                  for (final e in byMethod.entries) DonutSlice(e.key, e.value),
                ],
                centerLabel: 'Revenue',
                centerValue: moneyGroup(revenue),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SectionCard(
            title: 'By day',
            children: [
              for (final d in labels.reversed.take(20))
                ListRow(
                    head: d,
                    rest: '${_ordersFor(d)} orders',
                    trailing: money(byDay[d] ?? 0)),
            ],
          ),
        ],
      ),
    );
  }

  int _ordersFor(String day) => _inRange
      .where((o) => dayKey(o.created) == day)
      .length;
}
