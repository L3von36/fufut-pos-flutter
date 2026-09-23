/// Kitchen / Barista display — the web POS `KitchenView.vue`, native,
/// redesigned on the owner's 2026-09 brief ("ui ux pro max").
///
/// Ticket cards with **per-line tracking**: the board polls
/// `GET /api/orders/items/active` alongside the orders, so each line carries
/// its own status (new → preparing → ready) and advances on tap. A line tap
/// fires `PUT /api/orders/:id/items/:itemId {status}` — the same endpoint
/// the web uses, so the barista bumping drinks never drags food lines along.
/// Lines END at ready: the handoff is a ticket-level act (below).
///
/// **Bulk actions** per ticket: "Start All" (every new line → preparing,
/// undo toast), "All Ready" (preparing → ready), and — the pass's last word
/// — "Picked up by waiter" (ticket → fulfilled; owner's flow: the kitchen
/// hands off, the floor serves, the board clears). Tickets with no tracked
/// lines fall back to the whole-ticket `PUT /api/orders/:id {status}`.
///
/// **Today only** — the board is the service day's work surface. Open
/// tickets stamped before today drop off (they used to sit there forever:
/// an open-but-stale split order lingered on the pass for days); a count of
/// the hidden earlier tickets shows so nothing silently vanishes.
///
/// **Live via SSE** — the board subscribes to the fufut-api `kitchen` event
/// channel (the web POS's exact wire: `new_order` / `order_update` snapshots
/// carrying the full live order list, first snapshot = baseline). Pushes
/// replace the board within seconds of a waiter sending a ticket and carry
/// the audio: a genuinely new ticket fires the new-order ding + toast, an
/// order crossing into ready fires the chime + toast. The 15s poll survives
/// as a safety net that only runs while the stream is disconnected. The
/// header shows which one is currently driving the board (Live / Polling).
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
import '../state/order_scope.dart';
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

  /// Open tickets stamped before today, hidden by the board's today-only
  /// rule — surfaced as a count so nothing silently vanishes.
  int _earlier = 0;

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
      final all = results[0] as List<FufutOrder>;

      // Today only: the board is the service day's work surface. Open
      // tickets from earlier days (a stale split, an abandoned tab) used to
      // sit on the pass forever — they are countable, not actionable here;
      // Open Checks and the till own the money side of an old tab.
      var earlier = 0;
      final todays = <FufutOrder>[];
      for (final o in all) {
        if (orderIsToday(o)) {
          todays.add(o);
        } else {
          earlier++;
        }
      }

      // Per-line status map. Lines the server has not yet stamped keep the
      // ticket's own status.
      final lineMap = <String, Map<String, String>>{};
      for (final it in items) {
        lineMap.putIfAbsent(it.orderId, () => {})[it.id] = it.status;
      }

      setState(() {
        _orders = todays;
        _earlier = earlier;
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
    if (!widget.baristaMode) return boardLines(o);
    return boardLines(o)
        .where((l) =>
            nameIsDrink(_catByName[l.name.toLowerCase()] ?? '', l.name))
        .toList();
  }

  List<_Ticket> get _tickets {
    final out = <_Ticket>[];
    for (final o in _orders) {
      // Closed or handed off (fulfilled = picked up by the floor) drops off
      // the pass — the board is cooking work, not an archive.
      if (o.isClosed || o.status.toLowerCase() == 'fulfilled') continue;
      final lines = _stationLines(o);
      if (lines.isEmpty) continue;
      out.add(_Ticket(order: o, lines: lines));
    }
    // Oldest first — longest wait at the top, exactly the pass's order.
    out.sort((a, b) => (a.order.created ?? '').compareTo(b.order.created ?? ''));
    return out;
  }

  // ── Actions ─────────────────────────────────────────────────────

  /// The pass's last word: hand the ticket to the floor. Ticket-level
  /// fulfilled — the owner's flow has the chef saying "picked up" and the
  /// WAITER saying "served" (Orders screen), so the board never marks a
  /// ticket served.
  Future<void> _pickupTicket(_Ticket t) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      HapticFeedback.mediumImpact();
      await app.api.updateStatus(t.order, 'fulfilled');
      showInfoOn(
          messenger, 'Ticket ${shortId(t.order.id)} picked up by waiter');
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
      await _load(quiet: true); // wholesale revert to server truth
    }
  }

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

  /// Bulk advance every line sitting at [from] to the next step — parallel
  /// per-line PUTs, wholesale revert on failure, and an undo toast on Start
  /// All. Lines stop at ready: the handoff is the ticket-level pickup.
  Future<void> _bulkAdvance(_Ticket t, String from, {bool undoable = false}) async {
    const flow = {'new': 'preparing', 'preparing': 'ready'};
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
        // ── Board summary: the three lanes, glanceable from across the pass.
        // The lanes wrap inside an Expanded so a narrow phone never
        // overflows — the Live/Sound controls stay fixed at the right. ──
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _laneChip(
                        context, Icons.fiber_new_rounded, 'NEW', newN, pal.info),
                    _laneChip(context, Icons.soup_kitchen_rounded, 'PREPARING',
                        prepN, pal.warning),
                    _laneChip(
                        context,
                        Icons.notifications_active_rounded,
                        'READY',
                        readyN,
                        pal.primary),
                  ],
                ),
              ),
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
        // ── Earlier-ticket note — today-only hides stale open tickets, but
        // they are counted so nothing silently vanishes from the pass. ──
        if (_earlier > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 7, 12, 0),
            child: InfoBanner(
              '$_earlier open ticket${_earlier == 1 ? '' : 's'} from previous '
              'day${_earlier == 1 ? '' : 's'} hidden — settle or clear them '
              'from Open Checks.',
              severity: InfoSeverity.warning,
              icon: Icons.history_rounded,
            ),
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
                      onPickup: _pickupTicket,
                    ),
                  );
                }),
        ),
      ]),
    );
  }

  /// One lane of the pass — count first (readable across the kitchen), label
  /// under it, tinted only while the lane actually holds work.
  Widget _laneChip(
      BuildContext context, IconData icon, String label, int n, Color c) {
    final pal = Pal.of(context);
    final active = n > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: active ? c.withValues(alpha: 0.13) : pal.sunken,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
            color: active ? c.withValues(alpha: 0.45) : pal.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: active ? c : pal.faint),
        const SizedBox(width: 4),
        Text('$n',
            style: TextStyle(
                fontFamily: kFontMono,
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
                color: active ? c : pal.faint)),
        const SizedBox(width: 3),
        Text(label,
            style: TextStyle(
                fontFamily: kFontBody,
                fontSize: 8.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
                color: active ? c : pal.faint)),
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
  final Future<void> Function(_Ticket) onPickup;

  const _TicketCard({
    required this.ticket,
    required this.baristaMode,
    required this.statusOfLine,
    required this.onAdvanceLine,
    required this.onBulk,
    required this.onPickup,
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
    final urgency =
        critical ? pal.danger : (warning ? pal.warning : pal.primary);

    // Cooking progress — done lines over total lines; the pass reads the
    // bar before it reads anything else.
    final done = ticket.lines
        .where((l) =>
            const ['ready', 'served', 'fulfilled'].contains(statusOfLine(ticket, l)))
        .length;
    final total = ticket.lines.length;
    final progress = total == 0 ? 0.0 : done / total;
    final allReady = done == total;

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: critical || warning
                ? urgency.withValues(alpha: 0.55)
                : pal.border,
            width: critical || warning ? 1.2 : 1),
        boxShadow: [
          if (critical)
            BoxShadow(
                color: pal.danger.withValues(alpha: 0.10), blurRadius: 10),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The urgency rail — one glance across the pass says which
          // tickets are dying. Color, not text: it reads at 3 metres.
          Container(width: 4, color: urgency),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(11, 10, 11, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header: destination FIRST (what the pass scans for),
                  // id muted, elapsed as a filled pill top-right.
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          o.tableNum?.isNotEmpty == true
                              ? 'Table ${o.tableNum}'
                              : (o.customer ?? 'Walk-in'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w800,
                              color: pal.heading),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2.5),
                        decoration: BoxDecoration(
                          color: urgency.withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.timer_outlined,
                              size: 11, color: urgency),
                          const SizedBox(width: 3),
                          Text(_fmtElapsed(elapsed),
                              style: TextStyle(
                                  fontFamily: kFontMono,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: urgency)),
                        ]),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(shortId(o.id),
                      style: TextStyle(
                          fontFamily: kFontMono,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: pal.faint)),
                  if (baristaMode) ...[
                    const SizedBox(height: 2),
                    Text('Drinks only — food lines stay on the Kitchen screen',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 9.5,
                            color: pal.faint)),
                  ],
                  const SizedBox(height: 7),
                  // Cooking progress — n of m ready, hairline bar.
                  Row(children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 3,
                          backgroundColor: pal.sunken,
                          valueColor: AlwaysStoppedAnimation(urgency),
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text('$done/$total ready',
                        style: TextStyle(
                            fontFamily: kFontMono,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            color: allReady ? pal.success : pal.muted)),
                  ]),
                  const SizedBox(height: 5),
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
                  // The bulk action, per state. Lines end at ready — the
                  // handoff is the ticket-level pickup.
                  allReady && status == 'ready'
                      ? SizedBox(
                          width: double.infinity,
                          height: 36,
                          child: FilledButton.icon(
                            onPressed: () => onPickup(ticket),
                            style: FilledButton.styleFrom(
                              backgroundColor: pal.success,
                              textStyle: const TextStyle(
                                  fontFamily: kFontBody,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800),
                            ),
                            icon: const Icon(Icons.outbox_rounded, size: 16),
                            label: const Text('Picked up by waiter'),
                          ),
                        )
                      : _bulkButton(context, status),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bulkButton(BuildContext context, String status) {
    final pal = Pal.of(context);
    late final String label;
    late final String from;
    late final Color bg;
    late final IconData icon;
    bool undoable = false;
    switch (status) {
      case 'new':
        label = 'Start All';
        from = 'new';
        bg = pal.warning;
        icon = Icons.play_arrow_rounded;
        undoable = true;
      case 'preparing':
        label = 'All Ready';
        from = 'preparing';
        bg = pal.primary;
        icon = Icons.done_all_rounded;
      default:
        return Align(
          alignment: Alignment.centerRight,
          child: StatusBadge(status: status),
        );
    }
    return SizedBox(
      width: double.infinity,
      height: 36,
      child: FilledButton.icon(
        onPressed: () => onBulk(ticket, from, undoable: undoable),
        style: FilledButton.styleFrom(
          backgroundColor: bg,
          textStyle: const TextStyle(
              fontFamily: kFontBody,
              fontSize: 12,
              fontWeight: FontWeight.w800),
        ),
        icon: Icon(icon, size: 16),
        label: Text(label),
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
/// Ready is the line's terminal state (the handoff is ticket-level), so a
/// ready line renders a check and ignores taps.
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
      case 'served':
      case 'fulfilled':
        dotColor = pal.success;
      default:
        dotColor = pal.faint;
    }
    final done = status == 'ready' || status == 'served' || status == 'fulfilled';
    final tappable = status == 'new' || status == 'preparing';

    final row = Padding(
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
                    color: done ? pal.faint : pal.heading,
                    decoration: done ? TextDecoration.lineThrough : null,
                    decorationColor: pal.faint),
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
          if (done)
            Icon(Icons.check_circle_outline_rounded,
                size: 13, color: pal.success)
          else
            Icon(Icons.chevron_right_rounded,
                size: 14, color: tappable ? pal.muted : pal.faint),
        ],
      ),
    );

    if (!tappable) return row;
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(6), child: row);
  }
}
