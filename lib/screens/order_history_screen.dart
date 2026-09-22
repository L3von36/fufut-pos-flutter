import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/order_scope.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

/// Order History — the past tense of the Orders screen.
///
/// The operational screens (Orders, Pipeline, Open Checks) read the live
/// service day; this page reads any day window straight from the server
/// (`GET /api/orders?from=&to=&limit=&offset=` — Addis wall-clock day keys,
/// the same day semantics the reports use) and pages through it.
///
/// Read-only on purpose: yesterday's tickets are records, not work in
/// progress — status changes belong to today's board where they can be acted
/// on. The money line follows REAL_ORDERS (voided and cancelled excluded),
/// mirroring the web's isRealOrder and reports.js.
class OrderHistoryScreen extends StatefulWidget {
  const OrderHistoryScreen({super.key});

  @override
  State<OrderHistoryScreen> createState() => _OrderHistoryScreenState();
}

class _OrderHistoryScreenState extends State<OrderHistoryScreen> {
  static const _page = 100;

  static const _presets = [
    ('today', 'Today'),
    ('yesterday', 'Yesterday'),
    ('7d', '7 days'),
    ('30d', '30 days'),
  ];

  String _preset = 'yesterday';
  DateTime? _customFrom;
  DateTime? _customTo;
  List<FufutOrder> _orders = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;
  String _query = '';
  String _statusFilter = 'all';
  final _search = TextEditingController();

  static const _statuses = [
    'all', 'new', 'preparing', 'ready', 'served', 'fulfilled', 'completed',
    'cancelled'
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _dayKey(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  DateTime _dayAgo(int n) => DateTime.now().subtract(Duration(days: n));

  String get _from {
    switch (_preset) {
      case 'today':
        return _dayKey(DateTime.now());
      case 'yesterday':
        return _dayKey(_dayAgo(1));
      case '7d':
        return _dayKey(_dayAgo(7));
      case '30d':
        return _dayKey(_dayAgo(30));
      default:
        return _dayKey(_customFrom ?? _dayAgo(30));
    }
  }

  String get _to {
    switch (_preset) {
      case 'today':
        return _dayKey(DateTime.now());
      case 'yesterday':
      case '7d':
      case '30d':
        // Windows end yesterday: today is the Orders screen's job.
        return _dayKey(_dayAgo(1));
      default:
        return _dayKey(_customTo ?? _dayAgo(1));
    }
  }

  String get _rangeLabel {
    if (_preset == 'today') return 'Today';
    if (_preset == 'yesterday') return 'Yesterday';
    if (_preset == '7d') return 'Last 7 days';
    if (_preset == '30d') return 'Last 30 days';
    return '$_from → $_to';
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    setState(() { _loading = true; _error = null; });
    try {
      final rows = await app.api.orders(
          from: _from, to: _to, limit: _page, offset: 0);
      if (!mounted) return;
      setState(() {
        _orders = rows;
        _hasMore = rows.length == _page;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) {
        await app.sessionExpired();
        return;
      }
      setState(() { _loading = false; _error = e.message; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = '$e'; });
    }
  }

  Future<void> _loadMore() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _loadingMore = true);
    try {
      final rows = await app.api.orders(
          from: _from, to: _to, limit: _page, offset: _orders.length);
      if (!mounted) return;
      setState(() {
        _orders = [..._orders, ...rows];
        _hasMore = rows.length == _page;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      showInfoOn(messenger, 'Could not load more rows');
    }
  }

  List<FufutOrder> get _filtered {
    final q = _query.trim().toLowerCase();
    return _orders.where((o) {
      if (_statusFilter != 'all' && o.status.toLowerCase() != _statusFilter) {
        return false;
      }
      if (q.isEmpty) return true;
      return o.id.toLowerCase().contains(q) ||
          (o.customer ?? '').toLowerCase().contains(q) ||
          (o.tableNum ?? '').toLowerCase().contains(q) ||
          o.itemsRaw.toLowerCase().contains(q);
    }).toList();
  }

  /// Page money over REAL orders — voided_at / cancelled excluded, the same
  /// rule reports use. Labelled "in view" because the pager may not have
  /// pulled the whole window yet.
  double get _realTotal => _filtered
      .where(orderIsReal)
      .fold(0.0, (s, o) => s + o.total);

  static Color _accentFor(BuildContext context, String status) {
    final pal = Pal.of(context);
    switch (status.toLowerCase()) {
      case 'new':
        return pal.info;
      case 'preparing':
      case 'pending':
        return pal.warning;
      case 'ready':
        return const Color(0xFF6366F1);
      case 'served':
        return pal.gold;
      case 'fulfilled':
      case 'completed':
        return pal.success;
      case 'cancelled':
        return pal.danger;
      default:
        return pal.borderStrong;
    }
  }

  void _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      initialDateRange: DateTimeRange(
          start: _dayAgo(7), end: _dayAgo(1)),
    );
    if (picked != null && mounted) {
      setState(() {
        _preset = 'custom';
        _customFrom = picked.start;
        _customTo = picked.end;
      });
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final rows = _filtered;
    return Scaffold(
      backgroundColor: pal.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // ── Header ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 12, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back_rounded,
                        size: 20, color: pal.heading),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 2),
                  Text('Order History',
                      style: T.screenTitle.copyWith(color: pal.heading)),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.refresh_rounded,
                        size: 20, color: pal.muted),
                    onPressed: _load,
                  ),
                ],
              ),
            ),
            // ── Range presets + custom ──────────────────────────────────
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final (key, label) in _presets)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _PresetChip(
                        label: label,
                        active: _preset == key,
                        onTap: () {
                          setState(() => _preset = key);
                          _load();
                        },
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _PresetChip(
                      label: 'Custom',
                      icon: Icons.date_range_rounded,
                      active: _preset == 'custom',
                      onTap: _pickCustomRange,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Row(
                children: [
                  Icon(Icons.date_range_rounded,
                      size: 13, color: pal.faint),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('$_rangeLabel  ·  $_from → $_to',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: kFontMono,
                            fontSize: 10.5,
                            color: pal.muted)),
                  ),
                ],
              ),
            ),
            // ── Search + status chips ───────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: _HistorySearch(
                controller: _search,
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                children: [
                  for (final s in _statuses)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _HistoryChip(
                        label: s == 'all' ? 'All' : _cap(s),
                        count: s == 'all'
                            ? _orders.length
                            : _orders
                                .where((o) =>
                                    o.status.toLowerCase() == s.toLowerCase())
                                .length,
                        active: _statusFilter == s,
                        onTap: () => setState(() => _statusFilter = s),
                      ),
                    ),
                ],
              ),
            ),
            // ── Money line ──────────────────────────────────────────────
            if (!_loading && _error == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 2),
                child: Row(children: [
                  Text('${rows.length} in view',
                      style: TextStyle(
                          fontFamily: kFontMono,
                          fontSize: 10.5,
                          color: pal.faint)),
                  const Spacer(),
                  Flexible(
                    child: Text(
                        'Page total ${money(_realTotal)}  ·  voided excluded',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontFamily: kFontMono,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: pal.heading)),
                  ),
                ]),
              ),
            // ── List ────────────────────────────────────────────────────
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? LoadError(error: _error!, onRetry: _load)
                      : rows.isEmpty
                          ? const EmptyState(
                              icon: Icons.history_rounded,
                              title: 'No orders in this window',
                              hint:
                                  'Pick another day or range above — history '
                                  'keeps every ticket the live screens have '
                                  'moved on from.',
                            )
                          : ListView(
                              padding:
                                  const EdgeInsets.fromLTRB(12, 6, 12, 20),
                              children: [
                                for (final o in rows)
                                  Padding(
                                    padding:
                                        const EdgeInsets.only(bottom: 8),
                                    child: _HistoryTile(
                                      order: o,
                                      accent:
                                          _accentFor(context, o.status),
                                    ),
                                  ),
                                if (_hasMore)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: OutlinedButton.icon(
                                      onPressed: _loadingMore
                                          ? null
                                          : _loadMore,
                                      icon: _loadingMore
                                          ? const SizedBox(
                                              width: 14,
                                              height: 14,
                                              child:
                                                  CircularProgressIndicator(
                                                      strokeWidth: 2))
                                          : const Icon(
                                              Icons.expand_more_rounded,
                                              size: 16),
                                      label: Text(_loadingMore
                                          ? 'Loading…'
                                          : 'Load more'),
                                    ),
                                  ),
                              ],
                            ),
            ),
          ],
        ),
      ),
    );
  }

  static String _cap(String s) => s.isEmpty
      ? s
      : '${s[0].toUpperCase()}${s.substring(1).toLowerCase()}';
}

// ─────────────────────────────────────────────────────────────────────────────
// Local pieces — history screen keeps its own lean tiles: read-only records,
// no check actions, no live statuses.
// ─────────────────────────────────────────────────────────────────────────────

class _PresetChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  final IconData? icon;
  const _PresetChip({
    required this.label,
    required this.active,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(99),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? pal.primary : pal.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
              color: active ? pal.primary : pal.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon,
                size: 13,
                color: active ? Colors.white : pal.muted),
            const SizedBox(width: 4),
          ],
          Text(label,
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: active ? Colors.white : pal.body)),
        ]),
      ),
    );
  }
}

class _HistorySearch extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const _HistorySearch({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: pal.surface,
        border: Border.all(color: pal.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 17, color: pal.muted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 12.5,
                  color: pal.body),
              decoration: InputDecoration(
                hintText: 'Search id, items, customer, table…',
                hintStyle: TextStyle(fontSize: 12, color: pal.faint),
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryChip extends StatelessWidget {
  final String label;
  final int count;
  final bool active;
  final VoidCallback onTap;
  const _HistoryChip({
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(99),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? pal.primary : pal.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
              color: active ? pal.primary : pal.border),
        ),
        child: Text('$label · $count',
            style: TextStyle(
                fontFamily: kFontBody,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: active ? Colors.white : pal.muted)),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final FufutOrder order;
  final Color accent;
  const _HistoryTile({required this.order, required this.accent});

  String _stamp(BuildContext context) {
    final c = DateTime.tryParse(order.created ?? '');
    if (c == null) return order.created ?? '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(c.day)}/${two(c.month)} ${two(c.hour)}:${two(c.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final table = order.tableNum != null && order.tableNum!.isNotEmpty
        ? 'Table ${order.tableNum}'
        : (order.type ?? '');
    return InkWell(
      onTap: () => _openDetail(context),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: pal.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: pal.border),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 4, color: accent),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(11),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text('Order #${shortId(order.id)}',
                                style: T.mono.copyWith(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: pal.heading)),
                          ),
                          Text(money(order.total),
                              style: T.mono.copyWith(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: pal.heading)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        order.itemsRaw.isEmpty
                            ? (order.items.isEmpty
                                ? '—'
                                : order.items
                                    .map((l) => '${l.qty}× ${l.name}')
                                    .join(', '))
                            : order.itemsRaw,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11.5,
                            color: pal.body),
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          if (table.isNotEmpty) ...[
                            Icon(Icons.restaurant_rounded,
                                size: 11, color: pal.faint),
                            const SizedBox(width: 3),
                            Text(table,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 10.5,
                                    color: pal.muted)),
                            const SizedBox(width: 8),
                          ],
                          Icon(Icons.schedule_rounded,
                              size: 11, color: pal.faint),
                          const SizedBox(width: 3),
                          Text(_stamp(context),
                              style: TextStyle(
                                  fontFamily: kFontMono,
                                  fontSize: 10.5,
                                  color: pal.muted)),
                          const Spacer(),
                          if ((order.voidedAt ?? '').isNotEmpty)
                            Text('voided',
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: pal.danger))
                          else
                            Text(order.status,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: accent)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openDetail(BuildContext context) {
    final pal = Pal.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: pal.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.paddingOf(ctx).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Order #${order.id}',
                style: T.screenTitle.copyWith(color: pal.heading)),
            const SizedBox(height: 4),
            Text(
                '${order.status} · ${order.type ?? ''}'
                '${order.tableNum != null && order.tableNum!.isNotEmpty ? ' · Table ${order.tableNum}' : ''}'
                ' · ${order.created ?? ''}',
                style: TextStyle(
                    fontFamily: kFontMono,
                    fontSize: 10.5,
                    color: pal.muted)),
            if ((order.createdByName ?? '').isNotEmpty) ...[
              const SizedBox(height: 2),
              Text('Taken by ${order.createdByName}',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 11,
                      color: pal.muted)),
            ],
            const SizedBox(height: 10),
            for (final l in order.items.take(20))
              ListRow(
                  head: '${l.qty}× ${l.name}',
                  rest: l.notes,
                  trailing: money(l.lineTotal)),
            if (order.items.isEmpty)
              ListRow(head: order.itemsRaw, rest: null, trailing: ''),
            const SizedBox(height: 12),
            ListRow(head: 'Subtotal', rest: null,
                trailing: money(order.subtotal)),
            if (order.discount > 0)
              ListRow(head: 'Discount', rest: null,
                  trailing: '-${money(order.discount)}'),
            if (order.tip > 0)
              ListRow(head: 'Tip', rest: null, trailing: money(order.tip)),
            const Divider(height: 16),
            ListRow(head: 'Total', rest: null,
                trailing: money(order.total)),
            const SizedBox(height: 4),
            Text(
                (order.voidedAt ?? '').isNotEmpty
                    ? 'This ticket was voided — excluded from money totals.'
                    : 'A record of service. Status changes happen on the '
                        'live screens, not in history.',
                style: TextStyle(fontSize: 10.5, color: pal.faint)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
