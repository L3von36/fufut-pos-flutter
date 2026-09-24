/// Kitchen / Barista display — the web POS `KitchenView.vue`, native,
/// rebuilt as a true three-lane KDS on the owner's 2026-09 brief ("the ui
/// is ugly — make it better"):
///
/// **Station routing** — the board is the router. A ticket's lines are
/// classified by menu category first ("Ginger with Honey" and "Flat White"
/// are drinks only through their HOT DRINKS category), item name as the
/// fallback for pre-category rows. The kitchen pass shows FOOD lines only;
/// the bar board shows DRINK lines only; a ticket with none of this
/// station's work never renders here at all. An unclassifiable ticket fails
/// open (renders whole) rather than silently hiding somebody's work.
///
/// **Three lanes** — NEW / PREPARING / READY, the classic pass layout.
/// Wide surfaces (wall tablets ≥840px) show all three columns at once;
/// phones get a lane selector with live counts. A ticket moves lanes the
/// moment its derived status moves (the server recomputes the order status
/// from its tracked lines on every line bump).
///
/// **Per-line tracking** — the board also polls
/// `GET /api/orders/items/active`, so each line carries its own status
/// (new → preparing → ready) and advances on tap. A line tap fires
/// `PUT /api/orders/:id/items/:itemId {status}` — the same endpoint the web
/// uses, so the barista bumping drinks never drags food lines along. Lines
/// END at ready: the handoff is a ticket-level act ("Picked up by waiter",
/// ticket → fulfilled; owner's flow: the kitchen hands off, the floor
/// serves, the board clears). Tickets with no tracked lines fall back to
/// the whole-ticket `PUT /api/orders/:id {status}`. Bulk actions per card:
/// "Start Cooking" (undoable) and "All Ready".
///
/// **Today only** — the board is the service day's work surface. Open
/// tickets stamped before today drop off; a count of the hidden earlier
/// tickets shows so nothing silently vanishes.
///
/// **Live via SSE** — the board subscribes to the fufut-api `kitchen` event
/// channel (`new_order` / `order_update` snapshots carrying the full live
/// order list). Pushes replace the board within seconds of a waiter sending
/// a ticket and carry the audio (ding / chime); the 15s poll survives as a
/// safety net that only runs while the stream is disconnected, and the
/// header shows which one is driving the board (Live / Polling).
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

class KitchenBoard extends ConsumerStatefulWidget {
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
  ConsumerState<KitchenBoard> createState() => _KitchenBoardState();
}

class _KitchenBoardState extends ConsumerState<KitchenBoard>
    with WidgetsBindingObserver {
  List<FufutOrder> _orders = [];
  // orderId → itemId → status, from `GET /api/orders/items/active`.
  Map<String, Map<String, String>> _lineStatus = {};
  // orderId → tracked rows in line_no order — the safe line→id mapping
  // (name first, position second). The positional guess alone was the bug
  // that let one tap move a line the cook never touched.
  Map<String, List<ActiveOrderItem>> _activeItems = {};
  // Line keys and ticket ids with an action in flight — the tap guard and
  // the per-row spinner (button state management, owner's 2026-09 rule).
  final Set<String> _busyLines = {};
  String? _busyTicket;
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

  // Narrow screens show ONE lane at a time behind the selector (wide
  // surfaces show all three columns); NEW is where a shift starts.
  String _lane = 'new';

  // name → category, built from the menu — the station router's lookup.
  // BOTH boards need it: a kitchen pass without it would cook the bar's
  // "Ginger with Honey". Refreshed on every load; the session cache in
  // AppState adopts it so the Orders screen classifies identically.
  Map<String, String> _catByName = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _app = ref.read(appStateProvider);
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
      final byOrder = <String, List<ActiveOrderItem>>{};
      for (final it in items) {
        lineMap.putIfAbsent(it.orderId, () => {})[it.id] = it.status;
        byOrder.putIfAbsent(it.orderId, () => []).add(it);
      }
      setState(() {
        _lineStatus = lineMap;
        _activeItems = byOrder;
      });
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
        // The menu is the station router's lookup table — fetched in BOTH
        // modes and non-fatal: offline or a parse hiccup falls back to the
        // name regex, never to a blank board.
        app.api.menu().catchError((_) => const <MenuItem>[]),
      ]);
      if (!mounted) return;
      final menu = results[2] as List<MenuItem>;
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
      final byOrder = <String, List<ActiveOrderItem>>{};
      for (final it in items) {
        lineMap.putIfAbsent(it.orderId, () => {})[it.id] = it.status;
        byOrder.putIfAbsent(it.orderId, () => []).add(it);
      }

      setState(() {
        _orders = todays;
        _earlier = earlier;
        _lineStatus = lineMap;
        _activeItems = byOrder;
        app.adoptCategories(menu);
        _catByName = app.catByName;
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
    final app = ref.read(appStateProvider);
    if (_sse != null && _sse!.baseUrl != app.baseUrl) {
      _app = app;
      _connectSse();
    }
    AudioAlerts.instance.load().then((_) {
      if (mounted) setState(() => _muted = AudioAlerts.instance.muted);
    });
  }

  /// The station's lines of one ticket — FOOD only on the kitchen pass,
  /// DRINKS only on the bar board. Category first (menu lookup), name as
  /// the fallback for pre-category rows; the same rule the Orders screen
  /// scopes by. A ticket nobody can classify fails OPEN: it renders whole
  /// rather than silently hiding somebody's work behind a parse failure.
  List<OrderItemLine> _stationLines(FufutOrder o) {
    final scoped = scopedLines(
        o, widget.baristaMode ? 'bar' : 'kitchen',
        catByName: _catByName);
    return scoped ?? boardLines(o);
  }

  /// The pass's lane for a ticket — derived from THIS STATION's lines, not
  /// the order's overall status (owner's cross-talk report, 2026-09): on a
  /// mixed ticket the bar bumping its drinks must not drag the kitchen's
  /// card across the pass. The lane is the least-advanced of this
  /// station's lines; untracked tickets fall back to the order status.
  String _laneOf(_Ticket t) {
    final statuses = t.lines
        .map((l) => _statusOfLine(t, l).toLowerCase())
        .toSet();
    if (statuses.isEmpty) {
      final s = t.order.status.toLowerCase();
      return (s == 'preparing' || s == 'ready') ? s : 'new';
    }
    const doneSet = {'ready', 'served', 'fulfilled'};
    if (statuses.every(doneSet.contains)) return 'ready';
    if (statuses.any((s) => s != 'new')) return 'preparing';
    return 'new';
  }

  /// Tickets bucketed per lane, each lane oldest-first (longest wait on
  /// top — exactly the pass's reading order).
  Map<String, List<_Ticket>> get _lanes {
    final lanes = <String, List<_Ticket>>{
      'new': [],
      'preparing': [],
      'ready': [],
    };
    for (final t in _tickets) {
      lanes[_laneOf(t)]!.add(t);
    }
    return lanes;
  }

  /// Every line this station owns has been handed off — the ticket leaves
  /// THIS board even when the order overall is still moving at the other
  /// station (a bar pickup on a mixed ticket must not vanish the kitchen's
  /// food, and the other way round).
  bool _stationDone(_Ticket t) {
    const done = {'served', 'fulfilled'};
    return t.lines.isNotEmpty &&
        t.lines.every((l) => done.contains(_statusOfLine(t, l).toLowerCase()));
  }

  List<_Ticket> get _tickets {
    final out = <_Ticket>[];
    for (final o in _orders) {
      // Closed or handed off (fulfilled = picked up by the floor) drops off
      // the pass — the board is cooking work, not an archive. A served
      // ticket is fully with the floor: gone from every board.
      final s = o.status.toLowerCase();
      if (o.isClosed || s == 'fulfilled' || s == 'served') continue;
      final lines = _stationLines(o);
      if (lines.isEmpty) continue;
      final ticket = _Ticket(order: o, lines: lines);
      if (_stationDone(ticket)) continue;
      out.add(ticket);
    }
    // Oldest first — longest wait at the top, exactly the pass's order.
    out.sort((a, b) => (a.order.created ?? '').compareTo(b.order.created ?? ''));
    return out;
  }

  // ── Actions ─────────────────────────────────────────────────────

  String get _station => widget.baristaMode ? 'bar' : 'kitchen';

  /// The pass's last word: hand the ticket to the floor. Ticket-level
  /// fulfilled, SCOPED to this station — the owner's flow has the chef
  /// saying "picked up" and the WAITER saying "served" (Orders screen), and
  /// service law 4 has the bar's handoff never touch the kitchen's lines
  /// (the server enforces both; the station param makes the intent
  /// explicit). Rethrows after the toast so the button's own state machine
  /// sees the failure too.
  Future<void> _pickupTicket(_Ticket t) async {
    if (_busyTicket != null) return;
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    _busyTicket = t.order.id;
    if (mounted) setState(() {});
    try {
      HapticFeedback.mediumImpact();
      await app.api.updateStatus(t.order, 'fulfilled', station: _station);
      showInfoOn(
          messenger, 'Ticket ${shortId(t.order.id)} picked up by waiter');
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
      await _load(quiet: true); // wholesale revert to server truth
    } finally {
      _busyTicket = null;
      if (mounted) setState(() {});
    }
  }

  /// Advance ONE line (`PUT /orders/:id/items/:itemId`). One tap moves one
  /// line — the owner's 2026-09 report: tapping a single item must never
  /// take its siblings with it. When the ticket HAS tracked rows but this
  /// line cannot be matched to one, we refuse to guess with a whole-ticket
  /// write (that is exactly the bug that moved both stations) — refresh
  /// instead.
  Future<void> _advanceLine(_Ticket t, OrderItemLine line, String to) async {
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    final lineKey = '${t.order.id}/${line.name}/${line.qty}';
    if (_busyLines.contains(lineKey) || _busyTicket != null) return;
    final itemId = _itemIdFor(t.order, line);
    final hasTracked = (_lineStatus[t.order.id] ?? {}).isNotEmpty;
    if (hasTracked && itemId == null) {
      showWarnOn(messenger, 'Could not target that line — refreshing the board');
      await _load(quiet: true);
      return;
    }
    _busyLines.add(lineKey);
    if (mounted) setState(() {});
    try {
      HapticFeedback.selectionClick();
      if (itemId != null) {
        await app.api.advanceOrderItem(t.order.id, itemId, to);
      } else {
        // No tracked rows at all (true legacy ticket) — whole-ticket bump,
        // scoped to this station.
        await app.api.updateStatus(t.order, to, station: _station);
      }
      showInfoOn(messenger, '${line.name} → $to');
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    } finally {
      _busyLines.remove(lineKey);
      if (mounted) setState(() {});
    }
  }

  /// Resolve the server-side item id of a cart line.
  ///
  /// Match by name (and quantity when names collide) first — the tracked
  /// rows carry the same names the cart wrote — and fall back to position
  /// among the ticket's FULL line list only when names cannot decide. The
  /// station lines are a filtered subset (drinks stripped on the kitchen
  /// pass), so a station-index never equals a row index; the drinks-first
  /// ticket was the trap the positional guess fell into.
  String? _itemIdFor(FufutOrder order, OrderItemLine line) {
    final rows = _lineStatus[order.id];
    if (rows == null || rows.isEmpty) return null;
    final tracked = _activeItems[order.id];
    if (tracked != null && tracked.isNotEmpty) {
      final byName = tracked.where((it) => it.name == line.name).toList();
      if (byName.length == 1) return byName.first.id;
      final byNameQty =
          byName.where((it) => it.qty == line.qty).toList();
      if (byNameQty.length == 1) return byNameQty.first.id;
    }
    final allLines = boardLines(order);
    final idx = allLines.indexOf(line);
    if (idx < 0) return null;
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

  /// The line's note, read off the TRACKED row when the ticket's summary
  /// lines carry none of their own — the summary string the server stores
  /// (name/qty/price) never carries notes or allergens; the tracked rows
  /// the boards already match by name do. Without this the amber note line
  /// never rendered on a live ticket.
  String? _notesFor(_Ticket t, OrderItemLine line) {
    if (line.notes != null && line.notes!.trim().isNotEmpty) return line.notes;
    final itemId = _itemIdFor(t.order, line);
    if (itemId == null) return null;
    for (final it in _activeItems[t.order.id] ?? const <ActiveOrderItem>[]) {
      if (it.id == itemId) {
        final n = it.notes?.trim() ?? '';
        return n.isEmpty ? null : n;
      }
    }
    return null;
  }

  /// Bulk advance every line sitting at [from] to the next step — parallel
  /// per-line PUTs, wholesale revert on failure, and an undo toast on Start
  /// All. Lines stop at ready: the handoff is the ticket-level pickup.
  ///
  /// When the ticket HAS tracked rows but none sit at [from], this is a
  /// no-op with a hint — never the whole-ticket fallback (that fallback is
  /// how a barista's card once dragged the kitchen's food forward).
  Future<void> _bulkAdvance(_Ticket t, String from, {bool undoable = false}) async {
    const flow = {'new': 'preparing', 'preparing': 'ready'};
    final to = flow[from]!;
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    if (_busyTicket != null) return;

    // Lines currently at `from` (tracked rows preferred over the ticket's
    // own status).
    final targets = <String>[]; // item ids
    for (final l in t.lines) {
      if (_statusOfLine(t, l) == from) {
        final id = _itemIdFor(t.order, l);
        if (id != null) targets.add(id);
      }
    }
    final hasTracked = (_lineStatus[t.order.id] ?? {}).isNotEmpty;
    if (targets.isEmpty) {
      if (hasTracked) {
        showInfoOn(messenger, 'Nothing at "from" on this ticket');
        return;
      }
      // True legacy ticket (no tracked rows) — whole-ticket bump, scoped.
      _busyTicket = t.order.id;
      if (mounted) setState(() {});
      try {
        await app.api.updateStatus(t.order, to, station: _station);
        HapticFeedback.mediumImpact();
        showInfoOn(messenger, 'Ticket ${shortId(t.order.id)} → $to');
        await _load(quiet: true);
      } catch (e) {
        showErrorOn(messenger, e);
        await _load(quiet: true);
      } finally {
        _busyTicket = null;
        if (mounted) setState(() {});
      }
      return;
    }
    _busyTicket = t.order.id;
    if (mounted) setState(() {});
    try {
      await Future.wait(
          targets.map((id) => app.api.advanceOrderItem(t.order.id, id, to)));
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
    } finally {
      _busyTicket = null;
      if (mounted) setState(() {});
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
    final pal = Pal.of(context);
    final lanes = _lanes;
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final barista = widget.baristaMode;

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: Column(children: [
        _header(pal),
        // ── Earlier-ticket note — today-only hides stale open tickets, but
        // they are counted so nothing silently vanishes from the pass. ──
        if (_earlier > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: InfoBanner(
              '$_earlier open ticket${_earlier == 1 ? '' : 's'} from previous '
              'day${_earlier == 1 ? '' : 's'} hidden — settle or clear them '
              'from Open Checks.',
              severity: InfoSeverity.warning,
              icon: Icons.history_rounded,
            ),
          ),
        // ── Lane selector — phones show one lane at a time (the three
        // columns would be unreadable at 400px); tablets and wall screens
        // get the whole pass at once. ──
        if (!wide)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(
              children: [
                for (var i = 0; i < _kLanes.length; i++) ...[
                  Expanded(
                    child: _laneTab(pal, _kLanes[i], _kLanes[i].count(lanes)),
                  ),
                  if (i < _kLanes.length - 1) const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        // ── The pass ──
        Expanded(
          child: _tickets.isEmpty
              ? ListView(
                  children: [
                    const SizedBox(height: 110),
                    EmptyState(
                      icon: barista
                          ? Icons.local_cafe_rounded
                          : Icons.restaurant_menu,
                      title: barista
                          ? 'No drink tickets on the board'
                          : 'All quiet on the pass',
                      hint: barista
                          ? 'Drink lines land here the moment a waiter sends them'
                          : 'New kitchen tickets land here the moment a waiter sends them',
                    ),
                  ],
                )
              : wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < _kLanes.length; i++) ...[
                          Expanded(
                            child: _LaneColumn(
                              meta: _kLanes[i],
                              tickets: lanes[_kLanes[i].key]!,
                              baristaMode: barista,
                              statusOfLine: _statusOfLine,
                              notesOf: _notesFor,
                              busyLineKeys: _busyLines,
                              busyTicketId: _busyTicket,
                              onAdvanceLine: _advanceLine,
                              onBulk: _bulkAdvance,
                              onPickup: _pickupTicket,
                            ),
                          ),
                          if (i < _kLanes.length - 1)
                            Container(width: 0.5, color: pal.border),
                        ],
                      ],
                    )
                  : _LaneColumn(
                      meta:
                          _kLanes.where((m) => m.key == _lane).first,
                      tickets: lanes[_lane]!,
                      baristaMode: barista,
                      statusOfLine: _statusOfLine,
                      notesOf: _notesFor,
                      busyLineKeys: _busyLines,
                      busyTicketId: _busyTicket,
                      onAdvanceLine: _advanceLine,
                      onBulk: _bulkAdvance,
                      onPickup: _pickupTicket,
                    ),
        ),
      ]),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────

  /// One strip: the station seal, its name and routing rule, then the live
  /// badge and the sound toggle. Reads from across the kitchen at a glance.
  Widget _header(Pal pal) {
    final barista = widget.baristaMode;
    final accent = barista ? pal.gold : pal.primary;
    return Container(
      decoration: BoxDecoration(
        color: pal.surface,
        border: Border(bottom: BorderSide(color: pal.border)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: accent.withValues(alpha: 0.4)),
            ),
            child: Icon(
                barista
                    ? Icons.local_cafe_rounded
                    : Icons.restaurant_rounded,
                size: 19,
                color: accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    barista
                        ? 'Bar · Drinks'
                        : 'Kitchen · The Pass',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: pal.heading)),
                const SizedBox(height: 1),
                Text(
                    barista
                        ? 'Drink tickets — food stays on the Kitchen screen'
                        : 'Food tickets — drinks route to the Bar screen',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 10.5,
                        color: pal.muted)),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
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
        ],
      ),
    );
  }

  /// One selectable lane tab (narrow screens): colored count over label,
  /// tinted only while the lane actually holds work or is selected.
  Widget _laneTab(Pal pal, _LaneMeta meta, int n) {
    final c = _laneColor(meta.key, pal);
    final selected = _lane == meta.key;
    final hot = selected || n > 0;
    return InkWell(
      onTap: () => setState(() => _lane = meta.key),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: selected ? c.withValues(alpha: 0.14) : pal.sunken,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected
                  ? c.withValues(alpha: 0.55)
                  : n > 0
                      ? c.withValues(alpha: 0.3)
                      : pal.border,
              width: selected ? 1.3 : 1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(meta.icon, size: 13, color: hot ? c : pal.faint),
              const SizedBox(width: 4),
              Text('$n',
                  style: TextStyle(
                      fontFamily: kFontMono,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      color: hot ? c : pal.faint)),
            ]),
            const SizedBox(height: 1),
            Text(meta.shortLabel,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 8.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.7,
                    color: hot ? c : pal.faint)),
          ],
        ),
      ),
    );
  }
}

// ── Lane metadata ───────────────────────────────────────────────────────────

class _LaneMeta {
  final String key;
  final String label;
  final String shortLabel;
  final IconData icon;
  const _LaneMeta(this.key, this.label, this.shortLabel, this.icon);

  int count(Map<String, List<_Ticket>> lanes) => lanes[key]!.length;
}

const List<_LaneMeta> _kLanes = [
  _LaneMeta('new', 'NEW', 'NEW', Icons.fiber_new_rounded),
  _LaneMeta('preparing', 'PREPARING', 'PREP',
      Icons.local_fire_department_rounded),
  _LaneMeta('ready', 'READY', 'READY',
      Icons.notifications_active_rounded),
];

Color _laneColor(String key, Pal pal) {
  switch (key) {
    case 'preparing':
      return pal.warning;
    case 'ready':
      return pal.success;
    default:
      return pal.info;
  }
}

// ── One lane column ─────────────────────────────────────────────────────────

class _LaneColumn extends StatelessWidget {
  final _LaneMeta meta;
  final List<_Ticket> tickets;
  final bool baristaMode;
  final String Function(_Ticket, OrderItemLine) statusOfLine;
  final String? Function(_Ticket, OrderItemLine) notesOf;
  final Set<String> busyLineKeys;
  final String? busyTicketId;
  final Future<void> Function(_Ticket, OrderItemLine, String) onAdvanceLine;
  final Future<void> Function(_Ticket, String, {bool undoable}) onBulk;
  final Future<void> Function(_Ticket) onPickup;

  const _LaneColumn({
    required this.meta,
    required this.tickets,
    required this.baristaMode,
    required this.statusOfLine,
    required this.notesOf,
    required this.busyLineKeys,
    required this.busyTicketId,
    required this.onAdvanceLine,
    required this.onBulk,
    required this.onPickup,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final c = _laneColor(meta.key, pal);
    final hot = tickets.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: hot ? c.withValues(alpha: 0.12) : pal.sunken,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: hot ? c.withValues(alpha: 0.4) : pal.border),
            ),
            child: Row(children: [
              Icon(meta.icon, size: 13, color: hot ? c : pal.faint),
              const SizedBox(width: 6),
              Text(meta.label,
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                      color: hot ? c : pal.faint)),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                decoration: BoxDecoration(
                  color: hot ? c.withValues(alpha: 0.16) : pal.surface,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text('${tickets.length}',
                    style: TextStyle(
                        fontFamily: kFontMono,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        color: hot ? c : pal.faint)),
              ),
            ]),
          ),
        ),
        Expanded(
          child: tickets.isEmpty
              ? EmptyState(
                  icon: meta.icon,
                  title: meta.key == 'new'
                      ? (baristaMode
                          ? 'No drink tickets waiting'
                          : 'No new tickets')
                      : meta.key == 'preparing'
                          ? 'Nothing on the fire'
                          : 'Nothing ready yet',
                  hint: meta.key == 'new'
                      ? 'New orders land here the moment the floor sends them'
                      : meta.key == 'preparing'
                          ? 'Tickets you start cooking move into this lane'
                          : 'Finished tickets wait here for the floor to pick them up',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
                  itemCount: tickets.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => _TicketCard(
                    ticket: tickets[i],
                    lane: meta.key,
                    baristaMode: baristaMode,
                    statusOfLine: statusOfLine,
                    notesOf: notesOf,
                    busyLineKeys: busyLineKeys,
                    busyTicketId: busyTicketId,
                    onAdvanceLine: onAdvanceLine,
                    onBulk: onBulk,
                    onPickup: onPickup,
                  ),
                ),
        ),
      ],
    );
  }
}

// ── Ticket card ─────────────────────────────────────────────────────────────

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

  /// Time under the lamp: how long a READY ticket has been waiting for the
  /// floor. Reads the server's ready_at stamp (first time it crossed),
  /// falling back to created for legacy rows.
  static Duration readyElapsedOf(FufutOrder o) {
    final raw = (o.readyAt ?? '').isNotEmpty ? o.readyAt! : o.created;
    if (raw == null) return Duration.zero;
    final c = DateTime.tryParse(raw);
    if (c == null) return Duration.zero;
    final now = DateTime.now();
    var age = now.difference(c);
    if (age.isNegative) age = Duration.zero;
    return age;
  }
}

class _TicketCard extends StatelessWidget {
  final _Ticket ticket;
  final String lane;
  final bool baristaMode;
  final String Function(_Ticket, OrderItemLine) statusOfLine;
  final String? Function(_Ticket, OrderItemLine) notesOf;
  final Set<String> busyLineKeys;
  final String? busyTicketId;
  final Future<void> Function(_Ticket, OrderItemLine, String) onAdvanceLine;
  final Future<void> Function(_Ticket, String, {bool undoable}) onBulk;
  final Future<void> Function(_Ticket) onPickup;

  const _TicketCard({
    required this.ticket,
    required this.lane,
    required this.baristaMode,
    required this.statusOfLine,
    required this.notesOf,
    required this.busyLineKeys,
    required this.busyTicketId,
    required this.onAdvanceLine,
    required this.onBulk,
    required this.onPickup,
  });

  /// This ticket's action key — one tap at a time per ticket (a card mid
  /// request is frozen; the board state owns the flag).
  bool get _busy => busyTicketId == ticket.order.id;

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final o = ticket.order;
    final inReady = lane == 'ready';
    // Cooking lanes clock from creation; the READY lane clocks from the
    // moment the ticket crossed (ready_at) — that is time under the lamp,
    // and it is the floor's delay now.
    final elapsed =
        inReady ? _Ticket.readyElapsedOf(o) : _Ticket.elapsedOf(o);
    final critical = elapsed.inMinutes >= (inReady ? 10 : 15);
    final warning =
        !critical && elapsed.inMinutes >= (inReady ? 5 : 8);
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
    // The station's own progress drives the card's action — NOT the order's
    // overall status (owner's cross-talk report): a mixed ticket's bar card
    // shows the handoff the moment every DRINK is ready, even while the
    // kitchen is still cooking.
    const doneSet = {'ready', 'served', 'fulfilled'};
    final stationStatuses =
        ticket.lines.map((l) => statusOfLine(ticket, l).toLowerCase()).toSet();
    final laneStatus = stationStatuses.every(doneSet.contains)
        ? 'ready'
        : stationStatuses.any((s) => s != 'new')
            ? 'preparing'
            : 'new';

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: critical || warning
                ? urgency.withValues(alpha: 0.55)
                : pal.border,
            width: critical || warning ? 1.3 : 1),
        boxShadow: [
          if (critical)
            BoxShadow(
                color: pal.danger.withValues(alpha: 0.14),
                blurRadius: 14,
                offset: const Offset(0, 3)),
        ],
      ),
      // IntrinsicHeight: the card lives in a lane list (unbounded height),
      // and the urgency rail must stretch to whatever the content's height
      // turns out to be — stretch alone would force h=infinity on children.
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The urgency rail — one glance across the pass says which
            // tickets are dying. Color, not text: it reads at 3 metres.
            Container(width: 5, color: urgency),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header: destination FIRST (what the pass scans for),
                  // elapsed as a filled pill top-right.
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
                              fontSize: 15.5,
                              fontWeight: FontWeight.w800,
                              color: pal.heading),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3.5),
                        decoration: BoxDecoration(
                          color: urgency.withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.timer_outlined,
                              size: 12, color: urgency),
                          const SizedBox(width: 4),
                          Text(_fmtElapsed(elapsed),
                              style: TextStyle(
                                  fontFamily: kFontMono,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: urgency)),
                        ]),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  // Row two: id · line count · (bar) drinks-only marker.
                  Row(
                    children: [
                      Text(shortId(o.id),
                          style: TextStyle(
                              fontFamily: kFontMono,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: pal.faint)),
                      Text('  ·  $total item${total == 1 ? '' : 's'}',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 10.5,
                              color: pal.muted)),
                      if (baristaMode)
                        Text('  ·  drinks only',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 10.5,
                                fontStyle: FontStyle.italic,
                                color: pal.faint)),
                    ],
                  ),
                  const SizedBox(height: 9),
                  // Cooking progress — n of m ready, hairline bar.
                  Row(children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          backgroundColor: pal.sunken,
                          valueColor: AlwaysStoppedAnimation(urgency),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('$done/$total',
                        style: TextStyle(
                            fontFamily: kFontMono,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: allReady ? pal.success : pal.muted)),
                  ]),
                  const SizedBox(height: 7),
                  // Lines — tap to advance, status per line. The card
                  // shrink-wraps (lane lists scroll, the card never clips).
                  for (final l in ticket.lines)
                    _LineRow(
                      line: l,
                      status: statusOfLine(ticket, l),
                      note: notesOf(ticket, l),
                      busy: _busy ||
                          busyLineKeys.contains(
                              '${ticket.order.id}/${l.name}/${l.qty}'),
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
                  const SizedBox(height: 9),
                  // The one action that matters, per lane and per STATION.
                  // Lines end at ready — the handoff is the ticket-level
                  // pickup, and it carries the button's own state (busy,
                  // success) so a slow link never looks like a dead tap.
                  allReady
                      ? SizedBox(
                          width: double.infinity,
                          height: 42,
                          child: AsyncButton(
                            onPressed: () => onPickup(ticket),
                            icon: Icons.outbox_rounded,
                            label: 'Picked up by waiter',
                            background: pal.success,
                          ),
                        )
                      : _bulkButton(context, laneStatus),
                ],
              ),
            ),
          ),
        ],
        ),
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
        label = 'Start Cooking';
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
      height: 42,
      child: AsyncButton(
        onPressed: () => onBulk(ticket, from, undoable: undoable),
        icon: icon,
        label: label,
        background: bg,
      ),
    );
  }

  static String _fmtElapsed(Duration d) {
    final m = d.inMinutes;
    if (m < 60) return '${m}m';
    return '${d.inHours}h${d.inMinutes % 60}m';
  }
}

/// One ticket line with its own status — tap advances it one step. Ready is
/// the line's terminal state (the handoff is ticket-level), so a ready line
/// renders a check and ignores taps. The qty chip and 34px row keep every
/// tap target kitchen-glove friendly.
class _LineRow extends StatelessWidget {
  final OrderItemLine line;
  final String status;
  final String? note;
  final VoidCallback onTap;
  final bool busy;

  const _LineRow({
    required this.line,
    required this.status,
    required this.onTap,
    this.note,
    this.busy = false,
  });

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
    final hasNote = note != null && note!.trim().isNotEmpty;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Qty chip — the first thing a cook's eye catches.
            Container(
              width: 30,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: done ? pal.sunken : pal.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('${line.qty}×',
                  style: TextStyle(
                      fontFamily: kFontMono,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: done ? pal.faint : pal.primary)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                line.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.15,
                    color: done ? pal.faint : pal.heading,
                    decoration:
                        done ? TextDecoration.lineThrough : null,
                    decorationColor: pal.faint),
              ),
            ),
            const SizedBox(width: 6),
            if (busy)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (done)
              Icon(Icons.check_circle_outline_rounded,
                  size: 15, color: pal.success)
            else if (tappable)
              Icon(Icons.chevron_right_rounded,
                  size: 16, color: pal.muted)
            else
              Container(
                width: 7,
                height: 7,
                decoration:
                    BoxDecoration(shape: BoxShape.circle, color: dotColor),
              ),
          ],
        ),
        // Allergens and mods sit on their own amber line — never missed.
        if (hasNote)
          Padding(
            padding: const EdgeInsets.only(left: 38, top: 1),
            child: Row(children: [
              Icon(Icons.priority_high_rounded,
                  size: 10, color: pal.warning),
              const SizedBox(width: 3),
              Expanded(
                child: Text(note!,
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: pal.warning)),
              ),
            ]),
          ),
      ],
    );

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: content,
    );

    if (!tappable || busy) return row;
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(8), child: row);
  }
}
