/// Order Log — today's orders with the full pipeline timeline, per role.
///
/// The per-stage times come from three sources merged here, most exact
/// first:
///
///   * the **Order Journal** (`services/order_journal.dart`) — every device
///     records the stages it performs (till: taken/paid; boards: preparing/
///     ready; floor: picked up / served / table cleared) and echoes what it
///     witnesses over SSE or the feeds (stamped approximate);
///   * the **server's stage columns** — `preparing_at` / `ready_at` /
///     `picked_up_at` / `served_at` are first-time COALESCE stamps on the
///     order row itself, so every role sees every leg even when the action
///     happened on another device (the pending gap the owner reported,
///     2026-09); plus `order.created` / `order.updated_at` and the table's
///     `seated_at` / `bill_requested_at` / `guests`.
///
/// What the screen answers, per role:
///   * the floor  — what time each order was taken, when the bill was asked
///     for, how long it took to clear, how long the guests stayed, party
///     size, and the tip on every order (chips);
///   * the chef   — what time each order came in, how long it sat in New,
///     when prep was clicked, when it went ready, when the waiter picked it
///     up, and how many orders ran today;
///   * the barista — the same clock for the drink tickets;
///   * the cashier — what was settled, when, by which method, and how long
///     the bill took to clear after it was asked for.
///
/// Waiter data isolation applies: floor roles see only the orders they took
/// or that sit on their assigned tables (`orderVisibleToRole`), so one
/// waiter's log is never polluted by a colleague's section.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../services/order_journal.dart';
import '../state/app_state.dart';
import '../state/order_scope.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

/// One resolved pipeline moment: the stage, when it happened (null = still
/// pending), and whether the stamp is approximate.
class _StageStamp {
  final OrderStage stage;
  final DateTime? at;
  final bool approximate;
  const _StageStamp(this.stage, this.at, {this.approximate = false});

  bool get done => at != null;
}

/// A build of the screen's data for one role — scoped orders + tables.
class _LogData {
  final List<FufutOrder> orders;
  final Map<String, CafeTable> tablesByNumber;
  const _LogData(this.orders, this.tablesByNumber);
}

class OrderLogScreen extends ConsumerStatefulWidget {
  const OrderLogScreen({super.key});

  @override
  ConsumerState<OrderLogScreen> createState() => _OrderLogScreenState();
}

class _OrderLogScreenState extends ConsumerState<OrderLogScreen> {
  List<FufutOrder> _orders = [];
  Map<String, CafeTable> _tables = {};
  bool _loading = true;
  Object? _error;
  int _reloadEpoch = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = ref.read(appStateProvider);
    setState(() {
      _loading = true;
      _error = null;
    });
    final epoch = ++_reloadEpoch;
    try {
      // Waiter-class roles need the floor to know which tables are theirs —
      // the same fetch the Orders screen scopes with. Every other role gets
      // the floor too (party size, seated-at, bill-request stamps feed the
      // timeline), best-effort: a role without a tables read still sees its
      // log, just without the table columns.
      final results = await Future.wait([
        app.api.orders(),
        app.api.tables().catchError((_) => const <CafeTable>[]),
      ]);
      if (!mounted || epoch != _reloadEpoch) return;
      final rows = results[0] as List<FufutOrder>;
      final tables = results[1] as List<CafeTable>;

      final myTables = {for (final t in tables) t.number.toString()};
      final scoped = rows
          .where((o) => orderVisibleToRole(o, app.roleKey,
              myId: app.user?.id, myTables: myTables, catByName: app.catByName))
          .where(_orderIsToday)
          .where(_orderBelongsToRole)
          .toList()
        ..sort((a, b) => (b.created ?? '').compareTo(a.created ?? ''));

      setState(() {
        _orders = scoped;
        _tables = {for (final t in tables) t.number.toString(): t};
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted || epoch != _reloadEpoch) return;
      if (e.isAuthError) {
        await app.sessionExpired();
        return;
      }
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted || epoch != _reloadEpoch) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// Server stamps are local-time strings ("2026-08-06 01:55:46"); compare
  /// against the local day, exactly how the boards reason about age.
  bool _orderIsToday(FufutOrder o) {
    final c = DateTime.tryParse(o.created ?? '');
    if (c == null) return false;
    final now = DateTime.now();
    return c.year == now.year && c.month == now.month && c.day == now.day;
  }

  /// The role's slice of the day:
  ///   chefs see food tickets, the barista drink tickets, everyone else the
  ///   whole scoped list (waiter isolation already applied in _load).
  bool _orderBelongsToRole(FufutOrder o) {
    final app = ref.read(appStateProvider);
    switch (app.roleKey) {
      case 'head-chef':
      case 'assistant-chef':
        return _hasStationLines(o, false, app.catByName);
      case 'barista':
        return _hasStationLines(o, true, app.catByName);
      default:
        return true;
    }
  }

  /// The role's slice of the day: chefs see food tickets, the barista drink
  /// tickets — the same strict station routing the boards use (category
  /// first when the menu carries it, name as the legacy fallback).
  bool _hasStationLines(
      FufutOrder o, bool drinks, Map<String, String>? catByName) {
    final lines =
        scopedLines(o, drinks ? 'bar' : 'kitchen', catByName: catByName);
    return lines == null || lines.isNotEmpty; // null = unclassifiable: show it
  }

  CafeTable? _tableFor(FufutOrder o) =>
      o.tableNum == null ? null : _tables[o.tableNum];

  /// Server stamps come in two shapes: the order row's `created` is a local
  /// wall-clock string ("2026-08-06 01:55:46"), the stage columns are UTC ISO
  /// ("2026-09-25T07:12:33.000Z"). Parse both; UTC converts to local.
  DateTime? _serverStamp(String? s) {
    if (s == null || s.isEmpty) return null;
    final d = DateTime.tryParse(s.trim().replaceFirst(' ', 'T'));
    if (d == null) return null;
    return d.isUtc ? d.toLocal() : d;
  }

  /// When did [stage] happen on [o]? The journal's stamp first (this
  /// device's own action, or its echo), then the order row's own stage
  /// column — the server stamps preparing/ready/picked-up/served the first
  /// time a ticket enters each state, so EVERY role sees every leg instead
  /// of waiting on the one device that performed it (the pending gap the
  /// owner reported, 2026-09).
  DateTime? _stageAt(FufutOrder o, OrderStage stage) {
    final journalAt =
        OrderJournal.instance.latestStageAtSync(o.id, stage);
    if (journalAt != null) return journalAt;
    switch (stage) {
      case OrderStage.billRequested:
        final t = _tableFor(o);
        return t != null && t.billRequested ? _serverStamp(t.billRequestedAt) : null;
      case OrderStage.tableCleared:
        return null; // journal-only: freed on the floor, no server column
      default:
        return _serverStamp(switch (stage) {
          OrderStage.created => o.created,
          OrderStage.preparing => o.preparingAt,
          OrderStage.ready => o.readyAt,
          OrderStage.pickedUp => o.pickedUpAt,
          OrderStage.served => o.servedAt,
          OrderStage.paid => o.isPaid ? o.updatedAt : null,
          _ => null,
        });
    }
  }

  /// The order's pipeline timeline — every stage resolved through
  /// [_stageAt]. Only `paid` keeps an approximate flag: its server fallback
  /// (`updated_at`) drifts with any later write, where the stage columns are
  /// first-time COALESCE stamps.
  List<_StageStamp> _timelineFor(FufutOrder o) {
    final journal = OrderJournal.instance;
    final paidJournal = journal.latestStageAtSync(o.id, OrderStage.paid);
    final paidServer = o.isPaid ? _serverStamp(o.updatedAt) : null;
    return [
      for (final s in OrderStage.values)
        s == OrderStage.paid
            ? _StageStamp(OrderStage.paid, paidJournal ?? paidServer,
                approximate: paidJournal == null && paidServer != null)
            : _StageStamp(s, _stageAt(o, s)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = ref.watch(appStateProvider);
    final roleKey = app.roleKey ?? '';

    final body = _loading && _orders.isEmpty
        ? const Center(child: CircularProgressIndicator())
        : _error != null && _orders.isEmpty
            ? LoadError(error: _error!, onRetry: () => _load())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                  children: [
                    _HeaderRow(count: _orders.length, onRefresh: _load),
                    const SizedBox(height: 10),
                    _KpiStrip(
                        data: _LogData(_orders, _tables),
                        roleKey: roleKey,
                        stageAt: _stageAt),
                    const SizedBox(height: 12),
                    if (_orders.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 80),
                        child: Center(
                          child: Text('No orders today yet.',
                              style: TextStyle(
                                  fontFamily: kFontBody,
                                  fontSize: 12.5,
                                  color: Colors.grey)),
                        ),
                      )
                    else
                      for (final o in _orders)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _OrderLogCard(
                            order: o,
                            table: _tableFor(o),
                            timeline: _timelineFor(o),
                            stageAt: _stageAt,
                          ),
                        ),
                  ],
                ),
              );

    return Scaffold(backgroundColor: pal.bg, body: SafeArea(child: body));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widgets
// ─────────────────────────────────────────────────────────────────────────────

class _HeaderRow extends StatelessWidget {
  final int count;
  final Future<void> Function() onRefresh;
  const _HeaderRow({required this.count, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Row(
      children: [
        Text('Today — ${DateTime.now().day}/${DateTime.now().month}',
            style: T.screenTitle.copyWith(color: pal.heading)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: pal.tintBg,
            borderRadius: BorderRadius.circular(99),
          ),
          child: Text('$count orders',
              style: TextStyle(
                  fontFamily: kFontMono,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: pal.primary)),
        ),
        const Spacer(),
        IconButton(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh_rounded, size: 20),
          tooltip: 'Reload',
        ),
      ],
    );
  }
}

/// Role-flavoured day totals. Durations only average over orders that
/// actually have both stamps — a live ticket never drags the average down.
class _KpiStrip extends StatelessWidget {
  final _LogData data;
  final String roleKey;
  final DateTime? Function(FufutOrder, OrderStage) stageAt;
  const _KpiStrip(
      {required this.data, required this.roleKey, required this.stageAt});

  @override
  Widget build(BuildContext context) {
    final orders = data.orders;
    Duration? between(OrderStage a, OrderStage b) {
      var total = Duration.zero;
      var n = 0;
      for (final o in orders) {
        final ta = stageAt(o, a);
        final tb = stageAt(o, b);
        if (ta == null || tb == null || !tb.isAfter(ta)) continue;
        total += tb.difference(ta);
        n++;
      }
      return n == 0 ? null : Duration(milliseconds: total.inMilliseconds ~/ n);
    }

    final tips = orders.fold<double>(0, (s, o) => s + o.tip);
    final paidCount = orders.where((o) => o.isPaid).length;
    final paidTotal =
        orders.where((o) => o.isPaid).fold<double>(0, (s, o) => s + o.total);
    final inNewAvg = between(OrderStage.created, OrderStage.preparing);
    final makeAvg = between(OrderStage.preparing, OrderStage.ready);
    final passAvg = between(OrderStage.ready, OrderStage.pickedUp);
    final billAvg = between(OrderStage.billRequested, OrderStage.paid);

    final cards = <_KpiCard>[
      _KpiCard('${orders.length}', 'orders today', icon: Icons.receipt_long),
      if (paidCount > 0)
        _KpiCard('$paidCount', 'settled · ${_shortMoney(paidTotal)}',
            icon: Icons.payments_outlined),
      if (tips > 0)
        _KpiCard(_shortMoney(tips), 'tips', icon: Icons.volunteer_activism),
      if (inNewAvg != null)
        _KpiCard(_fmtDur(inNewAvg), 'avg in New', icon: Icons.hourglass_top),
      if (makeAvg != null)
        _KpiCard(_fmtDur(makeAvg), 'avg make time', icon: Icons.timer_outlined),
      if (passAvg != null)
        _KpiCard(_fmtDur(passAvg), 'ready → picked up',
            icon: Icons.shopping_bag_outlined),
      if (billAvg != null)
        _KpiCard(_fmtDur(billAvg), 'bill → settled', icon: Icons.request_quote),
    ];

    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: cards.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) => cards[i],
      ),
    );
  }

  static String _shortMoney(double v) =>
      v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : v.toStringAsFixed(0);

  static String _fmtDur(Duration d) {
    final m = d.inMinutes;
    if (m < 60) return '${m}m';
    return '${d.inHours}h${d.inMinutes % 60}m';
  }
}

class _KpiCard extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  const _KpiCard(this.value, this.label, {required this.icon});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      width: 132,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: pal.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(children: [
            Icon(icon, size: 13, color: pal.primary),
            const SizedBox(width: 5),
            Expanded(
              child: Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.mono.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: pal.heading)),
            ),
          ]),
          const SizedBox(height: 3),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontFamily: kFontBody, fontSize: 9.5, color: pal.muted)),
        ],
      ),
    );
  }
}

/// One order's log card: identity row, chips (guests, tip, pay), then the
/// pipeline timeline with per-leg durations.
class _OrderLogCard extends StatelessWidget {
  final FufutOrder order;
  final CafeTable? table;
  final List<_StageStamp> timeline;
  final DateTime? Function(FufutOrder, OrderStage) stageAt;
  const _OrderLogCard({
    required this.order,
    required this.table,
    required this.timeline,
    required this.stageAt,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final o = order;

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: pal.border),
      ),
      padding: const EdgeInsets.all(11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Order #${o.id}',
                    style: T.mono.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: pal.heading)),
              ),
              StatusBadge(status: o.status),
              const SizedBox(width: 5),
              _PayChip(paid: o.payState),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              if ((o.tableNum ?? '').isNotEmpty) 'Table ${o.tableNum}',
              if (o.customer != null && o.customer != 'Walk-in') o.customer!,
              if ((o.createdByName ?? '').isNotEmpty) 'by ${o.createdByName}',
              if ((o.type ?? '').isNotEmpty) o.type!,
            ].join('  ·  '),
            style: TextStyle(
                fontFamily: kFontBody, fontSize: 11, color: pal.muted),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              if (table != null && table!.partySize > 0)
                _Chip(
                  icon: Icons.groups_outlined,
                  text: '${table!.partySize} guests',
                ),
              if (o.tip > 0)
                _Chip(
                  icon: Icons.volunteer_activism,
                  text: 'Tip ${money(o.tip)}',
                  fg: pal.primary,
                  bg: pal.tintBg,
                ),
              if (o.discount > 0)
                _Chip(
                  icon: Icons.sell_outlined,
                  text: '-${money(o.discount)}',
                  fg: pal.success,
                  bg: pal.successBg,
                ),
              _Chip(
                icon: Icons.payments_outlined,
                text: money(o.total),
                fg: pal.heading,
              ),
            ],
          ),
          const Divider(height: 14),
          ..._timelineRows(context),
          if ((o.itemsRaw.isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                o.itemsRaw,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 10.5, color: pal.faint),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _timelineRows(BuildContext context) {
    final pal = Pal.of(context);
    final rows = <Widget>[];
    DateTime? prev;
    for (final s in timeline) {
      rows.add(_TimelineRow(
        stamp: s,
        prevAt: prev,
        last: s == timeline.last,
      ));
      if (s.done) prev = s.at;
    }
    // Guests' stay: seated (table) or created → paid/cleared.
    final stay = _stayDuration();
    if (stay != null) {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
            'Stay: ${_fmtDur(stay.$1)}${stay.$2 ? ' (from order taken)' : ' (seated → settled)'}',
            style: TextStyle(
                fontFamily: kFontBody, fontSize: 10.5, color: pal.faint)),
      ));
    }
    return rows;
  }

  (Duration, bool)? _stayDuration() {
    final end = stageAt(order, OrderStage.paid) ??
        stageAt(order, OrderStage.tableCleared);
    if (end == null) return null;
    final seatedAt = DateTime.tryParse(table?.seatedAt ?? '');
    final start = seatedAt ??
        stageAt(order, OrderStage.created) ??
        DateTime.tryParse(order.created ?? '');
    if (start == null || !end.isAfter(start)) return null;
    return (end.difference(start), seatedAt == null);
  }

  static String _fmtDur(Duration d) {
    final m = d.inMinutes;
    if (m < 60) return '${m}m';
    return '${d.inHours}h${d.inMinutes % 60}m';
  }
}

class _TimelineRow extends StatelessWidget {
  final _StageStamp stamp;
  final DateTime? prevAt;
  final bool last;
  const _TimelineRow(
      {required this.stamp, required this.prevAt, required this.last});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final o = stamp;
    final Color color = switch (o.stage) {
      OrderStage.created => pal.info,
      OrderStage.preparing => pal.warning,
      OrderStage.ready => const Color(0xFF6366F1),
      OrderStage.pickedUp => pal.primary,
      OrderStage.served => pal.success,
      OrderStage.billRequested => pal.gold,
      OrderStage.paid => pal.success,
      OrderStage.tableCleared => pal.muted,
    };

    final String time = o.done
        ? '${o.at!.hour.toString().padLeft(2, '0')}:${o.at!.minute.toString().padLeft(2, '0')}'
        : '—';
    final leg = (o.done && prevAt != null && o.at!.isAfter(prevAt!))
        ? _fmtDur(o.at!.difference(prevAt!))
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        children: [
          Icon(
            o.done ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 13,
            color: o.done ? color : pal.faint,
          ),
          const SizedBox(width: 7),
          SizedBox(
            width: 132,
            child: Text(o.stage.label,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: o.done ? pal.body : pal.faint)),
          ),
          Expanded(
            child: Text(
              o.done ? '$time${o.approximate ? ' (approx)' : ''}' : 'pending',
              style: TextStyle(
                  fontFamily: kFontMono,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: o.done ? pal.heading : pal.faint),
            ),
          ),
          if (leg != null)
            Text(leg,
                style: TextStyle(
                    fontFamily: kFontMono, fontSize: 10.5, color: pal.primary)),
        ],
      ),
    );
  }

  static String _fmtDur(Duration d) {
    final m = d.inMinutes;
    if (m < 60) return '${m}m';
    return '${d.inHours}h${d.inMinutes % 60}m';
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? fg;
  final Color? bg;
  const _Chip({required this.icon, required this.text, this.fg, this.bg});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final color = fg ?? pal.body;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bg ?? pal.sunken,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 4),
        Text(text,
            style: TextStyle(
                fontFamily: kFontMono,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: color)),
      ]),
    );
  }
}

/// Paid / Partly Paid / Unpaid chip for the log cards.
class _PayChip extends StatelessWidget {
  final String paid;
  const _PayChip({required this.paid});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final (bg, fg, label) = switch (paid) {
      'paid' => (pal.successBg, pal.success, 'PAID'),
      'partial' => (
          const Color(0x1A3B82F6),
          const Color(0xFF1D4ED8),
          'PARTLY PAID'
        ),
      _ => (pal.sunken, pal.muted, 'UNPAID'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(label,
          style: TextStyle(
              fontFamily: kFontBody,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
              color: fg)),
    );
  }
}
