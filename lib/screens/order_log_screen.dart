/// Order Log — one day's orders with the full pipeline timeline, per role.
///
/// ONE day per screen (owner's filter rule, 2026-09-25): a chip picks Today,
/// Yesterday or any date, and the fetch rides the same window — today's
/// tickets never share a screen with yesterday's.
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
///     2026-09); plus the bill legs the request-bill endpoint stamps on the
///     ORDER row (migration 028: `bill_requested_at` / `bill_method` /
///     `cleared_at`, and payments' `paid_at`) — the legs a table-only stamp
///     used to lose the moment the party ended; plus `order.created` /
///     `order.updated_at` and the table's `seated_at` / `guests`.
///
/// LIVE, not a page you reload (owner's report, 2026-09-25): the day list is
/// a FutureProvider the shared feeds invalidate — an SSE push (a pickup on
/// the pass, a settle at the till, a bill request on the floor) repaints the
/// screen within seconds — and the journal's revision bell repaints the
/// timelines the instant THIS device stamps something, even before the
/// refetch lands.
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
/// waiter's log is never polluted by a colleague's section. The manager —
/// and every whole-room role — reads EVERY order of the day and gets the
/// staff filter on top: 'All staff' plus one chip per name the day carried,
/// so the owner can read one waiter's day in isolation (owner's ask,
/// 2026-09-25).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../services/order_journal.dart';
import '../state/app_state.dart';
import '../state/app_time.dart';
import '../state/live_feeds.dart';
import '../state/order_scope.dart';
import '../theme.dart';
import '../widgets/backoffice.dart' show ChipSelect;
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

/// One build of the log — today's scoped orders + the floor tables.
class _LogData {
  final List<FufutOrder> orders;
  final Map<String, CafeTable> tablesByNumber;
  const _LogData(this.orders, this.tablesByNumber);
}

/// The role's scoped slice of ONE day, refetched whenever the shared feeds
/// push. Same rules the Orders screen applies: role scoping first (a waiter
/// sees only their tables and tickets), then the station split (chefs cook
/// food, the barista pours drinks), then the day window — all in one place
/// so the screen owns no fetch of its own.
///
/// The provider is a family keyed by the day (`YYYY-MM-DD`): the owner's
/// filter rule (2026-09-25) — today and yesterday never share a screen, the
/// picker decides which day the log reads, and the server fetch rides the
/// same window (`?from=&to=`).
final _orderLogProvider =
    FutureProvider.family<_LogData, String>((ref, dayKey) async {
  // READ, never watch: AppState has a single notify bell and this fetch
  // itself pings it — watching here would rebuild on the provider's echo.
  final app = ref.read(appStateProvider);
  final stationRole =
      const {'barista', 'head-chef', 'assistant-chef'}.contains(app.roleKey);
  if (stationRole) await app.ensureCategories();
  final results = await Future.wait([
    app.api.orders(
      from: dayKey,
      to: dayKey,
    ),
    // The floor feeds the timeline's table columns (party size, seated-at)
    // for every role — best-effort: a role without a tables read still sees
    // its log, just without the table columns.
    app.api.tables().catchError((_) => const <CafeTable>[]),
  ]);
  final rows = results[0] as List<FufutOrder>;
  final tables = results[1] as List<CafeTable>;
  // The waiter's own section (per-row assignment), not the whole room.
  final myTables = assignedTableNumbers(tables,
      myId: app.user?.id, myName: app.user?.displayName);
  final catByName = app.catByName;
  final roleKey = app.roleKey;
  final scoped = rows
      .where((o) => orderVisibleToRole(o, roleKey,
          myId: app.user?.id, myTables: myTables, catByName: catByName))
      // The day rule is the ten-character prefix of the local wall-clock
      // `created` stamp — the same string compare orderIsToday rides, one
      // window per screen instead of a merged week.
      .where((o) => (o.created ?? '').startsWith(dayKey))
      .where((o) => _orderBelongsToRole(o, roleKey, catByName))
      .toList()
    ..sort((a, b) => (b.created ?? '').compareTo(a.created ?? ''));
  return _LogData(scoped, {for (final t in tables) t.number.toString(): t});
});

/// The role's slice of the day: chefs see food tickets, the barista drink
/// tickets — the same strict station routing the boards use (category first
/// when the menu carries it, name as the legacy fallback). Everyone else
/// reads the whole scoped list (waiter isolation already applied above).
bool _orderBelongsToRole(
    FufutOrder o, String? roleKey, Map<String, String>? catByName) {
  switch (roleKey) {
    case 'head-chef':
    case 'assistant-chef':
      return _hasStationLines(o, false, catByName);
    case 'barista':
      return _hasStationLines(o, true, catByName);
    default:
      return true;
  }
}

bool _hasStationLines(
    FufutOrder o, bool drinks, Map<String, String>? catByName) {
  final lines = scopedLines(o, drinks ? 'bar' : 'kitchen', catByName: catByName);
  return lines == null || lines.isNotEmpty; // null = unclassifiable: show it
}

class OrderLogScreen extends ConsumerStatefulWidget {
  const OrderLogScreen({super.key});

  @override
  ConsumerState<OrderLogScreen> createState() => _OrderLogScreenState();
}

class _OrderLogScreenState extends ConsumerState<OrderLogScreen> {
  /// The day the log reads — Today by default, Yesterday and any picked
  /// date one chip away (the owner's day-filter rule, 2026-09-25).
  String _day = localTodayKey();

  /// The staff filter — whose orders the log shows (owner's 2026-09-25
  /// ask: the manager reads every order AND filters by user). The value is
  /// the order's `created_by` id; null shows everyone. Meaningless on a
  /// waiter's own log (isolation already narrowed it), so the row renders
  /// only where the whole room is in scope.
  String? _userFilter;

  /// Live push — the same pattern the Orders screen rides: a change on any
  /// shared feed (a settle, a serve, a bill request, a new ticket anywhere
  /// in the building) debounces an invalidate of this screen's scoped GET.
  /// The screen owns no socket and no fetch; it just watches.
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // The journal's bell is a ValueNotifier, not a provider — listen directly
    // so a stage stamped on THIS device (a pickup on the board, a settle at
    // the till) repaints the timelines the moment it lands.
    OrderJournal.instance.revision.addListener(_onJournalTick);
  }

  /// The journal reads synchronously in build, so a local stamp repaints
  /// with a plain setState — no refetch, the timeline fills the same frame.
  void _onJournalTick() {
    if (mounted) setState(() {});
  }

  void _debouncedReload() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) ref.invalidate(_orderLogProvider);
    });
  }

  @override
  void dispose() {
    OrderJournal.instance.revision.removeListener(_onJournalTick);
    _debounce?.cancel();
    super.dispose();
  }

  CafeTable? _tableFor(_LogData data, FufutOrder o) =>
      o.tableNum == null ? null : data.tablesByNumber[o.tableNum];

  /// Server stamps come in two shapes: the order row's `created` is a local
  /// wall-clock string ("2026-08-06 01:55:46"), the stage columns are UTC ISO
  /// ("2026-09-25T07:12:33.000Z"). app_time's [parseStamp] reads both; UTC
  /// converts to local, so every clock here reads the venue's wall.
  DateTime? _serverStamp(String? s) => parseStamp(s);

  /// When did [stage] happen on [o]? The journal's stamp first (this
  /// device's own action, or its echo), then the order row's own stage
  /// column — the server stamps preparing/ready/picked-up/served the first
  /// time a ticket enters each state, and (migration 028) the bill legs:
  /// `bill_requested_at` / `bill_method` land on the OPEN CHECKS at request
  /// time, `cleared_at` when the party ends, `paid_at` when the money
  /// settles — so EVERY role sees every leg instead of waiting on the one
  /// device that performed it (the pending gap the owner reported, 2026-09).
  DateTime? _stageAt(_LogData data, FufutOrder o, OrderStage stage) {
    final journalAt =
        OrderJournal.instance.latestStageAtSync(o.id, stage);
    if (journalAt != null) return journalAt;
    switch (stage) {
      case OrderStage.billRequested:
        // The order row's own stamp first — it survives the sitting; the
        // table's stamp is only for a request still standing.
        if ((o.billRequestedAt ?? '').isNotEmpty) {
          return _serverStamp(o.billRequestedAt);
        }
        final t = _tableFor(data, o);
        return t != null && t.billRequested ? _serverStamp(t.billRequestedAt) : null;
      case OrderStage.tableCleared:
        if ((o.clearedAt ?? '').isNotEmpty) return _serverStamp(o.clearedAt);
        return null; // journal fallback: freed on the floor, legacy rows
      default:
        return _serverStamp(switch (stage) {
          OrderStage.created => o.created,
          OrderStage.preparing => o.preparingAt,
          OrderStage.ready => o.readyAt,
          OrderStage.pickedUp => o.pickedUpAt,
          OrderStage.served => o.servedAt,
          OrderStage.paid =>
            o.isPaid ? (o.paidAt ?? o.updatedAt) : null,
          _ => null,
        });
    }
  }

  /// The order's pipeline timeline — every stage resolved through
  /// [_stageAt]. Only `paid` keeps an approximate flag: its server fallback
  /// (`updated_at`) drifts with any later write, where `paid_at` and the
  /// stage columns are first-time COALESCE stamps.
  List<_StageStamp> _timelineFor(_LogData data, FufutOrder o) {
    final journal = OrderJournal.instance;
    final paidJournal = journal.latestStageAtSync(o.id, OrderStage.paid);
    final paidServer = _serverStamp(o.isPaid ? (o.paidAt ?? o.updatedAt) : null);
    return [
      for (final s in OrderStage.values)
        s == OrderStage.paid
            ? _StageStamp(OrderStage.paid, paidJournal ?? paidServer,
                approximate: paidJournal == null && paidServer != null)
            : _StageStamp(s, _stageAt(data, o, s)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = ref.watch(appStateProvider);
    final roleKey = app.roleKey ?? '';
    final logAsync = ref.watch(_orderLogProvider(_day));
    // Live push from every shared feed — the journal's own bell rides
    // initState's listener above.
    ref.listen(kitchenFeedProvider, (_, __) => _debouncedReload());
    ref.listen(tablesFeedProvider, (_, __) => _debouncedReload());

    final data = logAsync.value ??
        const _LogData([], {});
    // The staff dimension: every name the day's orders carry, most active
    // first. The manager (and every whole-room role) gets the filter; the
    // waiter's log is already their own — isolation narrowed it.
    final canFilterByUser = roleKey != 'head-waiter';
    final staff = <String, String>{}; // id → display name
    for (final o in data.orders) {
      final id = o.createdById ?? '';
      final name = (o.createdByName ?? '').trim();
      if (id.isEmpty || name.isEmpty) continue;
      staff[id] = name;
    }
    final staffIds = staff.keys.toList();
    final shown = _userFilter == null || !staffIds.contains(_userFilter)
        ? data.orders
        : data.orders
            .where((o) => (o.createdById ?? '') == _userFilter)
            .toList();
    final body = logAsync.isLoading && data.orders.isEmpty
        ? const Center(child: CircularProgressIndicator())
        : logAsync.hasError && data.orders.isEmpty
            ? LoadError(
                error: '${logAsync.error}',
                onRetry: () => ref.invalidate(_orderLogProvider))
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(_orderLogProvider),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                  children: [
                    _DayFilterRow(
                      day: _day,
                      onDay: (d) => setState(() => _day = d),
                      onPick: _pickDay,
                    ),
                    if (canFilterByUser && staff.length >= 2) ...[
                      const SizedBox(height: 4),
                      _UserFilterRow(
                        staff: staff,
                        selected: _userFilter,
                        onChanged: (v) =>
                            setState(() => _userFilter = v.isEmpty ? null : v),
                      ),
                    ],
                    const SizedBox(height: 4),
                    _HeaderRow(
                        day: _day,
                        count: shown.length,
                        onRefresh: () async {
                          ref.invalidate(_orderLogProvider);
                        }),
                    const SizedBox(height: 10),
                    _KpiStrip(
                        data: _LogData(shown, data.tablesByNumber),
                        roleKey: roleKey,
                        stageAt: (o, s) => _stageAt(data, o, s)),
                    const SizedBox(height: 12),
                    if (shown.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 80),
                        child: Center(
                          child: Text(
                              _userFilter == null
                                  ? 'No orders on this day.'
                                  : 'No orders by ${staff[_userFilter] ?? 'this staff'} on this day.',
                              style: const TextStyle(
                                  fontFamily: kFontBody,
                                  fontSize: 12.5,
                                  color: Colors.grey)),
                        ),
                      )
                    else
                      for (final o in shown)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _OrderLogCard(
                            order: o,
                            table: _tableFor(data, o),
                            timeline: _timelineFor(data, o),
                            stageAt: (o, s) => _stageAt(data, o, s),
                          ),
                        ),
                  ],
                ),
              );

    return Scaffold(backgroundColor: pal.bg, body: SafeArea(child: body));
  }

  /// The calendar picker behind the 'Pick a day' chip — any day the venue
  /// has served, never merged with its neighbours.
  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse('${_day}T00:00:00') ?? DateTime.now(),
      firstDate: DateTime.now().add(const Duration(days: -90)),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _day = fmtDay(picked));
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widgets
// ─────────────────────────────────────────────────────────────────────────────

/// The day filter — Today / Yesterday / Pick a day, one window per screen.
/// The owner's rule (2026-09-25): a day's log reads that day alone.
class _DayFilterRow extends StatelessWidget {
  final String day;
  final ValueChanged<String> onDay;
  final VoidCallback onPick;
  const _DayFilterRow(
      {required this.day, required this.onDay, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final today = localTodayKey();
    final yday = localTodayKey(DateTime.now().add(const Duration(days: -1)));
    final value = day == today
        ? 'today'
        : day == yday
            ? 'yday'
            : 'pick';
    return ChipSelect(
      value: value,
      options: const [
        ('today', 'Today'),
        ('yday', 'Yesterday'),
        ('pick', 'Pick a day'),
      ],
      onChanged: (v) {
        if (v == 'today') {
          onDay(today);
        } else if (v == 'yday') {
          onDay(yday);
        } else {
          onPick();
        }
      },
    );
  }
}

/// The staff filter — 'All staff' plus every name the day's orders carry
/// (owner's 2026-09-25 ask: the manager reads every order and filters by
/// user). Client-side on purpose: the day's scoped list is already in hand,
/// and the chip row disappears when a single person fired the day.
class _UserFilterRow extends StatelessWidget {
  final Map<String, String> staff; // created_by id → display name
  final String? selected;
  final ValueChanged<String> onChanged;
  const _UserFilterRow(
      {required this.staff, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final entries = staff.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return ChipSelect(
      value: selected ?? '',
      options: [
        ('', 'All staff'),
        for (final e in entries) (e.key, e.value),
      ],
      onChanged: onChanged,
    );
  }
}

class _HeaderRow extends StatelessWidget {
  final String day;
  final int count;
  final Future<void> Function() onRefresh;
  const _HeaderRow(
      {required this.day, required this.count, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final today = localTodayKey();
    final yday = localTodayKey(DateTime.now().add(const Duration(days: -1)));
    final label = day == today
        ? 'Today — ${DateTime.now().day}/${DateTime.now().month}'
        : day == yday
            ? 'Yesterday'
            : '${day.substring(8, 10)}/${day.substring(5, 7)}';
    return Row(
      children: [
        Text(label, style: T.screenTitle.copyWith(color: pal.heading)),
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

  /// app_time's one elapsed shape — '42m' / '1h07m'.
  static String _fmtDur(Duration d) => fmtDur(d);
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
              // What the guest told the floor they would pay with, stamped at
              // bill-request time — the cashier's heads-up on the log card.
              if ((o.billMethod ?? '').isNotEmpty)
                _Chip(
                  icon: Icons.payment_outlined,
                  text: 'Plans: ${o.billMethod}',
                  fg: pal.primary,
                  bg: pal.tintBg,
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

  /// app_time's one elapsed shape — '42m' / '1h07m'.
  static String _fmtDur(Duration d) => fmtDur(d);
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

    final String time = o.done ? fmtClock(o.at!) : '—';
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

  /// app_time's one elapsed shape — '42m' / '1h07m'.
  static String _fmtDur(Duration d) => fmtDur(d);
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
