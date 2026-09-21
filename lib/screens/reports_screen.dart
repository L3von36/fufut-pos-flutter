/// Reports — the accountant's home, from the web `ReportsView.vue` +
/// dashboard figures.
///
/// The financial picture, read-only: net sales, tips (reported as its own
/// line, never inside net), expenses, trading margin, payment mix and the
/// best-selling categories. Period chips switch Today / 7 days / 30 days —
/// the same windows `resolveWindow` defines server-side. Parity additions
/// from ReportsView: staff performance, time-to-table, and the CSV exports
/// (JSON export stays manager-only, exactly like the web).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../utils/csv.dart';
import '../widgets/backoffice.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  DashboardStats? _stats;
  bool _loading = true;
  String _period = 'day';
  Object? _error;
  List<Map<String, dynamic>> _staff = [];
  List<Map<String, dynamic>> _timing = [];
  int _timingDays = 7;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final s = await app.api.reportsDashboard(period: _period);
      final staff = await app.api.staffPerformance();
      final from = DateTime.now()
          .add(Duration(days: -_timingDays))
          .toUtc()
          .toIso8601String();
      final timing = await app.api.orderTiming(from);
      if (!mounted) return;
      setState(() {
        _stats = s; _staff = staff; _timing = timing; _loading = false;
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

  bool get _isManager => context.read<AppState>().roleKey == 'manager';

  Future<void> _exportCsv(String kind) async {
    final messenger = ScaffoldMessenger.of(context);
    final now = DateTime.now();
    String name;
    String text;
    switch (kind) {
      case 'today':
        final s = _stats;
        text = toCsv(['Metric', 'ETB'], [
          ['Orders', s?.orders ?? 0],
          ['Net sales', s?.netSales.toStringAsFixed(2) ?? '0'],
          ['Tips', s?.tips.toStringAsFixed(2) ?? '0'],
          ['Discounts', s?.discounts.toStringAsFixed(2) ?? '0'],
          ['Expenses', s?.expenses.toStringAsFixed(2) ?? '0'],
          ['Gross of expenses', s?.grossOfExpenses.toStringAsFixed(2) ?? '0'],
        ]);
        name = 'report-today-${DateRangeRow.fmt(now)}.csv';
        break;
      case 'staff':
        text = toCsv(['Staff', 'Orders', 'Net ETB', 'Tips ETB', 'Avg ETB'], [
          for (final row in _staff)
            [row['name'], row['ordersCount'] ?? 0,
             row['totalSales'] ?? 0, row['totalTips'] ?? 0,
             row['averageOrder'] ?? 0],
        ]);
        name = 'report-staff-${DateRangeRow.fmt(now)}.csv';
        break;
      default:
        text = toCsv(['Metric', 'ETB'], const []);
        name = 'report.csv';
    }
    final downloaded = await exportCsv(name, text);
    showInfoOn(messenger,
        downloaded ? '$name downloaded' : 'Copied to clipboard');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _stats == null) return const DashboardSkeleton();
    if (_error != null && _stats == null) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final s = _stats;
    final pal = Pal.of(context);

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final p in const [
                ('day', 'Today'),
                ('week', '7 days'),
                ('month', '30 days'),
              ])
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
                    side: BorderSide(
                        color: _period == p.$1 ? pal.primary : pal.border),
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) {
                      setState(() => _period = p.$1);
                      _load(quiet: true);
                    },
                  ),
                ),
            ],
          ),
          if (s != null) ...[
            const SizedBox(height: 10),
            // Export row — Today CSV for every granted role; All Data JSON
            // stays manager-only, exactly like the web ReportsView.
            Row(children: [
              RowAction('Today CSV', () => _exportCsv('today')),
              const SizedBox(width: 6),
              RowAction('Staff CSV', () => _exportCsv('staff')),
              const Spacer(),
              if (_isManager)
                RowAction('All Data JSON', () {}, color: pal.faint),
            ]),
            const SizedBox(height: 10),
            // The one rule every figure obeys: net sales is total − tip.
            SectionCard(
              title: 'Trading',
              children: [
                ListRow(head: 'Net sales', trailing: money(s.netSales)),
                ListRow(head: 'Tips (not revenue)', trailing: money(s.tips)),
                ListRow(head: 'Discounts', trailing: money(s.discounts)),
                ListRow(head: 'Expenses', trailing: money(s.expenses)),
                ListRow(
                  head: 'Gross of expenses',
                  trailing: money(s.grossOfExpenses),
                  trailingColor: s.grossOfExpenses >= 0 ? pal.success : pal.danger,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: KpiCard(
                  label: 'Orders',
                  value: '${s.orders}',
                  icon: Icons.receipt_long,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: KpiCard(
                  label: 'Avg order',
                  value: money(s.averageOrder),
                  icon: Icons.analytics_outlined,
                ),
              ),
            ]),
            const SizedBox(height: 10),
            if (s.paymentMethods.isNotEmpty) ...[
              SectionCard(
                title: 'Payment Methods',
                children: [
                  for (final p in s.paymentMethods)
                    ListRow(
                      head: _methodLabel(p.method),
                      rest: '${p.count}×',
                      trailing: money(p.total),
                    ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            if (s.byCategory.isNotEmpty)
              SectionCard(
                title: 'Sales by Category',
                children: [
                  for (final c in s.byCategory.take(8))
                    ListRow(
                      head: c.category,
                      rest: '${c.quantity} sold',
                      trailing: money(c.revenue),
                    ),
                ],
              ),
            const SizedBox(height: 10),
            if (_staff.isNotEmpty)
              SectionCard(
                title: 'Staff performance',
                children: [
                  for (final row in _staff.take(12))
                    ListRow(
                      head: '${row['name'] ?? '—'}',
                      rest: '${row['ordersCount'] ?? 0} orders · avg ${money(_d(row['averageOrder']))}',
                      trailing: money(_d(row['totalSales'])),
                    ),
                ],
              ),
            if (_staff.isNotEmpty) const SizedBox(height: 10),
            if (_timing.isNotEmpty)
              SectionCard(
                title: 'Time to table',
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  for (final d in const [1, 7, 30])
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: RowAction(
                          '${d}d',
                          () {
                            _timingDays = d;
                            _load(quiet: true);
                          },
                          color: _timingDays == d ? pal.primary : null),
                    ),
                ]),
                children: [
                  for (final row in _timing.take(10))
                    ListRow(
                      head: '${row['category'] ?? '—'}',
                      rest:
                          '${_d(row['served'])} served of ${row['sampled'] ?? 0} sampled'
                          ' · fastest ${_d(row['fastestMinutes']).toStringAsFixed(0)} min',
                      trailing:
                          '${_d(row['averageMinutes']).toStringAsFixed(0)} min avg',
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }

  static double _d(dynamic v) =>
      v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

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
