/// Kitchen / Barista display — the web POS `KitchenView.vue`, native.
///
/// Open tickets as cards: who/where, elapsed time, the lines, and one primary
/// action per state (Start → Ready → Served). [baristaMode] pins the board to
/// the drinks station: a ticket shows only if it carries a drink line, and it
/// shows only those lines — food tickets stay on the kitchen board.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/roles.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

class KitchenBoard extends StatefulWidget {
  final bool baristaMode;

  const KitchenBoard({super.key, this.baristaMode = false});

  @override
  State<KitchenBoard> createState() => _KitchenBoardState();
}

class _KitchenBoardState extends State<KitchenBoard> {
  List<FufutOrder> _orders = [];
  bool _loading = true;
  Object? _error;
  Timer? _poll;
  // name → category, built from the menu, so pre-category order lines still
  // route to the right station (the web does the same via lib/drinks.js).
  Map<String, String> _catByName = {};

  @override
  void initState() {
    super.initState();
    _load();
    // Boards live on a wall / pass and are never touched; polling keeps them
    // honest without pulling to refresh.
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        app.api.orders(openOnly: true),
        if (widget.baristaMode) app.api.menu() else Future.value(null),
      ]);
      if (!mounted) return;
      final menu = results[1] as List<MenuItem>?;
      setState(() {
        _orders = results[0] as List<FufutOrder>;
        if (menu != null) {
          _catByName = {for (final m in menu) m.name.toLowerCase(): m.category};
        }
        _loading = false;
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

  /// The station's lines of one ticket, with the ticket's own routing rule:
  /// category first (rows stamped since the category migration), name as the
  /// fallback for rows written before categories existed.
  List<OrderItemLine> _stationLines(FufutOrder o) {
    if (!widget.baristaMode) return o.items;
    return o.items
        .where((l) =>
            nameIsDrink(_catByName[l.name.toLowerCase()] ?? '', l.name))
        .toList();
  }

  List<_Ticket> get _tickets {
    final out = <_Ticket>[];
    for (final o in _orders) {
      if (o.isClosed && o.status != 'ready') continue; // cancelled/served drop off
      final lines = _stationLines(o);
      if (lines.isEmpty) continue;
      out.add(_Ticket(order: o, lines: lines));
    }
    // Oldest first — longest wait at the top, exactly the pass's order.
    out.sort((a, b) => (a.order.created ?? '').compareTo(b.order.created ?? ''));
    return out;
  }

  Future<void> _bump(_Ticket t, String to) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.updateStatus(t.order, to);
      showInfoOn(messenger, 'Ticket ${shortId(t.order.id)} → $to');
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _orders.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _orders.isEmpty) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final tickets = _tickets;
    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: tickets.isEmpty
          ? ListView(
              children: [
                const SizedBox(height: 120),
                EmptyState(
                  icon: Icons.restaurant_menu,
                  title: widget.baristaMode
                      ? 'No drink tickets on the board'
                      : 'All quiet on the pass',
                  hint: widget.baristaMode
                      ? 'Drink lines land here the moment a waiter sends them'
                      : 'New kitchen tickets land here the moment a waiter sends them',
                ),
              ],
            )
          : LayoutBuilder(builder: (context, box) {
              // Wall tablets get two columns of tickets; phones one.
              final cols = box.maxWidth >= 760 ? 2 : 1;
              return GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: cols == 2 ? 1.25 : 1.45,
                ),
                itemCount: tickets.length,
                itemBuilder: (context, i) => _TicketCard(
                  ticket: tickets[i],
                  baristaMode: widget.baristaMode,
                  onBump: _bump,
                ),
              );
            }),
    );
  }
}

class _Ticket {
  final FufutOrder order;
  final List<OrderItemLine> lines;
  const _Ticket({required this.order, required this.lines});
}

class _TicketCard extends StatelessWidget {
  final _Ticket ticket;
  final bool baristaMode;
  final Future<void> Function(_Ticket t, String to) onBump;

  const _TicketCard({
    required this.ticket,
    required this.baristaMode,
    required this.onBump,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final o = ticket.order;
    final status = o.status.toLowerCase();
    final elapsed = _elapsed(o.created);
    final urgent = elapsed.inMinutes >= 20;

    return Container(
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: urgent ? pal.danger : pal.border,
            width: urgent ? 1.2 : 1),
      ),
      padding: const EdgeInsets.all(11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: id · table/customer … elapsed
          Row(
            children: [
              Text(shortId(o.id),
                  style: TextStyle(
                      fontFamily: kFontMono,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: pal.heading)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  o.tableNum?.isNotEmpty == true
                      ? 'Table ${o.tableNum}'
                      : (o.customer ?? 'Walk-in'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: pal.muted),
                ),
              ),
              Icon(Icons.timer_outlined,
                  size: 12,
                  color: urgent ? pal.danger : pal.faint),
              const SizedBox(width: 3),
              Text(_fmtElapsed(elapsed),
                  style: TextStyle(
                      fontFamily: kFontMono,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: urgent ? pal.danger : pal.muted)),
            ],
          ),
          if (baristaMode) ...[
            const SizedBox(height: 2),
            Text('Drinks only — food lines stay on the Kitchen screen',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 9.5, color: pal.faint)),
          ],
          const Divider(height: 12),
          // Lines
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final l in ticket.lines)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2.5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${l.qty}×',
                              style: TextStyle(
                                  fontFamily: kFontMono,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: pal.primary)),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                text: l.name,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: pal.heading),
                                children: [
                                  if (l.notes != null &&
                                      l.notes!.trim().isNotEmpty)
                                    TextSpan(
                                        text: '  · ${l.notes}',
                                        style: TextStyle(
                                            fontFamily: kFontBody,
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w500,
                                            color: pal.warning)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // The single next action, per state.
          _actionButton(context, status),
        ],
      ),
    );
  }

  Widget _actionButton(BuildContext context, String status) {
    final pal = Pal.of(context);
    late final String label;
    late final String to;
    late final Color bg;
    switch (status) {
      case 'new':
        label = 'Start preparing';
        to = 'preparing';
        bg = pal.warning;
      case 'preparing':
        label = 'Mark ready';
        to = 'ready';
        bg = pal.primary;
      case 'ready':
        label = 'Mark served';
        to = 'served';
        bg = pal.success;
      default:
        return Align(
          alignment: Alignment.centerRight,
          child: StatusBadge(status: status),
        );
    }
    return SizedBox(
      width: double.infinity,
      height: 32,
      child: FilledButton(
        onPressed: () => onBump(ticket, to),
        style: FilledButton.styleFrom(
          backgroundColor: bg,
          textStyle: const TextStyle(
              fontFamily: kFontBody,
              fontSize: 12,
              fontWeight: FontWeight.w700),
        ),
        child: Text(label),
      ),
    );
  }

  static Duration _elapsed(String? created) {
    if (created == null) return Duration.zero;
    final c = DateTime.tryParse(created);
    if (c == null) return Duration.zero;
    // Server stamps are local-time strings; parse without zone and compare
    // against local now so Addis tickets never read 3h fresh.
    final now = DateTime.now();
    var age = now.difference(c);
    if (age.isNegative) age = Duration.zero;
    return age;
  }

  static String _fmtElapsed(Duration d) {
    final m = d.inMinutes;
    if (m < 60) return '${m}m';
    return '${d.inHours}h${d.inMinutes % 60}m';
  }
}
