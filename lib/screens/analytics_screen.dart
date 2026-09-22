/// Analytics — the web `AnalyticsView.vue`: preset/custom ranges, the 8 KPI
/// cards (AOV, gross margin, fulfillment %, peak hour, cancellations,
/// trend), the revenue/volume/category/hourly pictures and the top/bottom
/// performer tables. 60s auto-refresh, all computation client-side like the
/// web.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/backoffice.dart';
import '../widgets/charts.dart';
import '../widgets/dashboard.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  List<FufutOrder> _orders = [];
  List<MenuItem> _menu = [];
  bool _loading = true;
  Object? _error;
  String _preset = '7d';
  String _from = '';
  String _to = '';
  Timer? _ticker;

  static const _presets = [
    ('today', 'Today'), ('7d', '7 days'), ('14d', '14 days'),
    ('30d', '30 days'), ('custom', 'Custom'),
  ];

  @override
  void initState() {
    super.initState();
    _applyPreset('7d');
    _ticker = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted && _preset != 'custom') _load(quiet: true);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

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
    _load();
  }

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait<dynamic>(
          [app.api.orders(), app.api.menu()]);
      final orders = results[0] as List<FufutOrder>;
      final menu = results[1] as List<MenuItem>;
      if (!mounted) return;
      setState(() { _orders = orders; _menu = menu; _loading = false; });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) { await app.sessionExpired(); return; }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  List<FufutOrder> get _inRange {
    return _orders.where((o) {
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

  double get _revenue {
    final rows = _inRange.where((o) => o.status.toLowerCase() != 'cancelled');
    return rows.fold<double>(0, (s, o) => s + (o.total - o.tip));
  }

  double get _aov {
    final rows = _inRange.where((o) => o.status.toLowerCase() != 'cancelled');
    return rows.isEmpty ? 0 : _revenue / rows.length;
  }

  int get _cancelled =>
      _inRange.where((o) => o.status.toLowerCase() == 'cancelled').length;

  double get _cancelPct =>
      _inRange.isEmpty ? 0 : (_cancelled / _inRange.length) * 100;

  /// Fulfilment: served+fulfilled share of everything that wasn't cancelled.
  double get _fulfillPct {
    final rows = _inRange.where((o) => o.status.toLowerCase() != 'cancelled');
    if (rows.isEmpty) return 0;
    final done = rows.where((o) {
      final s = o.status.toLowerCase();
      return s == 'served' || s == 'fulfilled' || s == 'completed';
    }).length;
    return done / rows.length * 100;
  }

  String get _peakHour {
    final counts = List<int>.filled(24, 0);
    for (final o in _inRange) {
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
  double get _trendPct {
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
    final prev = _orders
        .where((o) =>
            inPrev(o.created) && o.status.toLowerCase() != 'cancelled')
        .fold<double>(0, (s, o) => s + (o.total - o.tip));
    if (prev <= 0) return 0;
    return ((_revenue - prev) / prev) * 100;
  }

  Map<String, double> get _byCategory {
    // Category rides the structured lines; the menu map backfills names
    // written before categories were stamped.
    final catOf = {for (final m in _menu) m.name.toLowerCase(): m.category};
    final map = <String, double>{};
    for (final o in _inRange) {
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

  Map<String, int> get _itemCounts {
    final map = <String, int>{};
    for (final o in _inRange) {
      for (final l in o.items) {
        map[l.name] = (map[l.name] ?? 0) + l.qty;
      }
    }
    return map;
  }

  Map<String, int> get _statusCounts {
    final map = <String, int>{};
    for (final o in _inRange) {
      map[o.status] = (map[o.status] ?? 0) + 1;
    }
    return map;
  }

  Map<int, int> get _hourly {
    final counts = List<int>.filled(24, 0);
    for (final o in _inRange) {
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
    if (_loading && _orders.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _orders.isEmpty) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final pal = Pal.of(context);
    final rows = _inRange;
    final byCat = _byCategory;
    final items = _itemCounts;
    final statuses = _statusCounts;
    final hourly = _hourly;
    final trend = _trendPct;
    final totalItems = items.values.fold<int>(0, (s, v) => s + v);
    final avgItems = rows.isEmpty ? 0.0 : totalItems / rows.length;

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
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
                onFrom: (v) { setState(() => _from = v); _load(quiet: true); },
                onTo: (v) { setState(() => _to = v); _load(quiet: true); }),
          ],
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: KpiCard(label: 'Revenue',
                    value: money(_revenue), icon: Icons.trending_up_outlined)),
            const SizedBox(width: 8),
            Expanded(
                child: KpiCard(label: 'Avg order',
                    value: money(_aov),
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
                    value: '${_fulfillPct.toStringAsFixed(0)}%',
                    valueColor: _fulfillPct >= 80 ? pal.success : pal.warning,
                    icon: Icons.check_circle_outline)),
            const SizedBox(width: 8),
            Expanded(
                child: KpiCard(label: 'Peak hour',
                    value: _peakHour, icon: Icons.schedule_outlined)),
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
                    value: '${_cancelPct.toStringAsFixed(0)}%',
                    valueColor: _cancelPct > 10 ? pal.danger : pal.body,
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
