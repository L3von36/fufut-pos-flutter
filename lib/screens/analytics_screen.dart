/// Analytics — the web `AnalyticsView.vue`: preset/custom ranges, the 8 KPI
/// cards (AOV, gross margin, fulfillment %, peak hour, cancellations,
/// trend), the revenue/volume/category/hourly pictures and the top/bottom
/// performer tables. Minute-clock auto-refresh, all computation client-side
/// like the web.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/catalog_providers.dart' show menuProvider;
import '../state/clock.dart';
import '../theme.dart';
import '../widgets/backoffice.dart';
import '../widgets/charts.dart';
import '../widgets/dashboard.dart';

/// The order window analytics computes over. The date filters are applied
/// client-side (the endpoint takes none), so one unparameterized fetch
/// serves every preset; the menu for the category backfill comes from the
/// shared [menuProvider].
final analyticsOrdersProvider = FutureProvider<List<FufutOrder>>((ref) async {
  // Read, never watch: the fetch must not rebuild on its own session echo.
  final app = ref.read(appStateProvider);
  try {
    return await app.api.orders();
  } on ApiError catch (e) {
    if (e.isAuthError) await app.sessionExpired();
    rethrow;
  }
});

class AnalyticsScreen extends ConsumerStatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  ConsumerState<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends ConsumerState<AnalyticsScreen> {
  String _preset = '7d';
  String _from = '';
  String _to = '';

  static const _presets = [
    ('today', 'Today'), ('7d', '7 days'), ('14d', '14 days'),
    ('30d', '30 days'), ('custom', 'Custom'),
  ];

  @override
  void initState() {
    super.initState();
    _applyPreset('7d');
  }

  void _reload() => ref.invalidate(analyticsOrdersProvider);

  void _applyPreset(String p) {
    final now = DateTime.now();
    setState(() {
      _preset = p;
      switch (p) {
        case 'today':
          _from = DateRangeRow.fmt(now);
          _to = _from;
          break;
        case '30d':
          _from = DateRangeRow.fmt(now.add(const Duration(days: -29)));
          _to = DateRangeRow.fmt(now);
          break;
        case '14d':
          _from = DateRangeRow.fmt(now.add(const Duration(days: -13)));
          _to = DateRangeRow.fmt(now);
          break;
        case 'custom':
          break;
        default:
          _from = DateRangeRow.fmt(now.add(const Duration(days: -6)));
          _to = DateRangeRow.fmt(now);
      }
    });
  }

  List<FufutOrder> _inRange(List<FufutOrder> orders) {
    return orders.where((o) {
      final s = o.status.toLowerCase();
      if (s == 'voided') return false;
      final d = dayKey(o.created);
      if (d.length < 10) return false;
      if (_from.isNotEmpty && d.compareTo(_from) < 0) return false;
      if (_to.isNotEmpty && d.compareTo(_to) > 0) return false;
      return true;
    }).toList();
  }

  // ── KPI math (web AnalyticsView computed set) ────────────────────────────

  double _revenue(List<FufutOrder> inRange) {
    final rows = inRange.where((o) => o.status.toLowerCase() != 'cancelled');
    return rows.fold<double>(0, (s, o) => s + (o.total - o.tip));
  }

  double _aov(List<FufutOrder> inRange) {
    final rows = inRange.where((o) => o.status.toLowerCase() != 'cancelled');
    return rows.isEmpty ? 0 : _revenue(inRange) / rows.length;
  }

  int _cancelled(List<FufutOrder> inRange) =>
      inRange.where((o) => o.status.toLowerCase() == 'cancelled').length;

  double _cancelPct(List<FufutOrder> inRange) =>
      inRange.isEmpty ? 0 : (_cancelled(inRange) / inRange.length) * 100;

  /// Fulfilment: served+fulfilled share of everything that wasn't cancelled.
  double _fulfillPct(List<FufutOrder> inRange) {
    final rows = inRange.where((o) => o.status.toLowerCase() != 'cancelled');
    if (rows.isEmpty) return 0;
    final done = rows.where((o) {
      final s = o.status.toLowerCase();
      return s == 'served' || s == 'fulfilled' || s == 'completed';
    }).length;
    return done / rows.length * 100;
  }

  String _peakHour(List<FufutOrder> inRange) {
    final counts = List<int>.filled(24, 0);
    for (final o in inRange) {
      final t = o.created ?? '';
      if (t.length >= 13) {
        final h = int.tryParse(t.substring(11, 13));
        if (h != null && h >= 0 && h < 24) counts[h]++;
      }
    }
    var best = 0;
    for (var i = 1; i < 24; i++) {
      if (counts[i] > counts[best]) best = i;
    }
    if (counts[best] == 0) return '—';
    return '${best.toString().padLeft(2, '0')}:00';
  }

  /// Revenue vs the equal-length previous window.
  double _trendPct(List<FufutOrder> orders) {
    final fromD = DateTime.tryParse(_from);
    if (fromD == null) return 0;
    final span = DateTime.tryParse(_to)?.difference(fromD).inDays ?? 6;
    final prevTo = fromD.add(const Duration(days: -1));
    final prevFrom = prevTo.add(Duration(days: -(span < 0 ? 6 : span)));
    String f(DateTime d) => DateRangeRow.fmt(d);
    bool inPrev(String? stamp) {
      final d = dayKey(stamp);
      return d.compareTo(f(prevFrom)) >= 0 && d.compareTo(f(prevTo)) <= 0;
    }
    final prev = orders
        .where((o) =>
            inPrev(o.created) && o.status.toLowerCase() != 'cancelled')
        .fold<double>(0, (s, o) => s + (o.total - o.tip));
    if (prev <= 0) return 0;
    return ((_revenue(_inRange(orders)) - prev) / prev) * 100;
  }

  Map<String, double> _byCategory(
      List<FufutOrder> inRange, List<MenuItem> menu) {
    // Category rides the structured lines; the menu map backfills names
    // written before categories were stamped.
    final catOf = {for (final m in menu) m.name.toLowerCase(): m.category};
    final map = <String, double>{};
    for (final o in inRange) {
      if (o.status.toLowerCase() == 'cancelled') continue;
      final lines = o.items.isNotEmpty
          ? o.items
          : const <OrderItemLine>[];
      if (lines.isEmpty) continue;
      for (final l in lines) {
        final cat = l.course == 'main' && catOf[l.name.toLowerCase()] != null
            ? catOf[l.name.toLowerCase()]!
            : l.course;
        map[cat] = (map[cat] ?? 0) + l.lineTotal;
      }
    }
    return Map.fromEntries(
        map.entries.toList()..sort((a, b) => b.value.compareTo(a.value)));
  }

  Map<String, int> _itemCounts(List<FufutOrder> inRange) {
    final map = <String, int>{};
    for (final o in inRange) {
      for (final l in o.items) {
        map[l.name] = (map[l.name] ?? 0) + l.qty;
      }
    }
    return map;
  }

  Map<String, int> _statusCounts(List<FufutOrder> inRange) {
    final map = <String, int>{};
    for (final o in inRange) {
      map[o.status] = (map[o.status] ?? 0) + 1;
    }
    return map;
  }

  Map<int, int> _hourly(List<FufutOrder> inRange) {
    final counts = List<int>.filled(24, 0);
    for (final o in inRange) {
      final t = o.created ?? '';
      if (t.length >= 13) {
        final h = int.tryParse(t.substring(11, 13));
        if (h != null && h >= 0 && h < 24) counts[h]++;
      }
    }
    return counts.asMap();
  }

  @override
  Widget build(BuildContext context) {
    // The old 60s ticker refreshed the window; the minute clock does that
    // now, paused while a custom range is on screen — like before.
    ref.listen(minuteClockProvider, (_, __) {
      if (_preset != 'custom') ref.invalidate(analyticsOrdersProvider);
    });
    final ordersAsync = ref.watch(analyticsOrdersProvider);
    final menuAsync = ref.watch(menuProvider);
    final orders = ordersAsync.value ?? const <FufutOrder>[];
    final menu = menuAsync.value ?? const <MenuItem>[];
    if (ordersAsync.isLoading && orders.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (ordersAsync.hasError && orders.isEmpty) {
      return LoadError(error: ordersAsync.error!, onRetry: _reload);
    }
    final pal = Pal.of(context);
    final rows = _inRange(orders);
    final byCat = _byCategory(rows, menu);
    final items = _itemCounts(rows);
    final statuses = _statusCounts(rows);
    final hourly = _hourly(rows);
    final trend = _trendPct(orders);
    final revenue = _revenue(rows);
    final aov = _aov(rows);
    final fulfillPct = _fulfillPct(rows);
    final peakHour = _peakHour(rows);
    final cancelPct = _cancelPct(rows);
    final totalItems = items.values.fold<int>(0, (s, v) => s + v);
    final avgItems = rows.isEmpty ? 0.0 : totalItems / rows.length;

    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          ChipSelect(
            value: _preset,
            options: _presets,
            onChanged: _applyPreset,
          ),
          if (_preset == 'custom') ...[
            const SizedBox(height: 8),
            DateRangeRow(
                from: _from, to: _to,
                onFrom: (v) => setState(() => _from = v),
                onTo: (v) => setState(() => _to = v)),
          ],
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: KpiCard(label: 'Revenue',
                    value: money(revenue), icon: Icons.trending_up_outlined)),
            const SizedBox(width: 8),
            Expanded(
                child: KpiCard(label: 'Avg order',
                    value: money(aov),
                    sub: trend >= 0
                        ? '↑ ${trend.toStringAsFixed(0)}% vs prior'
                        : '↓ ${trend.abs().toStringAsFixed(0)}% vs prior',
                    valueColor: trend >= 0 ? pal.success : pal.danger,
                    icon: Icons.local_offer_outlined)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: KpiCard(label: 'Fulfillment',
                    value: '${fulfillPct.toStringAsFixed(0)}%',
                    valueColor: fulfillPct >= 80 ? pal.success : pal.warning,
                    icon: Icons.check_circle_outline)),
            const SizedBox(width: 8),
            Expanded(
                child: KpiCard(label: 'Peak hour',
                    value: peakHour, icon: Icons.schedule_outlined)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: KpiCard(label: 'Avg items / order',
                    value: avgItems.toStringAsFixed(1),
                    icon: Icons.format_list_numbered)),
            const SizedBox(width: 8),
            Expanded(
                child: KpiCard(label: 'Cancellation',
                    value: '${cancelPct.toStringAsFixed(0)}%',
                    valueColor: cancelPct > 10 ? pal.danger : pal.body,
                    icon: Icons.cancel_outlined)),
          ]),
          const SizedBox(height: 12),
          if (byCat.isNotEmpty) ...[
            SectionCard(
              title: 'Sales by category',
              children: [
                HBarChart(bars: [
                  for (final e in byCat.entries.take(7))
                    HBar(e.key, e.value),
                ], valueLabel: (v) => moneyGroup(v)),
              ],
            ),
            const SizedBox(height: 10),
          ],
          SectionCard(
            title: 'Orders by hour',
            children: [
              VBarChart(
                height: 84,
                bars: [
                  for (var h = 6; h <= 23; h++)
                    VBar(h.toString().padLeft(2, '0'),
                        (hourly[h] ?? 0).toDouble()),
                ],
              ),
              const SizedBox(height: 4),
              VBarLabels(labels: [
                for (var h = 6; h <= 23; h++)
                  h % 3 == 0 ? h.toString().padLeft(2, '0') : ''
              ]),
            ],
          ),
          const SizedBox(height: 10),
          if (statuses.isNotEmpty)
            SectionCard(
              title: 'Status distribution',
              children: [
                DonutChart(
                  slices: [
                    for (final e in statuses.entries)
                      DonutSlice(e.key, e.value.toDouble()),
                  ],
                  centerLabel: 'Orders',
                  centerValue: '${rows.length}',
                ),
              ],
            ),
          const SizedBox(height: 10),
          if (items.isNotEmpty) ...[
            SectionCard(
              title: 'Top performers',
              children: [
                HBarChart(bars: [
                  for (final e in (items.entries.toList()
                        ..sort((a, b) => b.value.compareTo(a.value)))
                      .take(6))
                    HBar(e.key, e.value.toDouble(), color: pal.success),
                ]),
              ],
            ),
            const SizedBox(height: 10),
            SectionCard(
              title: 'Bottom performers',
              children: [
                HBarChart(bars: [
                  for (final e in (items.entries.toList()
                        ..sort((a, b) => a.value.compareTo(b.value)))
                      .take(5))
                    HBar(e.key, e.value.toDouble(), color: pal.warning),
                ]),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
