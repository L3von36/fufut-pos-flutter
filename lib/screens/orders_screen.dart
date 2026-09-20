import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'checkout_sheet.dart' show PaymentSheet;

/// Order history + open checks — the waiter dashboard.
///
/// One screen serves two nav destinations: *Orders* (everything) and
/// *Open Checks* (`?open=1` — what the floor settles from).
///
/// Android-native layout: a KPI strip (open / ready / unpaid / on-tabs),
/// a sticky search field with a horizontally-scrolling status filter row,
/// then ticket cards whose left accent bar carries the status color.
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

  /// Status → card accent color (the `.badge-*` hues).
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

  // ── KPI math — computed over the currently loaded scope ────────────────────

  static const _openStatuses = {'new', 'preparing', 'ready', 'served'};

  bool _isOpen(FufutOrder o) => _openStatuses.contains(o.status.toLowerCase());

  int get _openCount => _orders.where(_isOpen).length;
  int get _readyCount =>
      _orders.where((o) => o.status.toLowerCase() == 'ready').length;
  int get _unpaidCount => _orders
      .where((o) => !o.isPaid && o.status.toLowerCase() != 'cancelled')
      .length;
  double get _onTabs => _orders
      .where((o) => _isOpen(o) && !o.isPaid)
      .fold(0.0, (s, o) => s + o.total);

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final rows = _filtered;
    return Scaffold(
      backgroundColor: pal.bg,
      body: Column(
        children: [
          // ── Header ────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text('Orders',
                    style: T.screenTitle.copyWith(color: pal.heading)),
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: pal.tintBg,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text('${rows.length}',
                      style: TextStyle(
                          fontFamily: kFontMono,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: pal.primary)),
                ),
                const Spacer(),
                _IconAction(icon: Icons.refresh_rounded, onTap: _load),
              ],
            ),
          ),
          // ── Scope toggle + search + status chips ─────────────────────────
          if (!widget.openOnlyDefault)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Row(
                children: [
                  _ScopeChip(
                    label: 'Open checks',
                    icon: Icons.timelapse_rounded,
                    active: _openOnly,
                    onTap: () {
                      setState(() => _openOnly = true);
                      _load();
                    },
                  ),
                  const SizedBox(width: 8),
                  _ScopeChip(
                    label: 'All recent',
                    icon: Icons.receipt_long_outlined,
                    active: !_openOnly,
                    onTap: () {
                      setState(() => _openOnly = false);
                      _load();
                    },
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: _SearchField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              children: [
                for (final s in _statuses)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _StatusFilterChip(
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
          // ── KPI strip ────────────────────────────────────────────────────
          if (!_loading && _error == null && _orders.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: _KpiStrip(
                open: _openCount,
                ready: _readyCount,
                unpaid: _unpaidCount,
                onTabs: _onTabs,
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
                            hint:
                                'New tickets appear here as the floor fires them.')
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.separated(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding:
                                  const EdgeInsets.fromLTRB(16, 8, 16, 24),
                              itemCount: rows.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (context, i) => _OrderTile(
                                order: rows[i],
                                accent: _accentFor(context, rows[i].status),
                              ),
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
// Header atoms
// ─────────────────────────────────────────────────────────────────────────────

/// 40px circular icon button used for the refresh action.
class _IconAction extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _IconAction({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Material(
      color: pal.sunken,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon, size: 20, color: pal.body),
        ),
      ),
    );
  }
}

/// Scope toggle — 'Open checks' vs 'All recent'.
class _ScopeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _ScopeChip({
    required this.label,
    required this.icon,
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? pal.primary : pal.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
              color: active ? pal.primary : pal.border, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 15,
                color: active ? Colors.white : pal.muted),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: active ? Colors.white : pal.body)),
          ],
        ),
      ),
    );
  }
}

/// 48px search field — surface card, rounded 13, trailing clear button.
class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _SearchField({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: pal.surface,
        border: Border.all(color: pal.border, width: 1.5),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 20, color: pal.muted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: TextStyle(
                  fontFamily: kFontBody, fontSize: 14, color: pal.heading),
              decoration: InputDecoration(
                hintText: 'Search id, table, customer…',
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                suffixIcon: controller.text.isEmpty
                    ? null
                    : IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.close_rounded,
                            size: 18, color: pal.muted),
                        onPressed: () {
                          controller.clear();
                          onChanged('');
                        },
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Status filter — pill with live count, primary when active.
class _StatusFilterChip extends StatelessWidget {
  final String label;
  final int count;
  final bool active;
  final VoidCallback onTap;

  const _StatusFilterChip({
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
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
        decoration: BoxDecoration(
          color: active ? pal.primary : pal.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
              color: active ? pal.primary : pal.border, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: active ? Colors.white : pal.body)),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: active
                      ? Colors.white.withValues(alpha: 0.22)
                      : pal.sunken,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text('$count',
                    style: TextStyle(
                        fontFamily: kFontMono,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: active ? Colors.white : pal.muted)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// KPI strip — Open / Ready / Unpaid / On tabs, tinted mini cards.
// ─────────────────────────────────────────────────────────────────────────────

class _KpiStrip extends StatelessWidget {
  final int open;
  final int ready;
  final int unpaid;
  final double onTabs;

  const _KpiStrip({
    required this.open,
    required this.ready,
    required this.unpaid,
    required this.onTabs,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    Color tint(Color base, Color bg) => dark ? base : bg;

    final cells = [
      (
        label: 'OPEN',
        value: '$open',
        bg: tint(pal.warning, pal.warningBg),
        fg: dark ? pal.warning : const Color(0xFF92400E),
      ),
      (
        label: 'READY',
        value: '$ready',
        bg: tint(const Color(0xFF6366F1), const Color(0xFFEEF2FF)),
        fg: dark ? const Color(0xFFA5B4FC) : const Color(0xFF3730A3),
      ),
      (
        label: 'UNPAID',
        value: '$unpaid',
        bg: tint(pal.danger, pal.dangerBg),
        fg: dark ? pal.danger : const Color(0xFF991B1B),
      ),
      (
        label: 'ON TABS',
        value: moneyGroup(onTabs),
        bg: tint(pal.primary, pal.tintBg),
        fg: dark ? pal.primary : pal.primary,
      ),
    ];

    return Row(
      children: [
        for (var i = 0; i < cells.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              decoration: BoxDecoration(
                color: cells[i].bg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Text(cells[i].value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: kFontMono,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: cells[i].fg)),
                  const SizedBox(height: 2),
                  Text(cells[i].label,
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.7,
                          color: cells[i].fg.withValues(alpha: 0.75))),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Ticket card — status accent bar, id + badges, items, money, icon meta row.
// ─────────────────────────────────────────────────────────────────────────────

class _OrderTile extends StatelessWidget {
  final FufutOrder order;
  final Color accent;

  const _OrderTile({required this.order, required this.accent});

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
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: pal.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: pal.border, width: 1.5),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 5, color: accent),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Line 1: id + status + pay
                      Row(
                        children: [
                          Expanded(
                            child: Text('Order #${order.id}',
                                style: T.mono.copyWith(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    color: pal.heading)),
                          ),
                          StatusBadge(status: order.status),
                          const SizedBox(width: 6),
                          PayBadge(paid: order.isPaid),
                        ],
                      ),
                      // Line 2: items
                      if (order.itemsRaw.isNotEmpty) ...[
                        const SizedBox(height: 7),
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
                              fontFamily: kFontBody,
                              fontSize: 12.5,
                              height: 1.3,
                              color: pal.muted),
                        ),
                      ],
                      const SizedBox(height: 8),
                      // Line 3: money + method + type
                      Row(
                        children: [
                          Text(money(order.total),
                              style: T.mono.copyWith(
                                  fontSize: 16.5,
                                  fontWeight: FontWeight.w700,
                                  color: pal.heading)),
                          if (order.tip > 0) ...[
                            const SizedBox(width: 6),
                            _Tag(
                              text: '+${money(order.tip)}',
                              bg: pal.tintBg,
                              fg: pal.primary,
                            ),
                          ],
                          if (order.discount > 0) ...[
                            const SizedBox(width: 6),
                            _Tag(
                              text: '-${money(order.discount)}',
                              bg: pal.successBg,
                              fg: pal.success,
                            ),
                          ],
                          const Spacer(),
                          if ((order.payment ?? '').isNotEmpty)
                            Text(_title(order.payment!),
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 11.5,
                                    color: pal.muted)),
                          if ((order.payment ?? '').isNotEmpty && type.isNotEmpty)
                            Text('  ·  ',
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 11.5,
                                    color: pal.faint)),
                          if (type.isNotEmpty)
                            Text(_title(type),
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 11.5,
                                    color: pal.muted)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Line 4: table · customer · date — with icons
                      Row(
                        children: [
                          if (table.isNotEmpty) ...[
                            Icon(Icons.table_restaurant_outlined,
                                size: 12.5, color: pal.faint),
                            const SizedBox(width: 3),
                            Text(table,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 11.5,
                                    color: pal.faint)),
                            const SizedBox(width: 10),
                          ],
                          if (customer.isNotEmpty) ...[
                            Icon(Icons.person_outline,
                                size: 13, color: pal.faint),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(customer,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontFamily: kFontBody,
                                      fontSize: 11.5,
                                      color: pal.faint)),
                            ),
                            const SizedBox(width: 10),
                          ],
                          if (order.created != null) ...[
                            Icon(Icons.schedule,
                                size: 12.5, color: pal.faint),
                            const SizedBox(width: 3),
                            Text(order.created!,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 11.5,
                                    color: pal.faint)),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              // Tap affordance — subtle chevron like a native list tile.
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(Icons.chevron_right_rounded,
                      size: 22, color: pal.faint),
                ),
              ),
            ],
          ),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(text,
          style: T.mono.copyWith(
              fontSize: 10.5, fontWeight: FontWeight.w700, color: fg)),
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
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text('Order #${order.id}',
                      style: T.mono.copyWith(
                          fontSize: 17,
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
              style: TextStyle(fontFamily: kFontBody, fontSize: 12, color: pal.faint),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (order.items.isNotEmpty)
                      for (final l in order.items)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 30,
                                alignment: Alignment.center,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: pal.sunken,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text('${l.qty}×',
                                    style: T.mono.copyWith(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w700,
                                        color: pal.body)),
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(_lineLabel(l),
                                    style: TextStyle(
                                        fontFamily: kFontBody,
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w500,
                                        height: 1.3,
                                        color: pal.heading)),
                              ),
                              const SizedBox(width: 8),
                              Text(money(l.lineTotal),
                                  style: T.mono.copyWith(
                                      fontSize: 13, color: pal.body)),
                            ],
                          ),
                        )
                    else
                      Text(order.itemsRaw.isEmpty
                          ? 'No line detail (legacy order)'
                          : order.itemsRaw,
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 12.5,
                              color: pal.body)),
                    if ((order.notes ?? '').isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: pal.sunken,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.sticky_note_2_outlined,
                                size: 15, color: pal.muted),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text('Notes: ${order.notes}',
                                  style: TextStyle(
                                      fontFamily: kFontBody,
                                      fontSize: 12.5,
                                      color: pal.body)),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.only(top: 10),
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
            const SizedBox(height: 18),
            if (!order.isPaid)
              FilledButton.icon(
                onPressed: () => _settle(context),
                icon: const Icon(Icons.payments_outlined, size: 19),
                label: const Text('Settle — take payment'),
              ),
            if (next != null) ...[
              const SizedBox(height: 9),
              OutlinedButton.icon(
                onPressed: () => _advance(context, next),
                icon: const Icon(Icons.arrow_forward_rounded, size: 18),
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
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(label,
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 13,
                  color: pal.muted,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
          const Spacer(),
          Text(money(value),
              style: T.mono.copyWith(
                  fontSize: bold ? 16 : 13.5,
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
            Icon(Icons.cloud_off, size: 36, color: pal.faint),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontFamily: kFontBody, fontSize: 13, color: pal.body)),
            const SizedBox(height: 14),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
