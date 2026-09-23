/// Table History — the floor's archive (owner request, 2026-09).
///
/// The floor plan shows the room as it IS; this screen shows what HAPPENED
/// on it. A grid of every table the signed-in role can see, each card
/// summarising the selected day window's activity (orders, covers-ish via
/// line count, revenue, unpaid balance); tapping a table opens its ordered
/// timeline — every ticket that touched the table in the window, newest
/// first, with status badges and the same detail sheet the Orders screen
/// uses. Day filter: Today / Yesterday / 7 days / 30 days.
///
/// Data: one `GET /api/orders?from&to&limit=200` per window (the same read
/// the Order History screen pages through), grouped client-side by table.
/// Tables come from `GET /api/tables` — which the server scopes per role
/// (the head-waiter sees their section, the manager the room). No SSE: an
/// archive is pulled on demand, not pushed.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/floor_plan.dart' show paymentLabel;
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart' show LoadError;
import 'orders_screen.dart' show OrderDetailSheet;

class TablesHistoryScreen extends StatefulWidget {
  /// Pre-select a table (the floor plan's "view history" deep link).
  final String? initialTableId;

  const TablesHistoryScreen({super.key, this.initialTableId});
  @override
  State<TablesHistoryScreen> createState() => _TablesHistoryScreenState();
}

class _TablesHistoryScreenState extends State<TablesHistoryScreen> {
  List<CafeTable> _tables = [];
  List<FufutOrder> _orders = [];
  bool _loading = true;
  Object? _error;
  String _preset = 'today'; // today | yesterday | 7d | 30d
  String? _openTableId; // null = the grid; set = that table's timeline

  @override
  void initState() {
    super.initState();
    _openTableId = widget.initialTableId;
    _load();
  }

  String _dayKey(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  (String, String) get _window {
    final now = DateTime.now();
    switch (_preset) {
      case 'yesterday':
        final y = now.subtract(const Duration(days: 1));
        return (_dayKey(y), _dayKey(y));
      case '7d':
        return (_dayKey(now.subtract(const Duration(days: 7))), _dayKey(now));
      case '30d':
        return (_dayKey(now.subtract(const Duration(days: 30))), _dayKey(now));
      default:
        final k = _dayKey(now);
        return (k, k);
    }
  }

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!mounted) return;
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final (from, to) = _window;
      final results = await Future.wait([
        app.api.tables(),
        app.api.orders(from: from, to: to, limit: 200),
      ]);
      if (!mounted) return;
      setState(() {
        _tables = results[0] as List<CafeTable>;
        _orders = results[1] as List<FufutOrder>;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) {
        await context.read<AppState>().sessionExpired();
        return;
      }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  List<FufutOrder> _ordersFor(CafeTable t) {
    return _orders
        .where((o) => o.tableNum == t.number || o.tableNum == t.id)
        .toList()
      ..sort((a, b) => (b.created ?? '').compareTo(a.created ?? ''));
  }

  double _revenueOf(List<FufutOrder> orders) => orders
      .where((o) => (o.paymentStatus ?? '').toLowerCase() == 'paid')
      .fold(0.0, (s, o) => s + o.total);

  @override
  Widget build(BuildContext context) {
    if (_loading && _orders.isEmpty && _tables.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _orders.isEmpty && _tables.isEmpty) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final pal = Pal.of(context);
    final table = _openTableId == null
        ? null
        : _tables.where((t) => t.id == _openTableId).firstOrNull;

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: Column(children: [
        // ── Day filter ────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Row(children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  _presetChip(context, 'today', 'Today'),
                  const SizedBox(width: 6),
                  _presetChip(context, 'yesterday', 'Yesterday'),
                  const SizedBox(width: 6),
                  _presetChip(context, '7d', '7 days'),
                  const SizedBox(width: 6),
                  _presetChip(context, '30d', '30 days'),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            Text('${_orders.length} order${_orders.length == 1 ? '' : 's'}',
                style: TextStyle(
                    fontFamily: kFontMono,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: pal.muted)),
          ]),
        ),
        const SizedBox(height: 4),
        // ── Body: grid, or one table's timeline ───────────────────────
        Expanded(
          child: table != null ? _tableTimeline(context, table) : _grid(context),
        ),
      ]),
    );
  }

  Widget _presetChip(BuildContext context, String value, String label) {
    final pal = Pal.of(context);
    final active = _preset == value;
    return InkWell(
      onTap: active
          ? null
          : () {
              setState(() => _preset = value);
              _load(quiet: true);
            },
      borderRadius: BorderRadius.circular(99),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? pal.primary : pal.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
              color: active ? pal.primary : pal.border),
        ),
        child: Text(label,
            style: TextStyle(
                fontFamily: kFontBody,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: active ? Colors.white : pal.body)),
      ),
    );
  }

  // ── The room: one card per table ───────────────────────────────────────

  Widget _grid(BuildContext context) {
    final pal = Pal.of(context);
    if (_tables.isEmpty) {
      return ListView(children: [
        const SizedBox(height: 100),
        const EmptyState(
          icon: Icons.history_rounded,
          title: 'No tables to show',
          hint: 'The floor plan defines the tables; the manager owns that.',
        ),
      ]);
    }
    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth >= 700 ? 3 : 2;
      return GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.5,
        ),
        itemCount: _tables.length,
        itemBuilder: (context, i) {
          final t = _tables[i];
          final orders = _ordersFor(t);
          final revenue = _revenueOf(orders);
          final unpaid = orders
              .where((o) =>
                  !(o.paymentStatus ?? '').toLowerCase().startsWith('paid'))
              .length;
          return InkWell(
            onTap: () => setState(() => _openTableId = t.id),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: pal.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: orders.isNotEmpty
                        ? pal.primary.withValues(alpha: 0.35)
                        : pal.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.table_restaurant_rounded,
                        size: 15,
                        color: orders.isNotEmpty ? pal.primary : pal.faint),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(t.name ?? 'Table ${t.number}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: pal.heading)),
                    ),
                    Icon(Icons.chevron_right_rounded,
                        size: 16, color: pal.faint),
                  ]),
                  const Spacer(),
                  orders.isEmpty
                      ? Text('No orders in this window',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 10.5,
                              color: pal.faint))
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${orders.length} order${orders.length == 1 ? '' : 's'}',
                                style: TextStyle(
                                    fontFamily: kFontMono,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: pal.body)),
                            const SizedBox(height: 2),
                            Text(
                                '${money(revenue)} collected'
                                '${unpaid > 0 ? '  ·  $unpaid open' : ''}',
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 10.5,
                                    color: unpaid > 0
                                        ? pal.warning
                                        : pal.muted)),
                          ],
                        ),
                ],
              ),
            ),
          );
        },
      );
    });
  }

  // ── One table: the ordered timeline of the window ──────────────────────

  Widget _tableTimeline(BuildContext context, CafeTable t) {
    final pal = Pal.of(context);
    final orders = _ordersFor(t);
    return Column(children: [
      // Table header — back, name, window totals.
      Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: pal.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: pal.border),
        ),
        child: Row(children: [
          InkWell(
            onTap: () => setState(() => _openTableId = null),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child:
                  Icon(Icons.arrow_back_rounded, size: 18, color: pal.primary),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(t.name ?? 'Table ${t.number}',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: pal.heading)),
          ),
          Text('${orders.length} orders · ${money(_revenueOf(orders))}',
              style: TextStyle(
                  fontFamily: kFontMono,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: pal.muted)),
        ]),
      ),
      Expanded(
        child: orders.isEmpty
            ? ListView(children: [
                const SizedBox(height: 90),
                const EmptyState(
                  icon: Icons.receipt_long_rounded,
                  title: 'Nothing on this table in the window',
                  hint:
                      'Switch the day filter above, or pick another table.',
                ),
              ])
            : ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: orders.length,
                itemBuilder: (context, i) {
                  final o = orders[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      onTap: () => _openOrder(context, o),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 11, vertical: 9),
                        decoration: BoxDecoration(
                          color: pal.surface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: pal.border),
                        ),
                        child: Row(children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Text(shortId(o.id),
                                      style: TextStyle(
                                          fontFamily: kFontMono,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                          color: pal.heading)),
                                  const SizedBox(width: 7),
                                  StatusBadge(status: o.status),
                                  if ((o.type ?? '').isNotEmpty) ...[
                                    const SizedBox(width: 6),
                                    Text(o.type!,
                                        style: TextStyle(
                                            fontFamily: kFontBody,
                                            fontSize: 10,
                                            color: pal.faint)),
                                  ],
                                ]),
                                const SizedBox(height: 2),
                                Text(_whenOf(o),
                                    style: TextStyle(
                                        fontFamily: kFontBody,
                                        fontSize: 10.5,
                                        color: pal.faint)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(money(o.total),
                                  style: TextStyle(
                                      fontFamily: kFontMono,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w800,
                                      color: pal.heading)),
                              const SizedBox(height: 2),
                              Text(paymentLabel(
                                  (o.paymentStatus ?? 'unpaid').toLowerCase()),
                                  style: TextStyle(
                                      fontFamily: kFontBody,
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w700,
                                      color: (o.paymentStatus ?? '')
                                              .toLowerCase()
                                              .startsWith('paid')
                                          ? pal.success
                                          : pal.warning)),
                            ],
                          ),
                        ]),
                      ),
                    ),
                  );
                },
              ),
      ),
    ]);
  }

  String _whenOf(FufutOrder o) {
    final c = DateTime.tryParse(o.created ?? '');
    if (c == null) return o.created ?? '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${_dayKey(c)}  ${two(c.hour)}:${two(c.minute)}';
  }

  Future<void> _openOrder(BuildContext context, FufutOrder o) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Pal.of(context).surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      builder: (_) => OrderDetailSheet(order: o),
    );
  }
}
