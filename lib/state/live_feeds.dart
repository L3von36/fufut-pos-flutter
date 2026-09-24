/// Live feeds — one SSE connection per feed, shared by every consumer.
///
/// Before this module, each screen built its own [SseChannel]: the kitchen
/// channel existed four times (kitchen board, barista board, pipeline,
/// orders, plus the floor's ready-chime), the alerts channel twice (banner
/// + dashboard). Two of the six dispose paths only called `suspend()` — the
/// Worker connection outlived logout — and two screens had no app-lifecycle
/// gate at all, so a backgrounded tablet pinned connections it could not
/// read.
///
/// Now each feed owns ONE channel for the whole app and hands out immutable
/// snapshots. Screens watch state; they never touch a socket. The feed:
///  * applies `new_order` / `order_update` snapshots directly (the payload
///    IS the current list — web parity, no second round-trip);
///  * detects transitions client-side ([KitchenLive] rules — first
///    snapshot after connecting is a baseline, never an announcement);
///  * polls as a safety net only while the stream is disconnected;
///  * suspends/resumes with the app lifecycle (the shell's observer calls
///    [KitchenFeedNotifier.appPaused] / [appResumed] — one gate for every
///    feed, replacing the per-screen observers).
///
/// Consumers that make sound (the boards' ding, the floor's chime) gate on
/// `ref.watch(activeTabProvider) == self` themselves: the shared feed
/// serves several screens at once, and only the on-stage one should speak.
///
/// autoDispose (Riverpod's default) is the logout story: the shell
/// unmounts, the last watcher leaves, the feed disposes, the channel
/// disconnects. No manual session hooks.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/sse/sse_channel.dart';
import '../models/models.dart';
import '../services/kitchen_live.dart';
import 'app_state.dart';
import 'floor_plan.dart' show defaultSections, mergeSections;
import 'session_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Kitchen feed — the kitchen event channel's single shared snapshot.
// ─────────────────────────────────────────────────────────────────────────────

/// One immutable snapshot of the kitchen event channel.
class KitchenFeedState {
  /// Every order the server's live snapshot carries — all statuses (the
  /// pipeline's Cancelled/Served lanes need them; the boards filter).
  final List<FufutOrder> orders;

  /// True while the SSE stream is connected ('Live' vs 'Polling' badges).
  final bool connected;

  /// The quota circuit-breaker mode ('normal' | 'conserve' | 'emergency' |
  /// 'critical') — surfaces as the "live updates slowed" notice.
  final String quotaMode;

  /// First fetch not landed yet (initial spinner).
  final bool loading;

  /// Last bootstrap/refresh failure — null once any fetch succeeds.
  final Object? error;

  /// Transition markers for consumers that make sound. Each changes value
  /// exactly when the corresponding transition fires (baseline snapshots
  /// leave them untouched; feed rebuild resets them to null):
  ///  * [lastNewOrderId] — a genuinely-new ticket entered the board;
  ///  * [lastReadyOrderId] — an order crossed into `ready`.
  final String? lastNewOrderId;
  final String? lastReadyOrderId;

  const KitchenFeedState({
    this.orders = const [],
    this.connected = false,
    this.quotaMode = 'normal',
    this.loading = true,
    this.error,
    this.lastNewOrderId,
    this.lastReadyOrderId,
  });

  KitchenFeedState copyWith({
    List<FufutOrder>? orders,
    bool? connected,
    String? quotaMode,
    bool? loading,
    Object? error,
    bool clearError = false,
    String? lastNewOrderId,
    bool clearNewId = false,
    String? lastReadyOrderId,
  }) {
    return KitchenFeedState(
      orders: orders ?? this.orders,
      connected: connected ?? this.connected,
      quotaMode: quotaMode ?? this.quotaMode,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      lastNewOrderId: clearNewId ? null : (lastNewOrderId ?? this.lastNewOrderId),
      lastReadyOrderId: lastReadyOrderId ?? this.lastReadyOrderId,
    );
  }
}

class KitchenFeedNotifier extends Notifier<KitchenFeedState> {
  SseChannel? _channel;
  StreamSubscription<SseEvent>? _sub;
  Timer? _poll;
  Timer? _linesDebounce;
  final KitchenLive _live = KitchenLive();
  bool _appPaused = false;

  static const _pollInterval = Duration(seconds: 15);

  @override
  KitchenFeedState build() {
    ref.onDispose(_teardown);
    _connect();
    _refresh(quiet: true); // bootstrap — the channel may answer first
    return const KitchenFeedState();
  }

  // ── Connection ────────────────────────────────────────────────────────

  void _connect() {
    final app = ref.read(appStateProvider);
    _teardownChannel();
    final ch = SseChannel(
      baseUrl: app.baseUrl,
      channel: 'kitchen',
      sessionToken: app.client.sessionToken,
    );
    _channel = ch;
    ch.connected.addListener(_syncConn);
    ch.quotaMode.addListener(_syncConn);
    _sub = ch.stream.listen(_onEvent);
    ch.connect();
  }

  /// Mirror the channel's ValueNotifiers into watched state.
  void _syncConn() {
    final ch = _channel;
    if (ch == null) return;
    state = state.copyWith(
        connected: ch.connected.value, quotaMode: ch.quotaMode.value);
    if (ch.connected.value) {
      _cancelPoll();
    } else {
      _ensurePoll();
    }
  }

  void _onEvent(SseEvent event) {
    if (event.event != 'new_order' && event.event != 'order_update') return;
    _applySnapshot(event);
    // Per-line status is NOT in the SSE payload — one debounced GET
    // refreshes it (the boards' _refreshLines, now feed-wide).
    _linesDebounce?.cancel();
    _linesDebounce = Timer(const Duration(milliseconds: 400), _bumpLines);
  }

  /// Apply a `new_order` / `order_update` snapshot. The payload already IS
  /// the current orders list — applying it directly skips a round-trip and
  /// the ticket lands within seconds of "Send to Kitchen" (web parity).
  void _applySnapshot(SseEvent event) {
    final data = event.tryDecodeJson();
    final raw = data?['orders'];
    if (raw is! List) {
      // Payload shape unexpected — fetch instead of rendering a stale
      // board (the web's fallback branch).
      _refresh(quiet: true);
      return;
    }
    // Parse defensively: one malformed row must never take down the feed.
    final fresh = <FufutOrder>[];
    for (final row in raw.whereType<Map>()) {
      try {
        fresh.add(FufutOrder.fromJson(Map<String, dynamic>.from(row)));
      } catch (_) {}
    }

    final was = state.orders;
    String? newId;
    String? readyId;
    if (event.event == 'new_order') {
      // First snapshot after connecting is the baseline (KitchenLive's
      // rule) — an opening board never announces every standing ticket.
      newId = _live.applyNewOrderSnapshot(fresh);
    } else {
      // The ready set BEFORE the overwrite decides the chime — the event
      // never carries a status field (the web shipped that bug once).
      readyId = KitchenLive.newlyReadyIn(was, fresh);
    }
    state = state.copyWith(
      orders: fresh,
      loading: false,
      clearError: true,
      lastNewOrderId: newId,
      lastReadyOrderId: readyId,
    );
  }

  // ── Poll fallback ─────────────────────────────────────────────────────

  void _ensurePoll() {
    if (_poll != null || _appPaused) return;
    _poll = Timer.periodic(_pollInterval, (_) {
      if (!state.connected) _refresh(quiet: true);
    });
  }

  void _cancelPoll() {
    _poll?.cancel();
    _poll = null;
  }

  // ── Public surface (screens + shell lifecycle) ────────────────────────

  /// Server-truth refetch — after user actions and pull-to-refresh. Never
  /// sounds: entrances and ready-transitions are the channel's job.
  Future<void> refresh({bool quiet = true}) => _refresh(quiet: quiet);

  Future<void> _refresh({bool quiet = true}) async {
    final app = ref.read(appStateProvider);
    try {
      final rows = await app.api.orders();
      if (!ref.mounted) return;
      state = state.copyWith(
          orders: rows, loading: false, clearError: true);
      _bumpLines();
    } on ApiError catch (e) {
      if (!ref.mounted) return;
      if (e.isAuthError) {
        await app.sessionExpired();
        return;
      }
      state = state.copyWith(loading: false, error: e);
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(loading: false, error: e);
    }
  }

  /// Per-line status is NOT in the SSE payload — one GET refreshes it for
  /// every consumer of [kitchenLinesProvider] at once.
  void _bumpLines() =>
      ref.read(_kitchenLinesTickProvider.notifier).bump();

  /// The pipeline's optimistic drag: move one order locally, server truth
  /// follows on the next push/refresh (revert = [refresh]).
  void applyOptimistic(String orderId, String status) {
    state = state.copyWith(orders: [
      for (final o in state.orders)
        if (o.id == orderId) o.withStatus(status) else o,
    ]);
  }

  /// App went to background — release the connection (web
  /// visibilitychange parity). Called by the shell's lifecycle observer.
  void appPaused() {
    _appPaused = true;
    _cancelPoll();
    _channel?.suspend();
  }

  /// App foregrounded — reconnect and correct from server truth.
  void appResumed() {
    _appPaused = false;
    _channel?.resume();
    _refresh(quiet: true);
  }

  void _teardown() {
    _cancelPoll();
    _linesDebounce?.cancel();
    _teardownChannel();
  }

  void _teardownChannel() {
    _sub?.cancel();
    _sub = null;
    final ch = _channel;
    if (ch != null) {
      ch.connected.removeListener(_syncConn);
      ch.quotaMode.removeListener(_syncConn);
      ch.disconnect();
      _channel = null;
    }
  }
}

final kitchenFeedProvider =
    NotifierProvider<KitchenFeedNotifier, KitchenFeedState>(
        KitchenFeedNotifier.new);

// ── Per-line status (GET /api/orders/items/active) ──────────────────────────

/// Bumped by the feed after every snapshot/refresh; the lines provider
/// watches it and re-fetches. Kept private so only the feed can bump it.
final _kitchenLinesTickProvider =
    NotifierProvider<_LinesTick, int>(_LinesTick.new);

class _LinesTick extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

/// OrderId-keyed tracked rows (`GET /api/orders/items/active`), refreshed
/// by kitchen activity. Allowed to fail on its own: tickets still render.
final kitchenLinesProvider = FutureProvider<List<ActiveOrderItem>>((ref) {
  ref.watch(_kitchenLinesTickProvider);
  return ref.watch(fufutApiProvider).orderItemsActive();
});

// ─────────────────────────────────────────────────────────────────────────────
// Ops alerts feed — the alerts event channel + the 60s safety poll.
// ─────────────────────────────────────────────────────────────────────────────

/// The three buckets the alerts dashboard renders; the banner reads [open].
class OpsAlertsFeedState {
  final List<OpsAlert> open; // critical-first (OpsAlert.rank)
  final List<OpsAlert> acknowledged;
  final List<OpsAlert> resolved;
  final bool connected;
  final String quotaMode;
  final bool loading;
  final Object? error;

  const OpsAlertsFeedState({
    this.open = const [],
    this.acknowledged = const [],
    this.resolved = const [],
    this.connected = false,
    this.quotaMode = 'normal',
    this.loading = true,
    this.error,
  });

  OpsAlertsFeedState copyWith({
    List<OpsAlert>? open,
    List<OpsAlert>? acknowledged,
    List<OpsAlert>? resolved,
    bool? connected,
    String? quotaMode,
    bool? loading,
    Object? error,
    bool clearError = false,
  }) {
    return OpsAlertsFeedState(
      open: open ?? this.open,
      acknowledged: acknowledged ?? this.acknowledged,
      resolved: resolved ?? this.resolved,
      connected: connected ?? this.connected,
      quotaMode: quotaMode ?? this.quotaMode,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class OpsAlertsFeedNotifier extends Notifier<OpsAlertsFeedState> {
  SseChannel? _channel;
  StreamSubscription<SseEvent>? _sub;
  Timer? _poll;
  Timer? _bucketsDebounce;
  bool _appPaused = false;

  static const _pollInterval = Duration(seconds: 60);

  @override
  OpsAlertsFeedState build() {
    ref.onDispose(_teardown);
    _connect();
    _refresh(quiet: true);
    // Always-on poll (web parity): the banner is the only thing watching
    // for breaches, so it keeps its 60s net even while the stream is up.
    _poll = Timer.periodic(_pollInterval, (_) {
      if (!_appPaused) _refresh(quiet: true);
    });
    return const OpsAlertsFeedState();
  }

  void _connect() {
    final app = ref.read(appStateProvider);
    _teardownChannel();
    final ch = SseChannel(
      baseUrl: app.baseUrl,
      channel: 'alerts',
      sessionToken: app.client.sessionToken,
    );
    _channel = ch;
    ch.connected.addListener(_syncConn);
    ch.quotaMode.addListener(_syncConn);
    _sub = ch.stream.listen(_onEvent);
    ch.connect();
  }

  void _syncConn() {
    final ch = _channel;
    if (ch == null) return;
    state = state.copyWith(
        connected: ch.connected.value, quotaMode: ch.quotaMode.value);
  }

  void _onEvent(SseEvent event) {
    if (event.event != 'alerts_update') return;
    final data = event.tryDecodeJson();
    final raw = data?['alerts'];
    if (raw is! List) {
      _refresh(quiet: true);
      return;
    }
    // Parse defensively: one malformed row must never take down the banner.
    final fresh = <OpsAlert>[];
    for (final row in raw.whereType<Map>()) {
      try {
        fresh.add(OpsAlert.fromJson(Map<String, dynamic>.from(row)));
      } catch (_) {}
    }
    fresh.sort(OpsAlert.rank);
    state = state.copyWith(open: fresh);
    // The payload carries the open list only — sync the other buckets
    // quietly so Acknowledged/Resolved stay honest.
    _bucketsDebounce?.cancel();
    _bucketsDebounce = Timer(const Duration(seconds: 1), () {
      if (!_appPaused) _fetchBuckets(quiet: true);
    });
  }

  Future<void> _fetchBuckets({bool quiet = true}) async {
    final app = ref.read(appStateProvider);
    try {
      final results = await Future.wait<dynamic>([
        app.api.alertsByStatus('open', limit: 200),
        app.api.alertsByStatus('acknowledged', limit: 25),
        app.api.alertsByStatus('resolved', limit: 100),
      ]);
      if (!ref.mounted) return;
      final open = (results[0] as List<OpsAlert>)..sort(OpsAlert.rank);
      state = state.copyWith(
        open: open,
        acknowledged: results[1] as List<OpsAlert>,
        resolved: results[2] as List<OpsAlert>,
        loading: false,
        clearError: true,
      );
    } on ApiError catch (e) {
      if (!ref.mounted) return;
      if (e.isAuthError) {
        await app.sessionExpired();
        return;
      }
      if (!quiet) state = state.copyWith(loading: false, error: e);
    } catch (e) {
      if (!ref.mounted) return;
      if (!quiet) state = state.copyWith(loading: false, error: e);
    }
  }

  Future<void> _refresh({bool quiet = true}) => _fetchBuckets(quiet: quiet);

  /// Server-truth refetch (pull-to-refresh, post-ack correctness).
  Future<void> refresh({bool quiet = true}) => _fetchBuckets(quiet: quiet);

  Future<void> ack(OpsAlert a) async {
    final app = ref.read(appStateProvider);
    await app.api.acknowledgeAlert(a.id);
    // Optimistic removal — the poll/push corrects the rest.
    state = state.copyWith(
        open: state.open.where((x) => x.id != a.id).toList());
  }

  Future<void> ackAll() async {
    final app = ref.read(appStateProvider);
    await app.api.acknowledgeAllAlerts();
    state = state.copyWith(open: const []);
  }

  void appPaused() {
    _appPaused = true;
    _poll?.cancel();
    _channel?.suspend();
  }

  void appResumed() {
    _appPaused = false;
    _poll = Timer.periodic(_pollInterval, (_) {
      if (!_appPaused) _refresh(quiet: true);
    });
    _channel?.resume();
    _refresh(quiet: true);
  }

  void _teardown() {
    _poll?.cancel();
    _bucketsDebounce?.cancel();
    _teardownChannel();
  }

  void _teardownChannel() {
    _sub?.cancel();
    _sub = null;
    final ch = _channel;
    if (ch != null) {
      ch.connected.removeListener(_syncConn);
      ch.quotaMode.removeListener(_syncConn);
      ch.disconnect();
      _channel = null;
    }
  }
}

final opsAlertsFeedProvider =
    NotifierProvider<OpsAlertsFeedNotifier, OpsAlertsFeedState>(
        OpsAlertsFeedNotifier.new);

// ─────────────────────────────────────────────────────────────────────────────
// Tables feed — the floor plan's live board ('tables' channel).
// ─────────────────────────────────────────────────────────────────────────────

/// One immutable snapshot of the floor: the tables, the orders the floor
/// still cares about, the merged section list, and the channel state.
class TablesFeedState {
  final List<CafeTable> tables;

  /// Kitchen-flow tickets whatever their payment state, plus
  /// served-but-unpaid tabs (the web's floor filter — a fulfilled ticket
  /// that HAS been paid is history). See [_isFloorRelevant].
  final List<FufutOrder> orders;

  /// Server sections merged over the shipped defaults.
  final List<String> sections;

  /// True while the `tables` stream is connected (the Live/Offline chip).
  final bool connected;

  final bool loading;
  final Object? error;

  const TablesFeedState({
    this.tables = const [],
    this.orders = const [],
    this.sections = defaultSections,
    this.connected = false,
    this.loading = true,
    this.error,
  });

  TablesFeedState copyWith({
    List<CafeTable>? tables,
    List<FufutOrder>? orders,
    List<String>? sections,
    bool? connected,
    bool? loading,
    Object? error,
    bool clearError = false,
  }) {
    return TablesFeedState(
      tables: tables ?? this.tables,
      orders: orders ?? this.orders,
      sections: sections ?? this.sections,
      connected: connected ?? this.connected,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Orders the floor plan still cares about: kitchen-flow tickets whatever
/// their payment state, plus served-but-unpaid tabs. A fulfilled ticket
/// that HAS been paid is history and stays off the board. Filtering
/// 'fulfilled' outright — what the screen once did — is what hid unpaid
/// tabs from "Add Round", the open-tab badge and the detail dialog.
bool _isFloorRelevant(FufutOrder o) {
  final status = o.status.toLowerCase();
  if (status == 'completed' || status == 'cancelled') return false;
  final terminal = status == 'fulfilled' || status == 'served';
  return !(terminal && (o.paymentStatus ?? '').toLowerCase() == 'paid');
}

class TablesFeedNotifier extends Notifier<TablesFeedState> {
  SseChannel? _channel;
  StreamSubscription<SseEvent>? _sub;
  Timer? _poll;
  bool _appPaused = false;

  /// The web's toggle chip: the floor can hang up the live stream itself.
  /// False = channel disconnected on purpose (the poll carries updates).
  bool _live = true;

  static const _pollInterval = Duration(seconds: 15);

  @override
  TablesFeedState build() {
    ref.onDispose(_teardown);
    _bootstrap();
    return const TablesFeedState();
  }

  // ── Bootstrap (the web's onMounted: three feeds, then the channel) ────

  Future<void> _bootstrap() async {
    await Future.wait([_fetchTables(), _fetchOrders()]);
    if (!ref.mounted) return;
    await _fetchSections();
    if (!ref.mounted) return;
    _connect();
  }

  // ── Connection ────────────────────────────────────────────────────────

  void _connect() {
    if (!_live) return;
    final app = ref.read(appStateProvider);
    _teardownChannel();
    final ch = SseChannel(
      baseUrl: app.baseUrl,
      channel: 'tables',
      sessionToken: app.client.sessionToken,
    );
    _channel = ch;
    ch.connected.addListener(_syncConn);
    ch.quotaMode.addListener(_syncConn);
    _sub = ch.stream.listen(_onEvent);
    ch.connect();
  }

  void _syncConn() {
    final ch = _channel;
    if (ch == null) return;
    state = state.copyWith(connected: ch.connected.value);
    if (ch.connected.value) {
      _cancelPoll();
    } else {
      _ensurePoll();
    }
  }

  void _onEvent(SseEvent event) {
    // The web registers table_update → loadTables, new_order/order_update →
    // loadOrders. It refetches rather than applying the payload, so the
    // render is always built from the same GET the web would make.
    switch (event.event) {
      case 'table_update':
        _fetchTables();
        break;
      case 'new_order':
      case 'order_update':
        _fetchOrders();
        break;
    }
  }

  // ── Fetches (each catches its own failures, like the web) ─────────────

  Future<void> _fetchTables() async {
    final app = ref.read(appStateProvider);
    try {
      final rows = await app.api.tables();
      if (!ref.mounted) return;
      state = state.copyWith(tables: rows, clearError: true);
    } on ApiError catch (e) {
      if (!ref.mounted) return;
      if (e.isAuthError) {
        await app.sessionExpired();
        return;
      }
      state = state.copyWith(loading: false, error: e);
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(loading: false, error: e);
    }
  }

  Future<void> _fetchOrders() async {
    final app = ref.read(appStateProvider);
    try {
      final all = await app.api.orders();
      if (!ref.mounted) return;
      state = state.copyWith(
          orders: all.where(_isFloorRelevant).toList());
    } on ApiError catch (e) {
      if (e.isAuthError) await app.sessionExpired();
      // The badges are allowed to fail on their own — the floor still renders.
    } catch (_) {}
  }

  Future<void> _fetchSections() async {
    final app = ref.read(appStateProvider);
    try {
      final serverList = await app.api.tableSections();
      if (!ref.mounted) return;
      final merged = mergeSections(serverList, state.tables);
      if (merged.isNotEmpty) state = state.copyWith(sections: merged);
    } catch (_) {
      // A failed read — the till is offline, the request timed out — is not
      // an error: the last known list (or the defaults) keeps the floor
      // working (the web's loadSections catch).
    }
  }

  // ── Poll fallback ─────────────────────────────────────────────────────

  void _ensurePoll() {
    if (_poll != null || _appPaused) return;
    _poll = Timer.periodic(_pollInterval, (_) {
      if (!state.connected) {
        _fetchTables();
        _fetchOrders();
      }
    });
  }

  void _cancelPoll() {
    _poll?.cancel();
    _poll = null;
  }

  /// The optimistic bill-request stamp — patch one row locally, server
  /// truth follows on the next push/refresh.
  void patchTableLocal(CafeTable patched) {
    state = state.copyWith(tables: [
      for (final t in state.tables)
        if (t.id == patched.id) patched else t,
    ]);
  }

  // ── Public surface ────────────────────────────────────────────────────

  Future<void> refreshTables() => _fetchTables();
  Future<void> refreshOrders() => _fetchOrders();
  Future<void> refreshSections() => _fetchSections();

  /// Pull-to-refresh: tables + orders + sections, one pass.
  Future<void> refreshAll() async {
    await Future.wait([_fetchTables(), _fetchOrders()]);
    if (!ref.mounted) return;
    await _fetchSections();
  }

  /// The Live/Offline chip: hang up (or re-open) the tables stream. The
  /// poll carries updates while offline — the web's toggleSSE, minus the
  /// kitchen channel (the ready chime now rides the shared kitchen feed).
  void setLive(bool on) {
    _live = on;
    if (on) {
      _connect();
    } else {
      _teardownChannel();
      _ensurePoll();
      state = state.copyWith(connected: false);
    }
  }

  void appPaused() {
    _appPaused = true;
    _cancelPoll();
    _channel?.suspend();
  }

  void appResumed() {
    _appPaused = false;
    _channel?.resume();
    _fetchTables();
    _fetchOrders();
  }

  void _teardown() {
    _cancelPoll();
    _teardownChannel();
  }

  void _teardownChannel() {
    _sub?.cancel();
    _sub = null;
    final ch = _channel;
    if (ch != null) {
      ch.connected.removeListener(_syncConn);
      ch.quotaMode.removeListener(_syncConn);
      ch.disconnect();
      _channel = null;
    }
  }
}

final tablesFeedProvider =
    NotifierProvider<TablesFeedNotifier, TablesFeedState>(
        TablesFeedNotifier.new);

// ── Guest QR orders waiting for a floor Accept ──────────────────────────────

/// The pending strip's list — a 30s poll, no SSE (guest orders are rare and
/// the strip is deliberately loud when one lands). On error the list
/// empties quietly and the next poll retries (the web's loadPending catch).
class PendingOrdersNotifier extends Notifier<List<FufutOrder>> {
  Timer? _poll;
  bool _appPaused = false;

  static const _interval = Duration(seconds: 30);

  @override
  List<FufutOrder> build() {
    ref.onDispose(_teardown);
    _poll = Timer.periodic(_interval, (_) {
      if (!_appPaused) _fetch();
    });
    _fetch();
    return const [];
  }

  Future<void> _fetch() async {
    final app = ref.read(appStateProvider);
    try {
      final rows = await app.api.pendingOrders();
      if (!ref.mounted) return;
      state = rows;
    } catch (_) {
      // A waiter cannot act on this failing, and the floor plan itself is
      // the important thing on this screen — stay quiet, retry on the next
      // poll (the web's loadPending catch).
      if (!ref.mounted) return;
      state = const [];
    }
  }

  Future<void> refresh() => _fetch();

  /// Drop one immediately rather than waiting for the reload: the waiter
  /// has just tapped it and needs to see that it went (the web's comment).
  void removeLocal(String orderId) =>
      state = state.where((o) => o.id != orderId).toList();

  void appPaused() {
    _appPaused = true;
    _poll?.cancel();
  }

  void appResumed() {
    _appPaused = false;
    _poll = Timer.periodic(_interval, (_) {
      if (!_appPaused) _fetch();
    });
    _fetch();
  }

  void _teardown() {
    _poll?.cancel();
    _poll = null;
  }
}

final pendingOrdersProvider =
    NotifierProvider<PendingOrdersNotifier, List<FufutOrder>>(
        PendingOrdersNotifier.new);
