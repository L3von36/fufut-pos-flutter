/// Reports — the accountant's home, from the web `ReportsView.vue` +
/// dashboard figures.
///
/// The financial picture, read-only: net sales, tips (reported as its own
/// line, never inside net), expenses, trading margin, payment mix and the
/// best-selling categories. Period chips switch Today / 7 days / 30 days —
/// the same windows `resolveWindow` defines server-side. Parity additions
/// from ReportsView: staff performance, time-to-table, and the CSV exports
/// (JSON export stays manager-only, exactly like the web).
///
/// Tier-2: the fetch lives in a screen-scoped FutureProvider keyed by the
/// period + timing window; the session is READ inside the provider, never
/// watched (the fetch must not rebuild on its own session echo).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../utils/csv.dart';
import '../widgets/backoffice.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

/// What reaches the server: the trading period and the time-to-table
/// sample window (staff performance is unfiltered).
typedef ReportsFilter = ({String period, int timingDays});

/// The dashboard figures, staff performance and the timing sample arrive
/// together — exactly like the old _load() trio.
typedef ReportsData = ({
  DashboardStats stats,
  List<Map<String, dynamic>> staff,
  List<Map<String, dynamic>> timing,
});

final reportsProvider =
    FutureProvider.family<ReportsData, ReportsFilter>((ref, f) async {
  final app = ref.read(appStateProvider);
  try {
    final stats = await app.api.reportsDashboard(period: f.period);
    final staff = await app.api.staffPerformance();
    final from = DateTime.now()
        .add(Duration(days: -f.timingDays))
        .toUtc()
        .toIso8601String();
    final timing = await app.api.orderTiming(from);
    return (stats: stats, staff: staff, timing: timing);
  } on ApiError catch (e) {
    if (e.isAuthError) await app.sessionExpired();
    rethrow;
  }
});

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  String _period = 'day';
  int _timingDays = 7;

  void _reload() =>
      ref.invalidate(reportsProvider((period: _period, timingDays: _timingDays)));

  bool get _isManager => ref.read(appStateProvider).roleKey == 'manager';

  Future<void> _exportCsv(String kind) async {
    final messenger = ScaffoldMessenger.of(context);
    final data = ref
        .read(reportsProvider((period: _period, timingDays: _timingDays)))
        .value;
    final stats = data?.stats;
    final staff = data?.staff ?? const <Map<String, dynamic>>[];
    final now = DateTime.now();
    String name;
    String text;
    switch (kind) {
      case 'today':
        final s = stats;
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
          for (final row in staff)
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
    final dataAsync = ref
        .watch(reportsProvider((period: _period, timingDays: _timingDays)));
    final data = dataAsync.value;
    final staff = data?.staff ?? const <Map<String, dynamic>>[];
    final timing = data?.timing ?? const <Map<String, dynamic>>[];
    if (dataAsync.isLoading && data == null) return const DashboardSkeleton();
    if (dataAsync.hasError && data == null) {
      return LoadError(error: dataAsync.error!, onRetry: _reload);
    }
    final s = data?.stats;
    final pal = Pal.of(context);

    return RefreshIndicator(
      onRefresh: () async => _reload(),
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
                      _reload();
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
            if (staff.isNotEmpty)
              SectionCard(
                title: 'Staff performance',
                children: [
                  for (final row in staff.take(12))
                    ListRow(
                      head: '${row['name'] ?? '—'}',
                      rest: '${row['ordersCount'] ?? 0} orders · avg ${money(_d(row['averageOrder']))}',
                      trailing: money(_d(row['totalSales'])),
                    ),
                ],
              ),
            if (staff.isNotEmpty) const SizedBox(height: 10),
            if (timing.isNotEmpty)
              SectionCard(
                title: 'Time to table',
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  for (final d in const [1, 7, 30])
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: RowAction(
                          '${d}d',
                          () {
                            setState(() => _timingDays = d);
                            _reload();
                          },
                          color: _timingDays == d ? pal.primary : null),
                    ),
                ]),
                children: [
                  for (final row in timing.take(10))
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
