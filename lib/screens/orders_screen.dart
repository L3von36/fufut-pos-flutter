import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'checkout_sheet.dart' show PaymentSheet;

/// Order history + open checks.
///
/// Two tabs mirror the web POS: every ticket the API returns (last 200) and
/// the open (`?open=1`) list the floor works from. Actions follow the same
/// pipeline as the till: advance status, settle an unpaid tab with a PUT.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<FufutOrder> _orders = [];
  bool _loading = true;
  bool _openOnly = true;
  String? _error;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Orders'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Open checks')),
                ButtonSegment(value: false, label: Text('All recent')),
              ],
              selected: {_openOnly},
              onSelectionChanged: (s) {
                setState(() => _openOnly = s.first);
                _load();
              },
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _ErrorPane(message: _error!, onRetry: _load)
                    : _orders.isEmpty
                        ? _EmptyPane(onRetry: _load)
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.separated(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                              itemCount: _orders.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, i) =>
                                  _OrderTile(order: _orders[i]),
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}

class _ErrorPane extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorPane({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 40, color: Colors.white24),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _EmptyPane extends StatelessWidget {
  final VoidCallback onRetry;
  const _EmptyPane({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.receipt_long, size: 44, color: Colors.white24),
          const SizedBox(height: 12),
          const Text('Nothing here yet'),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Refresh')),
        ],
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  final FufutOrder order;
  const _OrderTile({required this.order});

  @override
  Widget build(BuildContext context) {
    final label = order.tableNum != null && order.tableNum!.isNotEmpty
        ? 'Table ${order.tableNum}'
        : (order.type ?? 'order');
    final customer =
        order.customer != null && order.customer != 'Walk-in' ? order.customer! : '';
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: () => _openDetail(context),
        title: Row(
          children: [
            Expanded(
              child: Text(
                '#${order.id} · $label${customer.isEmpty ? '' : ' · $customer'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor(order.status).withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                order.status,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: statusColor(order.status)),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: order.isPaid
                    ? const Color(0xFF2E7D32).withValues(alpha: 0.25)
                    : const Color(0xFFF9A825).withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                order.isPaid ? 'paid' : 'unpaid',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: order.isPaid
                        ? const Color(0xFFA5D6A7)
                        : const Color(0xFFFFE082)),
              ),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              order.items.isNotEmpty
                  ? order.items.map((l) => '${l.qty}x ${l.name}').join(', ')
                  : order.itemsRaw,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
            const SizedBox(height: 2),
            Text(
              '${order.created ?? ''}  ·  ${money(order.total)}'
              '${order.createdByName != null ? '  ·  by ${order.createdByName}' : ''}',
              style: const TextStyle(fontSize: 11.5, color: Colors.white38),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetail(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ChangeNotifierProvider.value(
        value: context.read<AppState>(),
        child: _OrderDetailSheet(order: order),
      ),
    );
  }
}

/// One ticket: lines, money, and the actions this stage allows.
class _OrderDetailSheet extends StatelessWidget {
  final FufutOrder order;
  const _OrderDetailSheet({required this.order});

  static const _nextStatus = {
    'new': 'preparing',
    'preparing': 'ready',
    'ready': 'served',
  };

  @override
  Widget build(BuildContext context) {
    final next = _nextStatus[order.status.toLowerCase()];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Order #${order.id}',
                      style: const TextStyle(
                          fontSize: 19, fontWeight: FontWeight.w700)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor(order.status).withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(order.status,
                      style: TextStyle(
                          color: statusColor(order.status),
                          fontWeight: FontWeight.w700,
                          fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${order.type ?? ''}'
              '${order.tableNum != null && order.tableNum!.isNotEmpty ? ' · Table ${order.tableNum}' : ''}'
              '${order.customer != null && order.customer != 'Walk-in' ? ' · ${order.customer}' : ''}'
              '${order.created != null ? ' · ${order.created}' : ''}',
              style: const TextStyle(fontSize: 12.5, color: Colors.white38),
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
                              Text('${l.qty}×'),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _lineLabel(l),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w500),
                                ),
                              ),
                              Text(money(l.lineTotal)),
                            ],
                          ),
                        )
                    else
                      Text(order.itemsRaw.isEmpty
                          ? 'No line detail (legacy order)'
                          : order.itemsRaw),
                    if ((order.notes ?? '').isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A2624),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text('Notes: ${order.notes}'),
                      ),
                    ],
                    const Divider(height: 24),
                    _moneyRow('Subtotal', order.subtotal),
                    if (order.discount > 0)
                      _moneyRow('Discount', -order.discount),
                    if (order.tip > 0) _moneyRow('Tip', order.tip),
                    if (order.deliveryFee > 0)
                      _moneyRow('Delivery', order.deliveryFee),
                    _moneyRow('Total', order.total, bold: true),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (!order.isPaid)
              FilledButton.icon(
                onPressed: () => _settle(context),
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Settle — take payment'),
              ),
            if (next != null)
              OutlinedButton.icon(
                onPressed: () => _advance(context, next),
                icon: const Icon(Icons.arrow_forward),
                label: Text('Mark $next'),
              ),
          ],
        ),
      ),
    );
  }

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

  Widget _moneyRow(String label, double value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label,
              style: TextStyle(
                  color: Colors.white54,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
          const Spacer(),
          Text(money(value),
              style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w500)),
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
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => PaymentSheet(fixedTotal: order.total),
    );
    if (line == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await app.api.settleOrder(order, line.method, line);
      navigator.pop();
      showInfoOn(messenger, 'Tab settled — ${money(line.amount)} via ${line.method}');
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
