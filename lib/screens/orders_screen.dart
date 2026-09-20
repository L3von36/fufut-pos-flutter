import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'checkout_sheet.dart' show PaymentSheet;

/// Order history + open checks — a port of the web POS `OrdersView.vue`
/// in its phone layout: toolbar (title + count, search, status select),
/// then 12-grid ticket cards with the exact `.badge-*` status palette.
///
/// One screen serves two nav destinations: *Orders* (everything) and
/// *Open Checks* (`?open=1` — what the floor settles from).
class OrdersScreen extends StatefulWidget {
  final bool openOnlyDefault;
  const OrdersScreen({super.key, this.openOnlyDefault = false});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<FufutOrder> _orders = [];
  bool _loading = true;
  late bool _openOnly = widget.openOnlyDefault;
  String _query = '';
  String _statusFilter = 'all';
  String? _error;
  final _search = TextEditingController();

  static const _statuses = [
    'all', 'new', 'preparing', 'ready', 'served', 'fulfilled', 'cancelled'
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await app.api.orders(openOnly: _openOnly);
      if (!mounted) return;
      setState(() {
        _orders = rows;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) {
        await app.sessionExpired();
        return;
      }
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
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

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final rows = _filtered;
    return Scaffold(
      body: Column(
        children: [
          // ── Toolbar ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Row(
              children: [
                Text('Orders',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 14.7,
                        fontWeight: FontWeight.w700,
                        color: pal.heading)),
                const SizedBox(width: 8),
                Text('${rows.length} results',
                    style: TextStyle(
                        fontFamily: kFontBody, fontSize: 10.0, color: pal.muted)),
                const Spacer(),
                IconButton(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh, size: 18),
                  color: pal.muted,
                  tooltip: 'Refresh',
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: pal.surface,
                      border: Border.all(color: pal.border, width: 1.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.search, size: 15, color: pal.muted),
                        const SizedBox(width: 6),
                        Expanded(
                          child: TextField(
                            controller: _search,
                            onChanged: (v) => setState(() => _query = v),
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 10.9,
                                color: pal.heading),
                            decoration: InputDecoration(
                              hintText: 'Search orders...',
                              isDense: true,
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding:
                                  const EdgeInsets.symmetric(vertical: 10),
                              suffixIcon: _query.isEmpty
                                  ? null
                                  : IconButton(
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(Icons.close,
                                          size: 14, color: pal.muted),
                                      onPressed: () {
                                        _search.clear();
                                        setState(() => _query = '');
                                      },
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Status select — the web's native <select> with chevron.
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: pal.surface,
                    border: Border.all(color: pal.border, width: 1.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _statusFilter,
                      borderRadius: BorderRadius.circular(12),
                      icon: Icon(Icons.expand_more,
                          size: 16, color: pal.muted),
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 10.9,
                          color: pal.heading),
                      dropdownColor: pal.surface,
                      items: [
                        for (final s in _statuses)
                          DropdownMenuItem(
                            value: s,
                            child: Text(s == 'all' ? 'All Statuses' : _cap(s)),
                          ),
                      ],
                      onChanged: (v) =>
                          setState(() => _statusFilter = v ?? 'all'),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Open-checks toggle is only shown on the all-orders screen; the
          // Open Checks destination is already scoped.
          if (!widget.openOnlyDefault)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
              child: Row(
                children: [
                  _FilterChip(
                    label: 'Open checks',
                    active: _openOnly,
                    onTap: () {
                      setState(() => _openOnly = true);
                      _load();
                    },
                  ),
                  const SizedBox(width: 6),
                  _FilterChip(
                    label: 'All recent',
                    active: !_openOnly,
                    onTap: () {
                      setState(() => _openOnly = false);
                      _load();
                    },
                  ),
                ],
              ),
            ),
          // ── List ─────────────────────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _ErrorPane(message: _error!, onRetry: _load)
                    : rows.isEmpty
                        ? const EmptyState(
                            icon: Icons.receipt_long,
                            title: 'No orders yet',
                            hint: 'New tickets appear here as the floor fires them.')
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.separated(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding:
                                  const EdgeInsets.fromLTRB(14, 8, 14, 24),
                              itemCount: rows.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, i) =>
                                  _OrderTile(order: rows[i]),
                            ),
                          ),
          ),
        ],
      ),
    );
  }

  static String _cap(String s) => s.isEmpty
      ? s
      : '${s[0].toUpperCase()}${s.substring(1).toLowerCase()}';
}

// ─────────────────────────────────────────────────────────────────────────────
// Filter chip
// ─────────────────────────────────────────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _FilterChip(
      {required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(99),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? pal.primary : pal.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
              color: active ? pal.primary : pal.border, width: 1.5),
        ),
        child: Text(label,
            style: TextStyle(
                fontFamily: kFontBody,
                fontSize: 10.0,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : pal.body)),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Ticket card — the web's phone layout, 12-grid in spirit:
//   #id … [status]   / items   / total · tip · method · type   / meta / date
// ─────────────────────────────────────────────────────────────────────────────

class _OrderTile extends StatelessWidget {
  final FufutOrder order;
  const _OrderTile({required this.order});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final type = order.type ?? '';
    final table = order.tableNum != null && order.tableNum!.isNotEmpty
        ? 'Table ${order.tableNum}'
        : '';
    final customer =
        order.customer != null && order.customer != 'Walk-in' ? order.customer! : '';

    return InkWell(
      onTap: () => _openDetail(context),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: pal.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: pal.border, width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Line 1: id + status
            Row(
              children: [
                Expanded(
                  child: Text('#${order.id}',
                      style: T.mono.copyWith(
                          fontSize: 10.9,
                          fontWeight: FontWeight.w600,
                          color: pal.heading)),
                ),
                StatusBadge(status: order.status),
                const SizedBox(width: 6),
                PayBadge(paid: order.isPaid),
              ],
            ),
            // Line 2: items
            if (order.itemsRaw.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                order.items.isNotEmpty
                    ? order.items
                        .map((l) =>
                            l.qty > 1 ? '${l.qty}× ${l.name}' : l.name)
                        .join(', ')
                    : order.itemsRaw,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 10.5, color: pal.muted),
              ),
            ],
            const SizedBox(height: 6),
            // Line 3: money + method + type
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(money(order.total),
                    style: T.mono.copyWith(
                        fontSize: 11.8,
                        fontWeight: FontWeight.w600,
                        color: pal.heading)),
                if (order.tip > 0)
                  _Tag(
                    text: '+${money(order.tip)}',
                    bg: pal.tintBg,
                    fg: pal.primary,
                  ),
                if (order.discount > 0)
                  _Tag(
                    text: '-${money(order.discount)}',
                    bg: pal.successBg,
                    fg: pal.success,
                  ),
                if ((order.payment ?? '').isNotEmpty)
                  Text(_title(order.payment!),
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 10.0,
                          color: pal.muted)),
                if (type.isNotEmpty)
                  Text(_title(type),
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 10.0,
                          color: pal.muted)),
              ],
            ),
            const SizedBox(height: 4),
            // Line 4: table · customer · date
            Row(
              children: [
                Expanded(
                  child: Text(
                    [
                      if (table.isNotEmpty) table,
                      if (customer.isNotEmpty) customer,
                      if (order.created != null) order.created!,
                    ].join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: kFontBody, fontSize: 9.7, color: pal.faint),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _title(String s) => s.isEmpty
      ? s
      : s
          .split(RegExp(r'[\s_-]+'))
          .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
          .join(' ');

  void _openDetail(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: false,
      isScrollControlled: true,
      backgroundColor: Pal.of(context).surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<AppState>(),
        child: _OrderDetailSheet(order: order),
      ),
    );
  }
}

/// Small inline tag (tip/discount chips).
class _Tag extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  const _Tag({required this.text, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(text,
          style: T.mono.copyWith(
              fontSize: 9.2, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Detail sheet — lines, money rows, and the stage's action buttons.
// ─────────────────────────────────────────────────────────────────────────────

class _OrderDetailSheet extends StatelessWidget {
  final FufutOrder order;
  const _OrderDetailSheet({required this.order});

  /// The kitchen/complete pipeline, matching the web's row actions.
  static const _nextStatus = {
    'new': 'preparing',
    'preparing': 'ready',
    'ready': 'fulfilled',
  };

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final next = _nextStatus[order.status.toLowerCase()];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            Row(
              children: [
                Expanded(
                  child: Text('Order #${order.id}',
                      style: T.mono.copyWith(
                          fontSize: 13.4,
                          fontWeight: FontWeight.w700,
                          color: pal.heading)),
                ),
                StatusBadge(status: order.status),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [
                if ((order.type ?? '').isNotEmpty) order.type!,
                if (order.tableNum != null && order.tableNum!.isNotEmpty)
                  'Table ${order.tableNum}',
                if (order.customer != null && order.customer != 'Walk-in')
                  order.customer!,
                if (order.created != null) order.created!,
              ].join('  ·  '),
              style: TextStyle(fontFamily: kFontBody, fontSize: 9.7, color: pal.faint),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (order.items.isNotEmpty)
                      for (final l in order.items)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Text('${l.qty}×',
                                  style: T.mono.copyWith(
                                      fontSize: 10.9, color: pal.body)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(_lineLabel(l),
                                    style: TextStyle(
                                        fontFamily: kFontBody,
                                        fontSize: 10.9,
                                        fontWeight: FontWeight.w500,
                                        color: pal.heading)),
                              ),
                              Text(money(l.lineTotal),
                                  style: T.mono.copyWith(
                                      fontSize: 10.9, color: pal.body)),
                            ],
                          ),
                        )
                    else
                      Text(order.itemsRaw.isEmpty
                          ? 'No line detail (legacy order)'
                          : order.itemsRaw,
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 10.5,
                              color: pal.body)),
                    if ((order.notes ?? '').isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: pal.sunken,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text('Notes: ${order.notes}',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 10.0,
                                color: pal.body)),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.only(top: 8),
                      decoration: BoxDecoration(
                          border:
                              Border(top: BorderSide(color: pal.border))),
                      child: Column(
                        children: [
                          _moneyRow(context, 'Subtotal', order.subtotal),
                          if (order.discount > 0)
                            _moneyRow(context, 'Discount', -order.discount),
                          if (order.tip > 0)
                            _moneyRow(context, 'Tip', order.tip),
                          if (order.deliveryFee > 0)
                            _moneyRow(context, 'Delivery', order.deliveryFee),
                          _moneyRow(context, 'Total', order.total, bold: true),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (!order.isPaid)
              FilledButton.icon(
                onPressed: () => _settle(context),
                icon: const Icon(Icons.payments_outlined, size: 17),
                label: const Text('Settle — take payment'),
              ),
            if (next != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _advance(context, next),
                icon: const Icon(Icons.arrow_forward, size: 16),
                label: Text('Mark ${_title(next)}'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _title(String s) => s.isEmpty
      ? s
      : '${s[0].toUpperCase()}${s.substring(1).toLowerCase()}';

  /// "2x Macchiato [Extra shot] (no sugar)" — what the kitchen actually
  /// cooks, on one line.
  String _lineLabel(OrderItemLine l) {
    final sb = StringBuffer(l.name);
    final mods = l.modifiers
        .map((m) => (m['name'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .join(', ');
    if (mods.isNotEmpty) sb.write(' [$mods]');
    if (l.notes != null && l.notes!.isNotEmpty) sb.write(' (${l.notes})');
    return sb.toString();
  }

  Widget _moneyRow(BuildContext context, String label, double value,
      {bool bold = false}) {
    final pal = Pal.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label,
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 10.5,
                  color: pal.muted,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
          const Spacer(),
          Text(money(value),
              style: T.mono.copyWith(
                  fontSize: bold ? 12.2 : 10.9,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                  color: bold ? pal.heading : pal.body)),
        ],
      ),
    );
  }

  Future<void> _advance(BuildContext context, String status) async {
    final app = context.read<AppState>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.updateStatus(order, status);
      navigator.pop();
      showInfoOn(messenger, 'Marked $status');
    } on ApiError catch (e) {
      if (e.isAuthError) {
        await app.sessionExpired();
      }
      showErrorOn(messenger, e);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Future<void> _settle(BuildContext context) async {
    final app = context.read<AppState>();
    // fixedTotal: the bill is already on the server — the sheet must not
    // read the cart (there is none in this flow).
    final line = await showModalBottomSheet<PaymentLine>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Pal.of(context).surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      builder: (_) => PaymentSheet(fixedTotal: order.total),
    );
    if (line == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await app.api.settleOrder(order, line.method, line);
      navigator.pop();
      showInfoOn(
          messenger, 'Tab settled — ${money(line.amount)} via ${line.method}');
    } on ApiError catch (e) {
      if (e.isAuthError) {
        await app.sessionExpired();
      }
      showErrorOn(messenger, e);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }
}

class _ErrorPane extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorPane({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 32, color: pal.faint),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontFamily: kFontBody, fontSize: 10.9, color: pal.body)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
