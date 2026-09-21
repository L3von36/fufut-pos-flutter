/// Kitchen / Barista display — the web POS `KitchenView.vue`, native.
///
/// Ticket cards with **per-line tracking**: the board polls
/// `GET /api/orders/items/active` alongside the orders, so each line carries
/// its own status (new → preparing → ready → served) and advances on tap.
/// A line tap fires `PUT /api/orders/:id/items/:itemId {status}` — the same
/// endpoint the web uses, so the barista bumping drinks never drags food
/// lines along.
///
/// **Bulk actions** per ticket, mirroring the web columns: "Start All"
/// (every new line → preparing, with a 3-second undo toast), "All Ready"
/// (preparing → ready), "Served" (ready → served). Tickets with no tracked
/// lines fall back to the whole-ticket `PUT /api/orders/:id {status}`.
///
/// **Live via SSE** — the board subscribes to the fufut-api `kitchen` event
/// channel (the web POS's exact wire: `new_order` / `order_update` snapshots
/// carrying the full live order list, first snapshot = baseline). Pushes
/// replace the board within seconds of a waiter sending a ticket and carry
/// the audio: a genuinely new ticket fires the new-order ding + toast, an
/// order crossing into ready fires the chime + toast. The 15s poll survives
/// as a safety net that only runs while the stream is disconnected — when
/// SSE is alive the poll would just duplicate what the server already
/// pushed (the web ships the identical gate). The header shows which one is
/// currently driving the board (Live / Polling).
///
/// **Audio alerts** additionally fire on the 1s clock: any ticket older
/// than 15 minutes gets one critical triple-beep per ticket, exactly like
/// the web's clockTimer (a quiet board emits no SSE events, so only the
/// clock can catch time passing). Mute toggle persists per device.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../api/sse/sse_channel.dart';
import '../models/models.dart';
import '../services/audio_alerts.dart';
import '../services/kitchen_live.dart';
import '../state/app_state.dart';
import '../state/roles.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

class KitchenBoard extends StatefulWidget {
  final bool baristaMode;

  /// Which tab this board instance lives on, and the shell's active-tab
  /// broadcast. The shell keeps visited screens alive under `Offstage`, so
  /// a board that is not on stage must behave like the web's hidden tab:
  /// SSE suspended (Worker connection released), polls and clock silenced —
  /// otherwise a chef who visited both boards pins two connections and
  /// hears every alert twice.
  final ValueListenable<NavKey>? activeTab;
  final NavKey self;

  const KitchenBoard({
    super.key,
    this.baristaMode = false,
    this.activeTab,
    this.self = NavKey.kitchen,
  });

  @override
  State<KitchenBoard> createState() => _KitchenBoardState();
}

class _KitchenBoardState extends State<KitchenBoard>
    with WidgetsBindingObserver {
  List<FufutOrder> _orders = [];
  // orderId → itemId → status, from `GET /api/orders/items/active`.
  Map<String, Map<String, String>> _lineStatus = {};
  bool _loading = true;
  Object? _error;
  Timer? _poll;
  Timer? _clock;
  bool _muted = false;

  // SSE live channel — one per board instance, web useSSE parity.
  final KitchenLive _live = KitchenLive();
  SseChannel? _sse;
  StreamSubscription<SseEvent>? _sseSub;

  // The channel is up only when BOTH gates are open: the app is
  // foregrounded (lifecycle, the web's visibilitychange) and this board is
  // the shell's active tab (Offstage keep-alive — a web route would have
  // been unmounted instead).
  bool _lifecycleUp = true;
  bool _tabUp = true;

  // One critical beep per ticket per lifetime on this board — the web's
  // `_criticalAlerted` flag on each order row.
  final Set<String> _criticalAlerted = {};

  // name → category, built from the menu, so pre-category order lines still
  // route to the right station (the web does the same via lib/drinks.js).
  Map<String, String> _catByName = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _app = context.read<AppState>();
    _tabUp = widget.activeTab?.value == widget.self;
    widget.activeTab?.addListener(_onTabChanged);
    _load();
    if (_tabUp) _connectSse();
    // Refresh fallback: only while SSE is NOT connected — when the stream
    // is alive the server pushes every state change within seconds and a
    // fixed poll would just add latency and duplicate work (the web's own
    // gate in KitchenView.onMounted).
    _poll = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_tabUp) return; // offstage board — silent, suspended
      final sse = _sse;
      if (sse == null || !sse.connected.value) _load(quiet: true);
    });
    // The web's clockTimer: refreshes the elapsed clocks every second and
    // catches tickets crossing the 15-minute critical threshold — a quiet
    // board emits no SSE events, so only the clock can hear time pass.
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _onTabChanged() {
    if (!mounted) return;
    final up = widget.activeTab?.value == widget.self;
    if (up == _tabUp) return;
    _tabUp = up;
    _syncSse();
    if (up) {
      // Back on stage: server truth may have moved while we were dark.
      _load(quiet: true);
    }
  }

  void _syncSse() {
    final sse = _sse;
    if (sse == null) return;
    if (_lifecycleUp && _tabUp) {
      sse.resume(); // no-op when already up
    } else {
      sse.suspend();
    }
  }

  void _connectSse() {
    _sseSub?.cancel();
    _sse?.disconnect();
    final sse = SseChannel(
      baseUrl: _app.baseUrl,
      channel: 'kitchen',
      sessionToken: _app.client.sessionToken,
    );
    _sse = sse;
    _sseSub = sse.stream.listen(_onSseEvent);
    sse.connect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Web visibilitychange parity: hidden tabs pause the stream so a
    // locked tablet never pins a Worker connection it cannot read.
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _lifecycleUp = false;
    } else if (state == AppLifecycleState.resumed) {
      _lifecycleUp = true;
    } else {
      return; // inactive/detached: transient, leave the gates as they are
    }
    _syncSse();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.activeTab?.removeListener(_onTabChanged);
    _poll?.cancel();
    _clock?.cancel();
    _sseSub?.cancel();
    _sse?.disconnect();
    super.dispose();
  }

  /// 1s heartbeat: critical-threshold audio + elapsed clock refresh.
  void _tick() {
    if (!mounted || !_tabUp || _orders.isEmpty) return;
    for (final t in _tickets) {
      final id = t.order.id;
      if (_Ticket.elapsedOf(t.order).inMinutes >= 15 &&
          !_criticalAlerted.contains(id)) {
        _criticalAlerted.add(id);
        AudioAlerts.instance.play(AlertSound.critical);
      }
    }
    setState(() {}); // refresh the elapsed clocks on every ticket card
  }

  void _onSseEvent(SseEvent event) {
    if (!mounted) return;
    if (event.event != 'new_order' && event.event != 'order_update') return;

    final data = event.tryDecodeJson();
    final raw = data?['orders'];
    if (raw is! List) {
      // Payload shape unexpected — fetch instead of rendering a stale board
      // (the web's fallback branch).
      _load(quiet: true);
      return;
    }

    // Parse defensively: one malformed row must never take down the board.
    final fresh = <FufutOrder>[];
    for (final row in raw.whereType<Map>()) {
      try {
        fresh.add(FufutOrder.fromJson(Map<String, dynamic>.from(row)));
      } catch (_) {}
    }

    if (event.event == 'new_order') {
      // The SSE payload already IS the current orders list — applying it
      // directly skips a second round-trip after the waiter's POST, the
      // ticket lands within seconds of "Send to Kitchen" (web parity).
      setState(() {
        _orders = fresh;
        _loading = false;
        _error = null;
      });
      final newId = _live.applyNewOrderSnapshot(fresh);
      if (newId != null) {
        AudioAlerts.instance.play(AlertSound.newOrder);
        if (_messenger != null) {
          showInfoOn(_messenger!, 'New order ${shortId(newId)} on the board');
        }
      }
    } else {
      // order_update — snapshot the ready set BEFORE overwriting, so the
      // chime keys off the transition, not the new state (the event never
      // carries a status field; the web shipped that bug and fixed it here).
      final wasReady =
          _orders.where((o) => o.status.toLowerCase() == 'ready').toList();
      setState(() {
        _orders = fresh;
        _loading = false;
        _error = null;
      });
      final readyId = KitchenLive.newlyReadyIn(wasReady, fresh);
      if (readyId != null) {
        AudioAlerts.instance.play(AlertSound.orderReady);
        if (_messenger != null) {
          showInfoOn(_messenger!, 'Order ${shortId(readyId)} is ready!');
        }
      }
      // No sound for other transitions — the board just re-renders. (The
      // web plays a soft generic blip here; this app's three tones are
      // ding/chime/critical and a silent render is the honest default.)
    }

    // Per-line state is NOT in the SSE payload — one GET refreshes it.
    _refreshLines();
  }

  Future<void> _refreshLines() async {
    try {
      final items = await _app.api.orderItemsActive();
      if (!mounted) return;
      final lineMap = <String, Map<String, String>>{};
      for (final it in items) {
        lineMap.putIfAbsent(it.orderId, () => {})[it.id] = it.status;
      }
      setState(() => _lineStatus = lineMap);
    } catch (_) {
      // The item feed is allowed to fail on its own: tickets still render.
    }
  }

  late AppState _app;

  Future<void> _load({bool quiet = false}) async {
    final app = _app;
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        app.api.orders(openOnly: true),
        app.api.orderItemsActive(),
        if (widget.baristaMode) app.api.menu() else Future.value(null),
      ]);
      if (!mounted) return;
      final menu = results[2] as List<MenuItem>?;
      final items = results[1] as List<ActiveOrderItem>;

      // Per-line status map. Lines the server has not yet stamped keep the
      // ticket's own status.
      final lineMap = <String, Map<String, String>>{};
      for (final it in items) {
        lineMap.putIfAbsent(it.orderId, () => {})[it.id] = it.status;
      }

      setState(() {
        _orders = results[0] as List<FufutOrder>;
        _lineStatus = lineMap;
        if (menu != null) {
          _catByName = {for (final m in menu) m.name.toLowerCase(): m.category};
        }
        _loading = false;
      });
      // NOTE: no audio diff here — the web's loadOrders never sounds.
      // Entrances and ready-transitions are the SSE channel's job; this
      // fetch is data correction only (also after user actions).
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

  ScaffoldMessengerState? _messenger;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.of(context);
    // Settings can re-point the API mid-shift; the channel rebuilds so the
    // stream follows the same base URL the REST calls use.
    final app = context.read<AppState>();
    if (_sse != null && _sse!.baseUrl != app.baseUrl) {
      _app = app;
      _connectSse();
    }
    AudioAlerts.instance.load().then((_) {
      if (mounted) setState(() => _muted = AudioAlerts.instance.muted);
    });
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

  // ── Actions ───────────────────────────────────────────────────────────────

  /// Advance ONE line (`PUT /orders/:id/items/:itemId`).
  Future<void> _advanceLine(_Ticket t, OrderItemLine line, String to) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final itemId = _itemIdFor(t.order, line);
    try {
      HapticFeedback.selectionClick();
      if (itemId != null) {
        await app.api.advanceOrderItem(t.order.id, itemId, to);
      } else {
        // No tracked row (legacy line) — fall back to whole-ticket bump.
        await app.api.updateStatus(t.order, to);
      }
      showInfoOn(messenger, '${line.name} → $to');
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  /// Resolve the server-side item id of a cart line: the tracked rows carry
  /// `line_no`, so we match in order within the ticket.
  String? _itemIdFor(FufutOrder order, OrderItemLine line) {
    // Lines render in the order they appear in `order.items`; the active
    // rows are keyed per order — match by position among station lines.
    final stationLines = _stationLines(order);
    final idx = stationLines.indexOf(line);
    if (idx < 0) return null;
    final rows = _lineStatus[order.id];
    if (rows == null || rows.isEmpty) return null;
    final ids = rows.keys.toList();
    if (idx < ids.length) return ids[idx];
    return null;
  }

  String _statusOfLine(_Ticket t, OrderItemLine line) {
    final itemId = _itemIdFor(t.order, line);
    if (itemId != null) {
      final s = _lineStatus[t.order.id]?[itemId];
      if (s != null) return s;
    }
    return t.order.status.toLowerCase();
  }

  /// Bulk advance every line sitting at [from] to the next step — the web's
  /// `bulkAdvance`: parallel per-line PUTs, wholesale revert on failure, and
  /// a 3-second undo toast on Start All.
  Future<void> _bulkAdvance(_Ticket t, String from, {bool undoable = false}) async {
    const flow = {'new': 'preparing', 'preparing': 'ready', 'ready': 'served'};
    final to = flow[from]!;
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);

    // Lines currently at `from` (tracked rows preferred over the ticket's
    // own status).
    final targets = <String>[]; // item ids
    for (final l in t.lines) {
      if (_statusOfLine(t, l) == from) {
        final id = _itemIdFor(t.order, l);
        if (id != null) targets.add(id);
      }
    }
    try {
      if (targets.isNotEmpty) {
        await Future.wait(
            targets.map((id) => app.api.advanceOrderItem(t.order.id, id, to)));
      } else {
        // No tracked lines — the web's legacy whole-ticket PUT.
        await app.api.updateStatus(t.order, to);
      }
      HapticFeedback.mediumImpact();
      showInfoOn(messenger, 'Ticket ${shortId(t.order.id)} → $to');
      if (undoable && targets.isNotEmpty) {
        showUndoOn(messenger, 'Started ${targets.length} lines', () async {
          try {
            await Future.wait(targets
                .map((id) => app.api.advanceOrderItem(t.order.id, id, 'new')));
            await _load(quiet: true);
          } catch (e) {
            showErrorOn(_messenger ?? messenger, e);
          }
        });
      }
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
      await _load(quiet: true); // wholesale revert to server truth
    }
  }

  Future<void> _toggleMute() async {
    final audio = AudioAlerts.instance;
    await audio.setMuted(!audio.muted);
    if (!mounted) return;
    setState(() => _muted = audio.muted);
    showInfoOn(_messenger ?? ScaffoldMessenger.of(context),
        _muted ? 'Board sounds muted' : 'Board sounds on');
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading && _orders.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _orders.isEmpty) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final tickets = _tickets;
    final pal = Pal.of(context);
    final newN = tickets.where((t) => t.order.status.toLowerCase() == 'new').length;
    final prepN =
        tickets.where((t) => t.order.status.toLowerCase() == 'preparing').length;
    final readyN =
        tickets.where((t) => t.order.status.toLowerCase() == 'ready').length;

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: Column(children: [
        // ── Board summary strip + mute ──────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(children: [
            _countPill(context, 'NEW', newN, pal.info),
            const SizedBox(width: 6),
            _countPill(context, 'PREPARING', prepN, pal.warning),
            const SizedBox(width: 6),
            _countPill(context, 'READY', readyN, pal.primary),
            const Spacer(),
            // What is driving the board right now: the pushed stream or
            // the 15s poll. A wall tablet on flaky Wi-Fi deserves to know
            // why updates feel slow.
            if (_sse != null)
              ValueListenableBuilder<bool>(
                valueListenable: _sse!.connected,
                builder: (context, live, _) {
                  final c = live ? pal.success : pal.faint;
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: live
                          ? pal.success.withValues(alpha: 0.10)
                          : pal.sunken,
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(
                          color: live
                              ? pal.success.withValues(alpha: 0.35)
                              : pal.border),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle, color: c),
                      ),
                      const SizedBox(width: 4),
                      Text(live ? 'Live' : 'Polling',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                              color: live ? pal.success : pal.faint)),
                    ]),
                  );
                },
              ),
            const SizedBox(width: 6),
            InkWell(
              onTap: _toggleMute,
              borderRadius: BorderRadius.circular(99),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: pal.surface,
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: pal.border),
                ),
                child: Row(children: [
                  Icon(_muted ? Icons.volume_off : Icons.volume_up,
                      size: 13, color: _muted ? pal.danger : pal.primary),
                  const SizedBox(width: 4),
                  Text(_muted ? 'Muted' : 'Sound',
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: pal.body)),
                ]),
              ),
            ),
          ]),
        ),
        // ── Tickets grid ────────────────────────────────────────────────
        Expanded(
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
                      statusOfLine: _statusOfLine,
                      onAdvanceLine: _advanceLine,
                      onBulk: _bulkAdvance,
                    ),
                  );
                }),
        ),
      ]),
    );
  }

  Widget _countPill(BuildContext context, String label, int n, Color c) {
    final pal = Pal.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: n > 0 ? c.withValues(alpha: 0.12) : pal.sunken,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$n',
            style: TextStyle(
                fontFamily: kFontMono,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: n > 0 ? c : pal.faint)),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                fontFamily: kFontBody,
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: n > 0 ? c : pal.faint)),
      ]),
    );
  }
}

class _Ticket {
  final FufutOrder order;
  final List<OrderItemLine> lines;
  const _Ticket({required this.order, required this.lines});

  static Duration elapsedOf(FufutOrder o) {
    if (o.created == null) return Duration.zero;
    final c = DateTime.tryParse(o.created!);
    if (c == null) return Duration.zero;
    // Server stamps are local-time strings; parse without zone and compare
    // against local now so Addis tickets never read 3h fresh.
    final now = DateTime.now();
    var age = now.difference(c);
    if (age.isNegative) age = Duration.zero;
    return age;
  }
}

class _TicketCard extends StatelessWidget {
  final _Ticket ticket;
  final bool baristaMode;
  final String Function(_Ticket, OrderItemLine) statusOfLine;
  final Future<void> Function(_Ticket, OrderItemLine, String) onAdvanceLine;
  final Future<void> Function(_Ticket, String, {bool undoable}) onBulk;

  const _TicketCard({
    required this.ticket,
    required this.baristaMode,
    required this.statusOfLine,
    required this.onAdvanceLine,
    required this.onBulk,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final o = ticket.order;
    final status = o.status.toLowerCase();
    final elapsed = _Ticket.elapsedOf(o);
    // Web age classes: warning at 8 min, critical at 15.
    final critical = elapsed.inMinutes >= 15;
    final warning = elapsed.inMinutes >= 8 && !critical;

    return Container(
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: critical
                ? pal.danger
                : (warning ? pal.warning : pal.border),
            width: critical || warning ? 1.2 : 1),
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
                  color: critical
                      ? pal.danger
                      : (warning ? pal.warning : pal.faint)),
              const SizedBox(width: 3),
              Text(_fmtElapsed(elapsed),
                  style: TextStyle(
                      fontFamily: kFontMono,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: critical
                          ? pal.danger
                          : (warning ? pal.warning : pal.muted))),
            ],
          ),
          if (baristaMode) ...[
            const SizedBox(height: 2),
            Text('Drinks only — food lines stay on the Kitchen screen',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 9.5, color: pal.faint)),
          ],
          const Divider(height: 12),
          // Lines — tap to advance, status dot per line.
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final l in ticket.lines)
                    _LineRow(
                      line: l,
                      status: statusOfLine(ticket, l),
                      onTap: () {
                        const flow = {
                          'new': 'preparing',
                          'preparing': 'ready',
                          'ready': 'served',
                        };
                        final s = statusOfLine(ticket, l);
                        final to = flow[s];
                        if (to != null) onAdvanceLine(ticket, l, to);
                      },
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // The bulk action, per state — the web's column buttons.
          _bulkButton(context, status),
        ],
      ),
    );
  }

  Widget _bulkButton(BuildContext context, String status) {
    final pal = Pal.of(context);
    late final String label;
    late final String from;
    late final Color bg;
    bool undoable = false;
    switch (status) {
      case 'new':
        label = 'Start All';
        from = 'new';
        bg = pal.warning;
        undoable = true;
      case 'preparing':
        label = 'All Ready';
        from = 'preparing';
        bg = pal.primary;
      case 'ready':
        label = 'Served';
        from = 'ready';
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
        onPressed: () => onBulk(ticket, from, undoable: undoable),
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

  static String _fmtElapsed(Duration d) {
    final m = d.inMinutes;
    if (m < 60) return '${m}m';
    return '${d.inHours}h${d.inMinutes % 60}m';
  }
}

/// One ticket line with its own status dot — tap advances it one step.
class _LineRow extends StatelessWidget {
  final OrderItemLine line;
  final String status;
  final VoidCallback onTap;

  const _LineRow({required this.line, required this.status, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final Color dotColor;
    switch (status) {
      case 'new':
        dotColor = pal.info;
      case 'preparing':
        dotColor = pal.warning;
      case 'ready':
        dotColor = pal.primary;
      case 'served':
      case 'fulfilled':
        dotColor = pal.success;
      default:
        dotColor = pal.faint;
    }
    final advanced = status == 'served' || status == 'fulfilled';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2.5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.only(top: 5),
              decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
            ),
            const SizedBox(width: 7),
            Text('${line.qty}×',
                style: TextStyle(
                    fontFamily: kFontMono,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: pal.primary)),
            const SizedBox(width: 7),
            Expanded(
              child: Text.rich(
                TextSpan(
                  text: line.name,
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: advanced ? pal.faint : pal.heading),
                  children: [
                    if (line.notes != null && line.notes!.trim().isNotEmpty)
                      TextSpan(
                          text: '  · ${line.notes}',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w500,
                              color: pal.warning)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            Text(status,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: dotColor)),
          ],
        ),
      ),
    );
  }
}
