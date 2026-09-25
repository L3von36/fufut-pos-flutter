/// Floor plan — the web POS `TablesView.vue`, native, feature-for-feature.
///
/// Everything the web page renders, this screen renders; nothing added,
/// nothing skipped:
///
///  • Toolbar — "Floor Plan" title, "{n} tables · {p}% occupied" subtitle,
///    the Live/Offline SSE toggle (`tm-live-btn`), manager-only Add Table,
///    and the manual refresh button with its "Refreshed" toast.
///  • Pending strip — QR orders guests placed themselves, held back from the
///    kitchen until somebody on the floor taps Accept. Absent entirely when
///    nothing is waiting.
///  • Zone picker — a dropdown (the web replaced chips with a select), fed by
///    `GET /api/tables/sections` merged with the zones on the rows.
///  • Status strip — four KPI chips that double as floor filters (tap twice
///    to clear): Free/Seated/Reserved/Cleaning with seats/guests sub-counts.
///  • Table cards — status pill, table icon + T-## number, server initials
///    badge, capacity/size row, occupancy timer with urgency colors and the
///    4-hour overdue badge, order count + running total, Open Tab badge,
///    payment badge and the pulsing Bill Requested chip, reservation hold
///    with its window label.
///  • Detail panel — hold banner with the release rule and manager release,
///    quick-status buttons (with the seated_at/newSeating/guests side
///    effects), assigned-server dropdown (manager writes, everyone else
///    reads with an explanation), guest count, table notes, the table's open
///    checks, occupancy line, and the full action row: New Order / Add Round,
///    Ask for the Bill / Cancel Bill Request, Go to Checkout (checkout
///    grant), QR Code (manager), Close / Save Changes / Delete (manager).
///  • QR modal — the same qrserver.com image the web draws, the guest URL,
///    and Print QR Card (the web's print popup, native via a PDF card).
///  • Add Table modal — number, name, capacity, zone, shape picker.
///  • Live wiring — the same two SSE channels the web opens: `tables` for
///    the floor plan and `kitchen` diffed for the "your table's food is
///    ready" chime (capped at three per snapshot, exactly like the web).
///    A 15s poll runs only while the stream is disconnected; timers tick
///    every 10s and the pending feed polls every 30s, both web intervals.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../services/audio_alerts.dart';
import '../services/order_journal.dart';
import '../state/app_state.dart';
import '../state/app_time.dart';
import '../state/cart.dart';
import '../state/clock.dart';
import '../state/floor_plan.dart';
import '../state/live_feeds.dart';
import '../state/nav.dart';
import '../state/roles.dart';
import '../state/session_providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/bill_request_sheet.dart' show showBillRequestSheet;
import '../widgets/dashboard.dart' show LoadError;
import 'checkout_sheet.dart' show PaymentResult, PaymentSheet;
import 'orders_screen.dart' show OrderDetailSheet;

class TablesScreen extends ConsumerStatefulWidget {
  final ValueChanged<NavKey>? onNavigate;

  /// Which shell tab this floor lives on — the ready chime speaks only
  /// while the floor is on stage (null = always on stage, the tests' bare
  /// constructor). The live feeds themselves never sleep while the screen
  /// is mounted; there is no connection left to gate.
  final NavKey? self;

  const TablesScreen({super.key, this.onNavigate, this.self});

  @override
  ConsumerState<TablesScreen> createState() => _TablesScreenState();
}

class _TablesScreenState extends ConsumerState<TablesScreen> {
  String _activeSection = 'All';
  String _statusFilter = '';

  String? _accepting; // pending order currently being accepted

  /// Roster cache for the assignment dropdown — fetched once per screen
  /// life (ephemeral UI support, not app state).
  List<StaffMember> _staffServers = [];

  // Previous status per order id, used to detect a transition INTO ready.
  // Without this, every feed tick that finds a ready order would re-chime —
  // the waiter would hear it over and over until the order is served, which
  // is worse than no notification at all (the web's prevOrderStatuses).
  Map<String, String> _prevOrderStatuses = {};

  TablesFeedState get _feed => ref.read(tablesFeedProvider);

  bool get _onStage =>
      widget.self == null || ref.read(activeTabProvider) == widget.self;

  // ── Data (build() watches the feeds; these read the same snapshot) ────────

  List<CafeTable> get _tables => _feed.tables;
  List<FufutOrder> get _orders => _feed.orders;
  List<FufutOrder> get _pending => ref.read(pendingOrdersProvider);
  List<String> get _sections => _feed.sections;

  // ── Derived (the web's computed properties) ──────────────────────────────

  List<CafeTable> get _filtered {
    var t = _tables;
    if (_activeSection != 'All') {
      t = t.where((x) => x.section == _activeSection).toList();
    }
    if (_statusFilter.isNotEmpty) {
      t = t.where((x) => x.status == _statusFilter).toList();
    }
    return t;
  }

  int _countOf(String status) =>
      _tables.where((t) => t.status == status).length;

  int get _occupiedSeats => _tables
      .where((t) => t.status == 'occupied')
      .fold<int>(0, (s, t) => s + t.guestsCount);

  int get _availableSeats => _tables
      .where((t) => t.status == 'available')
      .fold<int>(0, (s, t) => s + (t.seats ?? 0));

  int get _occupancyPercent => _tables.isEmpty
      ? 0
      : ((_countOf('occupied') / _tables.length) * 100).round();

  /// Orders still open per table id — the "{n} Orders" badge.
  Map<String, int> get _tableOrderCounts {
    final map = <String, int>{};
    for (final o in _orders) {
      final tn = o.tableNum ?? '';
      if (tn.isEmpty) continue;
      final tbl = _tableByNumber(tn);
      if (tbl == null) continue;
      map[tbl.id] = (map[tbl.id] ?? 0) + 1;
    }
    return map;
  }

  Map<String, double> get _tableOrderTotals {
    final map = <String, double>{};
    for (final o in _orders) {
      final tn = o.tableNum ?? '';
      if (tn.isEmpty) continue;
      final tbl = _tableByNumber(tn);
      if (tbl == null) continue;
      map[tbl.id] = (map[tbl.id] ?? 0) + o.total;
    }
    return map;
  }

  /// Table id → open (unpaid, non-cancelled) check, so the floor can badge
  /// tables with a running tab the waiter has not settled yet.
  Map<String, FufutOrder> get _tableOpenTab {
    final map = <String, FufutOrder>{};
    for (final o in _orders.where(isResumableCheck)) {
      final tn = o.tableNum ?? '';
      if (tn.isEmpty) continue;
      final tbl = _tableByNumber(tn);
      if (tbl == null) continue;
      final existing = map[tbl.id];
      if (existing == null ||
          _createdMs(o) >= _createdMs(existing)) {
        map[tbl.id] = o;
      }
    }
    return map;
  }

  CafeTable? _tableByNumber(String num) {
    for (final t in _tables) {
      if (t.number == num) return t;
    }
    return null;
  }

  static int _createdMs(FufutOrder o) =>
      DateTime.tryParse(o.created ?? '')?.toUtc().millisecondsSinceEpoch ?? -1;

  bool get _isManager => ref.watch(roleProvider) == 'manager';

  // ── Feed listeners (registered in build) ─────────────────────────────────

  /// Back on stage: the floor may have moved while we were dark.
  void _onTabChanged(NavKey? prev, NavKey next) {
    if (!mounted || next != widget.self) return;
    ref.read(tablesFeedProvider.notifier).refreshTables();
    ref.read(tablesFeedProvider.notifier).refreshOrders();
    ref.read(pendingOrdersProvider.notifier).refresh();
  }

  /// The ready chime — table-scoped, diffed against the previous snapshot.
  /// The shared kitchen feed carries every order; this screen only speaks
  /// for orders sitting on ITS tables, and only while on stage.
  void _onKitchenFeed(KitchenFeedState? prev, KitchenFeedState next) {
    if (prev == null || !mounted) return;
    if (identical(prev.orders, next.orders)) return;
    if (!_onStage) return; // chime only while on stage

    final myTables = _tables.map((t) => t.id).toSet();
    final prevStatuses = _prevOrderStatuses;
    final nextStatuses = <String, String>{
      for (final o in next.orders) o.id: o.status,
    };
    if (myTables.isEmpty) {
      // No tables loaded yet — keep the map fresh so the first real
      // snapshot does not fire a chime for an order that was already ready
      // before we connected (the web's guard).
      _prevOrderStatuses = nextStatuses;
      return;
    }
    final newlyReady = <FufutOrder>[];
    for (final o in next.orders) {
      final tid = o.tableNum ?? '';
      if (tid.isEmpty || !myTables.contains(tid)) continue;
      if (o.status == 'ready' && prevStatuses[o.id] != 'ready') {
        newlyReady.add(o);
      }
    }
    _prevOrderStatuses = nextStatuses;
    // Sound + toast per newly-ready order. Cap at 3 so a chef hitting
    // "Mark all ready" on a 10-top board does not chime ten times in a tick.
    if (newlyReady.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    for (final o in newlyReady.take(3)) {
      AudioAlerts.instance.play(AlertSound.orderReady);
      showInfoOn(messenger,
          'Table ${o.tableNum} — order ready, pick up from the pass');
    }
  }

  /// Pull-to-refresh.
  Future<void> _refreshAll() async {
    await ref.read(tablesFeedProvider.notifier).refreshAll();
    await ref.read(pendingOrdersProvider.notifier).refresh();
    if (!mounted) return;
    showInfoOn(ScaffoldMessenger.of(context), 'Refreshed');
  }

  // ── Floor actions ────────────────────────────────────────────────────────

  /// A guest's self-placed order joins the kitchen board.
  Future<void> _acceptOrder(FufutOrder order) async {
    if (_accepting != null) return;
    setState(() => _accepting = order.id);
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.acceptOrder(order.id);
      // Drop it immediately rather than waiting for the reload: the waiter
      // has just tapped it and needs to see that it went (the web's comment).
      if (!mounted) return;
      ref.read(pendingOrdersProvider.notifier).removeLocal(order.id);
      AudioAlerts.instance.play(AlertSound.newOrder);
      showInfoOn(messenger,
          'Sent to the kitchen — ${tableLabel(order.tableNum)}');
      await ref.read(tablesFeedProvider.notifier).refreshOrders();
    } on ApiError catch (e) {
      if (e.isAuthError) await app.sessionExpired();
      if (!mounted) return;
      setState(() => _accepting = null);
      showErrorOn(messenger, e);
    } catch (e) {
      if (!mounted) return;
      setState(() => _accepting = null);
      showErrorOn(messenger, e);
    } finally {
      if (mounted && _accepting == order.id) {
        setState(() => _accepting = null);
      }
    }
  }

  /// New Order / Add Round — wire the cart to the table's open check when
  /// one exists (served-but-unpaid counts; that is how dessert gets sold)
  /// and jump to the menu, exactly the web's newOrderForTable.
  void _newOrderForTable(CafeTable t) {
    final cart = ref.read(cartProvider);
    if (t.status == 'occupied') {
      final latest = latestResumableCheck(_orders, t.number);
      if (latest != null) {
        cart.startAddRound(orderId: latest.id, tableNum: t.number);
        widget.onNavigate?.call(NavKey.menuView);
        return;
      }
    }
    cart.startNewOrderForTable(t.number);
    widget.onNavigate?.call(NavKey.menuView);
  }

  /// Go to Checkout — the cashier settles the table's open check. The web
  /// routes to /app/checkout with the check wired; here the same check opens
  /// in the payment sheet and settles via the same PUT.
  ///
  /// Owner's rule (2026-09): only SERVED orders settle. A check still in the
  /// kitchen cannot be paid yet — the gate says so instead of hiding it.
  Future<void> _goToCheckout(CafeTable t) async {
    final app = ref.read(appStateProvider);
    final latest = latestResumableCheck(_orders, t.number);
    if (latest == null) {
      showInfoOn(ScaffoldMessenger.of(context),
          'No open check for table ${t.number}');
      return;
    }
    if (latest.status.toLowerCase() != 'served') {
      showWarnOn(
          ScaffoldMessenger.of(context),
          'Table ${t.number}\'s check is ${latest.status} — '
          'settle opens once the waiter marks it served.');
      return;
    }
    // fixedTotal: the bill is already on the server — the sheet must not
    // read the cart (there is none in this flow).
    final result = await showModalBottomSheet<PaymentResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Pal.of(context).surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      builder: (_) => PaymentSheet(fixedTotal: latest.total),
    );
    if (result == null || !mounted) return;
    final line = result.primary;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.settleOrder(latest, line.method, line,
          tip: result.tip, breakdown: result.breakdown);
      showInfoOn(messenger,
          'Tab settled — ${money(line.amount)} via ${line.method}');
      await ref.read(tablesFeedProvider.notifier).refreshTables();
      await ref.read(tablesFeedProvider.notifier).refreshOrders();
    } on ApiError catch (e) {
      if (e.isAuthError) await app.sessionExpired();
      showErrorOn(messenger, e);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Future<String?> _requestBill(CafeTable t) async {
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    // What the guest plans to pay with — the sheet also shows the venue's
    // telebirr/bank accounts so the floor can tell the guest where to send
    // the money. A request without a method still works (skip the sheet via
    // a cancel), the till just learns nothing about the money up front.
    final method = await showBillRequestSheet(context, ref);
    if (method == null) return null;
    try {
      await app.api.requestBill(t.id, method: method);
      // Stamp the floor row so the chip stays up without waiting for the
      // next push (the web updates both the copy and the row).
      final stamp = DateTime.now().toUtc().toIso8601String();
      _patchRow(t.id, billRequestedAt: stamp, billMethod: method);
      return stamp;
    } on ApiError catch (e) {
      if (e.isAuthError) await app.sessionExpired();
      showErrorOn(messenger, e);
      return null;
    } catch (e) {
      showErrorOn(messenger, e);
      return null;
    }
  }

  Future<String?> _cancelBillRequest(CafeTable t) async {
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.cancelBillRequest(t.id);
      _patchRow(t.id, billRequestedAt: '', billMethod: '');
      return '';
    } on ApiError catch (e) {
      if (e.isAuthError) await app.sessionExpired();
      showErrorOn(messenger, e);
      return null;
    } catch (e) {
      showErrorOn(messenger, e);
      return null;
    }
  }

  void _patchRow(String id, {required String billRequestedAt, String? billMethod}) {
    for (final t in _tables) {
      if (t.id == id) {
        ref.read(tablesFeedProvider.notifier).patchTableLocal(t.copyWith(
            billRequestedAt: billRequestedAt, billMethod: billMethod));
        return;
      }
    }
  }

  /// Quick-status side effects live in the detail sheet; this is the PUT.
  /// Returns null on success, the failure message otherwise (the sheet stays
  /// open on failure, exactly like the web's saveDetail catch).
  Future<String?> _saveTable(Map<String, dynamic> payload, String id) async {
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.updateTable(id, payload);
      showInfoOn(messenger, 'Table updated');
      await ref.read(tablesFeedProvider.notifier).refreshTables();
      return null;
    } on ApiError catch (e) {
      if (e.isAuthError) await app.sessionExpired();
      // The server refuses seating a held table with an explanation;
      // surfacing it is the difference between an explanation and a wall.
      await ref.read(tablesFeedProvider.notifier).refreshTables();
      return e.message;
    } catch (e) {
      await ref.read(tablesFeedProvider.notifier).refreshTables();
      return e.toString();
    }
  }

  /// The kitchen's table-turn: clear the party off a table whose guests have
  /// gone. The server owns the guard — it refuses while an open check on the
  /// table is still unpaid, and the message is exactly what the chef needs
  /// (“settle first”), so it surfaces verbatim. Returns null on success, the
  /// failure message otherwise (same contract as _saveTable).
  Future<String?> _freeTable(String id) async {
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    // The Order Log's last leg: the party has gone and the table turns. The
    // check this free closes was settled a moment ago, so it has already
    // left the floor feed — resolve the table's number first, then stamp
    // its newest ticket after the free lands (this device's clock, exact).
    String? number;
    for (final t in ref.read(tablesFeedProvider).tables) {
      if (t.id == id) {
        number = t.number;
        break;
      }
    }
    try {
      await app.api.freeTable(id);
      showInfoOn(messenger, 'Table freed');
      if (number != null) {
        try {
          final all = await app.api.orders();
          for (final o in all) {
            if ('${o.tableNum}' != number) continue;
            OrderJournal.instance.record(o.id, OrderStage.tableCleared,
                by: app.user?.displayName,
                note: 'Table $number freed');
            break; // newest-first: the first hit is the newest ticket
          }
        } catch (_) {
          // A log leg is best-effort — the free itself already landed.
        }
      }
      await ref.read(tablesFeedProvider.notifier).refreshTables();
      return null;
    } on ApiError catch (e) {
      if (e.isAuthError) await app.sessionExpired();
      await ref.read(tablesFeedProvider.notifier).refreshTables();
      return e.message;
    } catch (e) {
      await ref.read(tablesFeedProvider.notifier).refreshTables();
      return e.toString();
    }
  }

  Future<bool> _deleteTable(CafeTable t) async {
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.deleteTable(t.id);
      showInfoOn(messenger, 'Table deleted');
      await ref.read(tablesFeedProvider.notifier).refreshTables();
      return true;
    } on ApiError catch (e) {
      if (e.isAuthError) await app.sessionExpired();
      showErrorOn(messenger, e);
      return false;
    } catch (e) {
      showErrorOn(messenger, e);
      return false;
    }
  }

  Future<bool> _releaseHold(CafeTable t, TableHold hold) async {
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.releaseReservation(hold.id);
      showInfoOn(messenger, 'Table released');
      await ref.read(tablesFeedProvider.notifier).refreshTables();
      return true;
    } on ApiError catch (e) {
      if (e.isAuthError) await app.sessionExpired();
      showErrorOn(messenger, e);
      return false;
    } catch (e) {
      showErrorOn(messenger, e);
      return false;
    }
  }

  Future<void> _openDetail(CafeTable t) async {
    if (_isManager) _loadStaffServers();
    final app = ref.read(appStateProvider);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Pal.of(context).surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      constraints: BoxConstraints(
          maxWidth: 640, maxHeight: MediaQuery.sizeOf(context).height * 0.92),
      builder: (_) => _DetailSheet(
          table: t,
          tables: _tables,
          isManager: app.roleKey == 'manager',
          canRequestBill:
              ['head-waiter', 'manager'].contains(app.roleKey),
          canCheckout: canCheckout(app.roleKey),
          // Floor writes are the head-waiter's and the manager's; the kitchen
          // sees the room read-only and gets the one action that turns a
          // table. See roles.dart for the grant sets.
          canOrder: canTakeTableOrders(app.roleKey),
          canEditTable: canEditTable(app.roleKey),
          canFree: canFreeTable(app.roleKey),
          canServe: canMarkServed(app.roleKey),
          servers: _assignableServers(),
          // The web's openDetail fetch: this table's open checks only —
          // and ONLY the current seating's (owner's 2026-09-25 rule). A
          // freed party's leftover check (served but unpaid) drops into the
          // history section below; the new customers' active list carries
          // their own orders alone.
          onLoadOrders: () async {
            final all = await app.api.orders();
            return all
                .where((o) => o.tableNum == t.number && isResumableCheck(o))
                .where((o) => isCurrentSeatingOrder(o, t))
                .toList();
          },
          // The table's memory: every ticket that touched it in the last
          // seven days, any status — survives the party leaving.
          onLoadHistory: () async {
            final now = DateTime.now();
            final to = fmtDay(now);
            final from = fmtDay(now.subtract(const Duration(days: 7)));
            final all = await app.api.orders(from: from, to: to, limit: 200);
            return all
                .where((o) => o.tableNum == t.number || o.tableNum == t.id)
                .toList()
              ..sort((a, b) =>
                  (b.created ?? '').compareTo(a.created ?? ''));
          },
          onSave: (payload) => _saveTable(payload, t.id),
          onFree: () => _freeTable(t.id),
          onDelete: () => _deleteTable(t),
          onReleaseHold: (hold) => _releaseHold(t, hold),
          onRequestBill: () => _requestBill(t),
          onCancelBillRequest: () => _cancelBillRequest(t),
          onNewOrder: () => _newOrderForTable(t),
          onGoToCheckout: () => _goToCheckout(t),
          onShowQr: () => _generateQr(t),
          onServeOrder: _serveOrder,
        ),
    );
  }

  /// The waiter's handoff word — fulfilled → served, from the table's own
  /// detail sheet. Server law 3 refuses the write for roles without the
  /// grant; the button only shows where the app already knows it is allowed.
  /// Refreshes the floor + pending feeds so the badge and the pending panel
  /// move the moment the tap lands.
  Future<bool> _serveOrder(FufutOrder o) async {
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.updateStatus(o, 'served');
      showInfoOn(messenger, 'Order ${shortId(o.id)} served');
      await ref.read(tablesFeedProvider.notifier).refreshTables();
      await ref.read(tablesFeedProvider.notifier).refreshOrders();
      ref.read(pendingOrdersProvider.notifier).refresh();
      return true;
    } on ApiError catch (e) {
      if (e.isAuthError) await app.sessionExpired();
      showErrorOn(messenger, e);
      return false;
    } catch (e) {
      showErrorOn(messenger, e);
      return false;
    }
  }

  /// Roster of who can be assigned: active head-waiters, so the name stored
  /// on the table is exactly the staff member's display name (the web's
  /// assignableServers filter).
  List<String> _assignableServers() {
    return _staffServers
        .where((s) =>
            s.role.toLowerCase() == 'head-waiter' &&
            s.status.toLowerCase() == 'active')
        .map((s) => s.name.trim())
        .where((n) => n.isNotEmpty)
        .toList();
  }

  Future<void> _loadStaffServers() async {
    if (_staffServers.isNotEmpty) return;
    final app = ref.read(appStateProvider);
    try {
      final staff = await app.api.staff();
      if (mounted) setState(() => _staffServers = staff);
    } catch (_) {
      if (mounted) setState(() => _staffServers = const []);
    }
  }

  Future<void> _generateQr(CafeTable t) async {
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await app.api.tableQr(t.id);
      if (!mounted) return;
      showInfoOn(messenger, 'QR Code generated for Table ${t.number}');
      await showDialog<void>(
        context: context,
        builder: (_) => _QrModal(tableNumber: t.number, url: res.url),
      );
    } on ApiError catch (e) {
      if (e.isAuthError) await app.sessionExpired();
      showErrorOn(messenger, e);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Future<void> _openAddTable() async {
    final app = ref.read(appStateProvider);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Pal.of(context).surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      constraints: BoxConstraints(
          maxWidth: 560, maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      builder: (_) => _AddTableSheet(
        sections: _sections,
        defaultNumber: _tables.fold<int>(0, (m, t) {
          final n = int.tryParse(t.number);
          return n != null && n > m ? n : m;
        }),
        onAdd: ({required number, required capacity, section, name, shape = 'square'}) async {
          final messenger = ScaffoldMessenger.of(context);
          try {
            await app.api.addTable(
              number: number,
              capacity: capacity,
              section: section,
              name: name,
              shape: shape,
            );
            showInfoOn(messenger, 'Table added');
            return null;
          } on ApiError catch (e) {
            if (e.isAuthError) await app.sessionExpired();
            return e.message;
          } catch (e) {
            return e.toString();
          }
        },
      ),
    );
    await ref.read(tablesFeedProvider.notifier).refreshTables();
  }

  /// The web's toggleSSE — hang up (or re-open) the tables stream. The
  /// ready chime now rides the shared kitchen feed, so only the tables
  /// channel follows this switch.
  void _toggleSse() {
    final up = ref.read(tablesFeedProvider).connected;
    ref.read(tablesFeedProvider.notifier).setLive(!up);
    if (mounted) setState(() {});
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Watched data: the floor feed, the pending strip, and the clocks —
    // minute ticks re-tint the occupancy colours, kitchen-feed transitions
    // drive the ready chime, and the active-tab switch refreshes on return.
    final feed = ref.watch(tablesFeedProvider);
    ref.watch(pendingOrdersProvider);
    ref.listen(minuteClockProvider, (_, __) {
      if (mounted && _onStage) setState(() {}); // occupancy re-tint
    });
    ref.listen(activeTabProvider, _onTabChanged);
    ref.listen(kitchenFeedProvider, _onKitchenFeed);

    if (feed.loading && feed.tables.isEmpty && feed.error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (feed.error != null && feed.tables.isEmpty) {
      return LoadError(
          error: feed.error!,
          onRetry: () => ref.read(tablesFeedProvider.notifier).refreshAll());
    }
    final pal = Pal.of(context);
    final manager = _isManager;
    final filtered = _filtered;

    // Visible sections: the picked zone alone, or every zone that still has
    // tables after the current filter (the web's visibleSections).
    final List<String> visibleSections;
    final Map<String, List<CafeTable>> bySection;
    if (_activeSection != 'All') {
      visibleSections = [_activeSection];
    } else {
      visibleSections = _sections
          .where((s) => filtered.any((t) => t.section == s))
          .toList();
    }
    bySection = {
      for (final s in visibleSections)
        s: filtered.where((t) => t.section == s).toList(),
    };
    final counts = _tableOrderCounts;
    final totals = _tableOrderTotals;
    final openTabs = _tableOpenTab;

    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
        children: [
          _Toolbar(
            tableCount: _tables.length,
            occupancyPercent: _occupancyPercent,
            connected: feed.connected,
            onToggleSse: _toggleSse,
            manager: manager,
            onAddTable: _openAddTable,
            onRefresh: _refreshAll,
          ),
          // Pending strip — absent entirely when nothing is waiting.
          if (_pending.isNotEmpty) ...[
            const SizedBox(height: 12),
            _PendingStrip(
              pending: _pending,
              accepting: _accepting,
              onAccept: _acceptOrder,
            ),
          ],
          const SizedBox(height: 14),
          _ZonePicker(
            sections: _sections,
            value: _activeSection,
            onChanged: (v) => setState(() => _activeSection = v),
          ),
          const SizedBox(height: 2),
          _StatusStrip(
            available: _countOf('available'),
            availableSeats: _availableSeats,
            occupied: _countOf('occupied'),
            occupiedGuests: _occupiedSeats,
            reserved: _countOf('reserved'),
            cleaning: _countOf('cleaning'),
            active: _statusFilter,
            onToggle: (key) => setState(() {
              _statusFilter = _statusFilter == key ? '' : key;
            }),
          ),
          const SizedBox(height: 14),
          if (filtered.isEmpty)
            _EmptyState(section: _activeSection)
          else
            ...[
              for (final entry in bySection.entries) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(entry.key,
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: pal.heading)),
                    const SizedBox(width: 8),
                    Text('${entry.value.length} tables',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11,
                            color: pal.muted)),
                  ],
                ),
                const SizedBox(height: 8),
                _SectionGrid(
                  tables: entry.value,
                  counts: counts,
                  totals: totals,
                  openTabs: openTabs,
                  onTap: _openDetail,
                ),
                const SizedBox(height: 16),
              ],
            ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Toolbar — "Floor Plan", counts, Live toggle, Add Table (manager), refresh.
// ─────────────────────────────────────────────────────────────────────────────

class _Toolbar extends StatelessWidget {
  final int tableCount;
  final int occupancyPercent;
  final bool connected;
  final VoidCallback onToggleSse;
  final bool manager;
  final VoidCallback onAddTable;
  final VoidCallback onRefresh;

  const _Toolbar({
    required this.tableCount,
    required this.occupancyPercent,
    required this.connected,
    required this.onToggleSse,
    required this.manager,
    required this.onAddTable,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Floor Plan',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: pal.heading)),
            Text('$tableCount tables · $occupancyPercent% occupied',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 11.5, color: pal.muted)),
          ],
        ),
        const SizedBox(width: 4),
        _LiveChip(connected: connected, onToggle: onToggleSse),
        if (manager)
          SizedBox(
            height: 34,
            child: FilledButton.icon(
              onPressed: onAddTable,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: const TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700),
              ),
              icon: const Icon(Icons.add, size: 15),
              label: const Text('Add Table'),
            ),
          ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh, size: 20),
          color: pal.muted,
        ),
      ],
    );
  }
}

/// The web's `tm-live-btn`: a green-pulsing Live chip while the stream is
/// up, a dim Offline chip while the poll carries the floor. Tapping toggles
/// the connection (the web's toggleSSE).
class _LiveChip extends StatelessWidget {
  final bool connected;
  final VoidCallback onToggle;

  const _LiveChip({required this.connected, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return _chip(pal, connected);
  }

  Widget _chip(Pal pal, bool up) {
    final color = up ? pal.success : pal.muted;
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: up ? 0.12 : 0.07),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 5),
          Text(up ? 'Live' : 'Offline',
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: color)),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pending strip — guest QR orders waiting for a floor Accept. Deliberately
// loud: a guest is sitting there wondering whether anybody saw it.
// ─────────────────────────────────────────────────────────────────────────────

class _PendingStrip extends StatelessWidget {
  final List<FufutOrder> pending;
  final String? accepting;
  final ValueChanged<FufutOrder> onAccept;

  const _PendingStrip({
    required this.pending,
    required this.accepting,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final n = pending.length;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: pal.warningBorder),
        borderRadius: BorderRadius.circular(10),
        color: pal.warningBg,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                '$n order${n == 1 ? '' : 's'} from guests waiting',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: pal.heading),
              ),
            ),
            Text('The kitchen has not seen these yet',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 10.5, color: pal.muted)),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(builder: (context, box) {
          final cols = box.maxWidth >= 560 ? 2 : 1;
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: cols == 1 ? 3.6 : 2.9,
            ),
            itemCount: pending.length,
            itemBuilder: (context, i) {
              final o = pending[i];
              final isAccepting = accepting == o.id;
              // The web reads o.source === 'qr'; a QR order without the
              // field reads Staff there too, so the default matches.
              final sourceQr = (o.source ?? '').toLowerCase() == 'qr';
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: pal.surface,
                  border: Border.all(color: pal.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(tableLabel(o.tableNum),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: pal.heading)),
                      ),
                      const SizedBox(width: 6),
                      _SourceBadge(qr: sourceQr),
                      const Spacer(),
                      Text(waitingFor(o.created),
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 10,
                              color: pal.muted)),
                    ]),
                    const SizedBox(height: 3),
                    Text(
                      o.items.isNotEmpty
                          ? summariseItems(o.items)
                          : o.itemsRaw,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 11,
                          height: 1.3,
                          color: pal.body),
                    ),
                    const SizedBox(height: 5),
                    Row(children: [
                      Text(formatETB(o.total),
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: pal.heading)),
                      const Spacer(),
                      SizedBox(
                        height: 28,
                        child: FilledButton(
                          onPressed:
                              isAccepting || accepting != null
                                  ? null
                                  : () => onAccept(o),
                          style: FilledButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 14),
                            textStyle: const TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700),
                          ),
                          child: Text(isAccepting ? 'Sending…' : 'Accept'),
                        ),
                      ),
                    ]),
                  ],
                ),
              );
            },
          );
        }),
      ]),
    );
  }
}

/// QR / Staff source badge — a printed code is a photograph anyone can keep,
/// so the badge says where the order came from.
class _SourceBadge extends StatelessWidget {
  final bool qr;
  const _SourceBadge({required this.qr});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: qr ? pal.tintBg : pal.sunken,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(qr ? 'QR' : 'Staff',
          style: TextStyle(
              fontFamily: kFontBody,
              fontSize: 8.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              color: qr ? pal.primary : pal.muted)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Zone picker — a dropdown, not chips: one row, every zone in the native
// picker, and it cannot render as a circle because it is a rectangle by
// construction (the web's tm-zonepick note).
// ─────────────────────────────────────────────────────────────────────────────

class _ZonePicker extends StatelessWidget {
  final List<String> sections;
  final String value;
  final ValueChanged<String> onChanged;

  const _ZonePicker({
    required this.sections,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final options = <String>['All', ...sections];
    final current = options.contains(value) ? value : 'All';
    return Row(children: [
      Text('ZONE',
          style: TextStyle(
              fontFamily: kFontBody,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: pal.muted)),
      const SizedBox(width: 10),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border.all(color: pal.border),
            borderRadius: BorderRadius.circular(8),
            color: pal.surface,
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: current,
              isDense: true,
              borderRadius: BorderRadius.circular(8),
              items: [
                for (final s in options)
                  DropdownMenuItem(
                    value: s,
                    child: Text(s == 'All' ? 'All sections' : s,
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: pal.heading)),
                  ),
              ],
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ),
      ),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Status strip — the four numbers a floor plan needs, and each one filters
// the floor. Tapping the same chip twice clears it, so getting back to the
// whole floor never needs a separate "All" control.
// ─────────────────────────────────────────────────────────────────────────────

class _StatusStrip extends StatelessWidget {
  final int available;
  final int availableSeats;
  final int occupied;
  final int occupiedGuests;
  final int reserved;
  final int cleaning;
  final String active;
  final ValueChanged<String> onToggle;

  const _StatusStrip({
    required this.available,
    required this.availableSeats,
    required this.occupied,
    required this.occupiedGuests,
    required this.reserved,
    required this.cleaning,
    required this.active,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final chips = [
      _StripChip(
        key: 'available',
        label: 'Free',
        count: available,
        sub: '$availableSeats seats',
        color: Pal.of(context).success,
      ),
      _StripChip(
        key: 'occupied',
        label: 'Seated',
        count: occupied,
        sub: '$occupiedGuests guests',
        color: Pal.of(context).info,
      ),
      _StripChip(
        key: 'reserved',
        label: 'Reserved',
        count: reserved,
        sub: 'today',
        color: Pal.of(context).warning,
      ),
      _StripChip(
        key: 'cleaning',
        label: 'Cleaning',
        count: cleaning,
        sub: 'to reset',
        color: Pal.of(context).faint,
      ),
    ];
    return LayoutBuilder(builder: (context, box) {
      final twoUp = box.maxWidth < 560;
      final showSub = box.maxWidth >= 380;
      final rows = <Widget>[];
      for (var i = 0; i < chips.length; i += twoUp ? 2 : 4) {
        final slice = chips.sublist(
            i, (i + (twoUp ? 2 : 4)).clamp(0, chips.length));
        rows.add(Row(
          children: [
            for (final c in slice)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                      right: c != slice.last ? 8 : 0, bottom: twoUp ? 8 : 0),
                  child: _buildChip(context, c, showSub),
                ),
              ),
          ],
        ));
      }
      return Column(children: rows);
    });
  }

  Widget _buildChip(BuildContext context, _StripChip chip, bool showSub) {
    final pal = Pal.of(context);
    final isActive = active == chip.key;
    return Material(
      color: isActive ? pal.tintBg : pal.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: () => onToggle(chip.key),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isActive ? pal.primary : pal.border,
              width: 1.5,
            ),
          ),
          child: Row(children: [
            Container(
              width: 7,
              height: 7,
              decoration:
                  BoxDecoration(shape: BoxShape.circle, color: chip.color),
            ),
            const SizedBox(width: 8),
            Text('${chip.count}',
                style: TextStyle(
                    fontFamily: kFontMono,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: pal.heading)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(chip.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: pal.body)),
            ),
            if (showSub)
              Text(chip.sub,
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 10,
                      color: pal.muted)),
          ]),
        ),
      ),
    );
  }
}

class _StripChip {
  final String key;
  final String label;
  final int count;
  final String sub;
  final Color color;
  const _StripChip({
    required this.key,
    required this.label,
    required this.count,
    required this.sub,
    required this.color,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Section grid + the table card.
// ─────────────────────────────────────────────────────────────────────────────

class _SectionGrid extends StatelessWidget {
  final List<CafeTable> tables;
  final Map<String, int> counts;
  final Map<String, double> totals;
  final Map<String, FufutOrder> openTabs;
  final ValueChanged<CafeTable> onTap;

  const _SectionGrid({
    required this.tables,
    required this.counts,
    required this.totals,
    required this.openTabs,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      // The web grid is repeat(auto-fill, minmax(200px, 1fr)) — 2-up below
      // 480px, more columns as the pane widens. Rows size to the tallest
      // card (CSS grid auto rows), which a Wrap reproduces: every card gets
      // the row's column width and keeps its own intrinsic height.
      final cols = (box.maxWidth / 200).floor().clamp(2, 6);
      final cardWidth =
          (box.maxWidth - (cols - 1) * 12) / cols;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final t in tables)
            SizedBox(
              width: cardWidth,
              child: _TableCard(
                table: t,
                orderCount: counts[t.id] ?? 0,
                orderTotal: totals[t.id] ?? 0,
                openTab: openTabs[t.id] != null,
                onTap: onTap,
              ),
            ),
        ],
      );
    });
  }
}

class _TableCard extends StatelessWidget {
  final CafeTable table;
  final int orderCount;
  final double orderTotal;
  final bool openTab;
  final ValueChanged<CafeTable> onTap;

  const _TableCard({
    required this.table,
    required this.orderCount,
    required this.orderTotal,
    required this.openTab,
    required this.onTap,
  });

  static const _pillLight = {
    'available': (Color(0xFFF0FDF4), Color(0xFF166534)),
    'occupied': (Color(0xFFEFF6FF), Color(0xFF1E40AF)),
    'reserved': (Color(0xFFFEF3C7), Color(0xFF92400E)),
  };
  static const _pillDark = {
    'available': (Color(0x2216A34A), Color(0xFF4ADE80)),
    'occupied': (Color(0x2260A5FA), Color(0xFF60A5FA)),
    'reserved': (Color(0x22FBBF24), Color(0xFFFBBF24)),
  };

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final status = table.status.toLowerCase();

    // Card accent: 3px top bar + icon tint — success / primary / info /
    // neutral, exactly the web's ::before rules.
    final Color accent;
    switch (status) {
      case 'occupied':
        accent = pal.primary;
        break;
      case 'reserved':
        accent = pal.info;
        break;
      case 'cleaning':
        accent = pal.faint;
        break;
      default:
        accent = pal.success;
    }
    final pill = (dark ? _pillDark : _pillLight)[status] ??
        (dark
            ? (const Color(0x2294A3B8), pal.muted)
            : (pal.sunken, pal.muted));

    final urgency = occupancyUrgency(table);
    final timer = occupancyTimer(table.seatedAt);

    return Material(
      color: pal.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: () => onTap(table),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: status == 'occupied'
                  ? const Color(0x330F7B78)
                  : status == 'reserved'
                      ? const Color(0x332563EB)
                      : pal.border,
            ),
          ),
          child: Stack(children: [
            // 3px status accent across the top.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                height: 3,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(14)),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Top row: server initials badge (left), status pill (right).
                  Row(children: [
                    if ((table.server ?? '').isNotEmpty)
                      _ServerBadge(name: table.server!)
                    else
                      const SizedBox(width: 24),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: pill.$1,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(status,
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.3,
                              color: pill.$2)),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  // Center: table icon + padded number.
                  _TableIcon(status: status, accent: accent),
                  const SizedBox(height: 6),
                  Text(
                      'T-${table.number.padLeft(2, '0')}',
                      style: TextStyle(
                          fontFamily: kFontMono,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: pal.heading)),
                  const SizedBox(height: 10),
                  // Bottom info, by status — the web's tfc-bottom.
                  if (status == 'available') ...[
                    _infoRow(context,
                        '${table.seats ?? '—'} Persons · ${table.sizeLabel}'),
                  ] else if (status == 'occupied') ...[
                    if (timer.isNotEmpty)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.schedule,
                              size: 12,
                              color: _urgencyColor(pal, urgency)),
                          const SizedBox(width: 4),
                          Text(timer,
                              style: TextStyle(
                                  fontFamily: kFontMono,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: _urgencyColor(pal, urgency))),
                        ],
                      ),
                    if (urgency == 'overdue') ...[
                      const SizedBox(height: 3),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: pal.danger,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text('Releases soon — past 4h',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.3,
                                color: Colors.white)),
                      ),
                    ],
                    const SizedBox(height: 3),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                              orderCount > 0
                                  ? '$orderCount Order${orderCount > 1 ? 's' : ''}'
                                  : 'No order',
                              style: TextStyle(
                                  fontFamily: kFontBody,
                                  fontSize: 10.5,
                                  fontWeight: orderCount > 0
                                      ? FontWeight.w500
                                      : FontWeight.w700,
                                  color: orderCount > 0
                                      ? pal.muted
                                      : pal.warning)),
                        ),
                        if (orderTotal > 0) ...[
                          const SizedBox(width: 6),
                          Text(formatETB(orderTotal),
                              style: TextStyle(
                                  fontFamily: kFontMono,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: pal.heading)),
                        ],
                      ],
                    ),
                    if (openTab) ...[
                      const SizedBox(height: 3),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: pal.warning,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text('Open Tab',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.3,
                                color: Colors.white)),
                      ),
                    ],
                    if ((table.payment ?? '').isNotEmpty ||
                        table.billRequested) ...[
                      const SizedBox(height: 3),
                      // Wrap, not Row: both chips together outrun a narrow
                      // card, and the web's flex rows wrap the same way.
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 5,
                        runSpacing: 3,
                        children: [
                          if ((table.payment ?? '').isNotEmpty)
                            _PayBadge(state: table.payment!),
                          if (table.billRequested)
                            _BillRequestedChip(method: table.billMethod),
                        ],
                      ),
                    ],
                  ] else if (status == 'reserved') ...[
                    _infoRow(context, '${table.seats ?? '—'} Persons'),
                    if (table.reservedHold != null) ...[
                      const SizedBox(height: 3),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.event_outlined,
                              size: 12, color: pal.muted),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                                table.reservedHold!.name?.isNotEmpty == true
                                    ? table.reservedHold!.name!
                                    : 'Reserved',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 10,
                                    color: pal.muted)),
                          ),
                          const SizedBox(width: 4),
                          Text(
                              holdWindowLabel(table.reservedHold!.startAt,
                                  table.reservedHold!.endAt),
                              style: TextStyle(
                                  fontFamily: kFontMono,
                                  fontSize: 9.5,
                                  color: pal.muted)),
                        ],
                      ),
                    ],
                  ] else if (status == 'cleaning') ...[
                    _infoRow(context, 'Needs cleaning'),
                  ],
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _infoRow(BuildContext context, String text) {
    return Text(text,
        style: TextStyle(
            fontFamily: kFontBody, fontSize: 10.5, color: Pal.of(context).muted));
  }

  Color _urgencyColor(Pal pal, String urgency) {
    switch (urgency) {
      case 'fresh':
        return pal.success;
      case 'warm':
        return pal.warning;
      case 'late':
      case 'overdue':
        return pal.danger;
      default:
        return pal.muted;
    }
  }
}

/// The web's tfc-icon: a 48-unit table with four chairs a side, tinted by
/// status. Drawn with CustomPaint so no asset is needed.
class _TableIcon extends StatelessWidget {
  final String status;
  final Color accent;
  const _TableIcon({required this.status, required this.accent});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final bg = status == 'cleaning'
        ? pal.sunken
        : accent.withValues(alpha: 0.08);
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(13)),
      child: CustomPaint(painter: _TableGlyph(color: accent)),
    );
  }
}

class _TableGlyph extends CustomPainter {
  final Color color;
  _TableGlyph({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final dots = Paint()..color = color;
    final w = size.width, h = size.height;
    // Table top: rounded rect across the middle.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.20, h * 0.34, w * 0.60, h * 0.36),
          Radius.circular(w * 0.09)),
      stroke,
    );
    // Four chair dots per side, mirroring the SVG's 8 circles.
    const xs = [0.21, 0.38, 0.62, 0.79];
    for (final fx in xs) {
      canvas.drawCircle(Offset(w * fx, h * 0.24), w * 0.055, dots);
      canvas.drawCircle(Offset(w * fx, h * 0.80), w * 0.055, dots);
    }
  }

  @override
  bool shouldRepaint(covariant _TableGlyph oldDelegate) =>
      oldDelegate.color != color;
}

/// Server initials badge — stable hue from the name hash, fixed
/// saturation/lightness so white text stays legible in both themes.
class _ServerBadge extends StatelessWidget {
  final String name;
  const _ServerBadge({required this.name});

  @override
  Widget build(BuildContext context) {
    final hue = serverHue(name);
    final initials = serverInitials(name);
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: HSLColor.fromAHSL(1, hue.toDouble(), 0.55, 0.34).toColor(),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(initials,
          style: const TextStyle(
              fontFamily: kFontBody,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              letterSpacing: 0.2)),
    );
  }
}

/// Paid / Partly Paid / Unpaid — calm when settled, ordinary when sitting,
/// "some money is down" for partial. Same hues as the web's tfc-pay-badge.
class _PayBadge extends StatelessWidget {
  final String state;
  const _PayBadge({required this.state});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final label = paymentLabel(state);
    final Color bg, fg;
    switch (state.toLowerCase()) {
      case 'paid':
        bg = dark ? const Color(0x3810B981) : const Color(0x2910B981);
        fg = dark ? const Color(0xFF34D399) : const Color(0xFF047857);
        break;
      case 'partial':
        bg = dark ? const Color(0x383B82F6) : const Color(0x293B82F6);
        fg = dark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8);
        break;
      default: // unpaid
        bg = dark ? const Color(0x38F59E0B) : const Color(0x29F59E0B);
        fg = dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(label,
          style: TextStyle(
              fontFamily: kFontBody,
              fontSize: 8.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: fg)),
    );
  }
}

/// The pulsing red "Bill Requested" chip — the floor plan and the cashier's
/// screen must agree that somebody asked for the check.
class _BillRequestedChip extends StatefulWidget {
  /// What the guest plans to pay with — stamped at request time, read off
  /// the table row. Null/empty keeps the bare "Bill Requested" copy.
  final String? method;
  const _BillRequestedChip({this.method});

  @override
  State<_BillRequestedChip> createState() => _BillRequestedChipState();
}

class _BillRequestedChipState extends State<_BillRequestedChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
    lowerBound: 0.55,
    upperBound: 1.0,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final method = widget.method;
    final label = (method == null || method.isEmpty)
        ? 'Bill Requested'
        : 'Bill · ${method[0].toUpperCase()}${method.substring(1)}';
    return FadeTransition(
      opacity: _pulse,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFFB91C1C)
              : const Color(0xFFDC2626),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label,
            style: const TextStyle(
                fontFamily: kFontBody,
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: Colors.white)),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Empty state — nothing matches the current zone/status filter.
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final String section;
  const _EmptyState({required this.section});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final isAll = section == 'All';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 56),
      child: Column(children: [
        Container(
          width: 52,
          height: 52,
          decoration:
              BoxDecoration(color: pal.sunken, shape: BoxShape.circle),
          child: Icon(Icons.close, size: 26, color: pal.muted),
        ),
        const SizedBox(height: 12),
        Text('No tables in ${isAll ? 'any section' : section}',
            style: TextStyle(
                fontFamily: kFontBody,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: pal.heading)),
        const SizedBox(height: 4),
        Text(
            isAll
                ? 'Tables will appear here once they are added.'
                : 'Try selecting a different section.',
            style: TextStyle(
                fontFamily: kFontBody, fontSize: 11.5, color: pal.muted)),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Table detail panel — the web's tm-detail-modal, bottom-sheet form.
// ─────────────────────────────────────────────────────────────────────────────

class _DetailSheet extends StatefulWidget {
  final CafeTable table;
  /// The whole floor, so the hold banner reads the LIVE row the SSE keeps
  /// fresh rather than the copy the sheet was opened with (the web's
  /// detailHold computed).
  final List<CafeTable> tables;
  final bool isManager;
  final bool canRequestBill;
  final bool canCheckout;

  /// Floor writes (New Order / Add Round). The head-waiter and the manager;
  /// the kitchen, till, driver and cleaner never open a ticket from the floor.
  final bool canOrder;

  /// Party edits (status chips, guests, notes, Save Changes). The kitchen's
  /// floor view is read-shaped — the server would refuse its writes anyway.
  final bool canEditTable;

  /// The table-turn action (Free Table). The kitchen can clear a party whose
  /// guests have gone; the server refuses while a check is still unpaid.
  final bool canFree;
  final List<String> servers;
  final Future<List<FufutOrder>> Function() onLoadOrders;
  final Future<List<FufutOrder>> Function() onLoadHistory;
  final Future<String?> Function(Map<String, dynamic> payload) onSave;
  final Future<String?> Function() onFree;
  final Future<bool> Function() onDelete;
  final Future<bool> Function(TableHold hold) onReleaseHold;
  final Future<String?> Function() onRequestBill;
  final Future<String?> Function() onCancelBillRequest;
  final VoidCallback onNewOrder;
  final VoidCallback onGoToCheckout;
  final VoidCallback onShowQr;

  /// Mark Served — the floor's moment (owner's flow, 2026-09): the kitchen
  /// hands off with "picked up" (fulfilled) and the WAITER says "served".
  /// Rendered on fulfilled checks right in the table's detail sheet, so the
  /// waiter never has to hunt for the Orders screen to say it. Empty set
  /// means this role cannot serve (server law 3 refuses anyway).
  final bool canServe;
  final Future<bool> Function(FufutOrder order) onServeOrder;

  const _DetailSheet({
    required this.table,
    required this.tables,
    required this.isManager,
    required this.canRequestBill,
    required this.canCheckout,
    required this.canOrder,
    required this.canEditTable,
    required this.canFree,
    required this.servers,
    required this.onLoadOrders,
    required this.onLoadHistory,
    required this.onSave,
    required this.onFree,
    required this.onDelete,
    required this.onReleaseHold,
    required this.onRequestBill,
    required this.onCancelBillRequest,
    required this.onNewOrder,
    required this.onGoToCheckout,
    required this.onShowQr,
    required this.canServe,
    required this.onServeOrder,
  });

  @override
  State<_DetailSheet> createState() => _DetailSheetState();
}

class _DetailSheetState extends State<_DetailSheet> {
  late String _status = widget.table.status;
  late int _guests = widget.table.guestsCount;
  late String _server = widget.table.server ?? '';
  late String _seatedAt = widget.table.seatedAt ?? '';
  late String _billRequestedAt = widget.table.billRequestedAt ?? '';
  bool _newSeating = false;
  bool _saving = false;
  bool _releasing = false;
  bool _freeing = false;
  bool _billBusy = false;
  List<FufutOrder>? _detailOrders;
  List<FufutOrder>? _detailHistory;

  late final TextEditingController _notesCtrl =
      TextEditingController(text: widget.table.notes ?? '');

  @override
  void initState() {
    super.initState();
    _loadOrders();
    _loadHistory();
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadOrders() async {
    try {
      final rows = await widget.onLoadOrders();
      if (!mounted) return;
      setState(() => _detailOrders = rows);
    } catch (_) {
      if (!mounted) return;
      setState(() => _detailOrders = const []);
    }
  }

  Future<void> _loadHistory() async {
    try {
      final rows = await widget.onLoadHistory();
      if (!mounted) return;
      setState(() => _detailHistory = rows);
    } catch (_) {
      if (!mounted) return;
      setState(() => _detailHistory = const []);
    }
  }

  CafeTable? get _liveRow {
    for (final t in widget.tables) {
      if (t.id == widget.table.id) return t;
    }
    return null;
  }

  TableHold? get _hold => _liveRow?.reservedHold;

  void _quickStatus(String s) {
    setState(() {
      final prev = _status;
      _status = s;
      // Auto-set/clear seated_at — the web's quickStatus side effects.
      if (s == 'occupied' && prev != 'occupied') {
        _seatedAt = DateTime.now().toUtc().toIso8601String();
        // Tells the server this is a party arriving, not an edit to the one
        // already there, so it refuses if somebody claimed the table first.
        _newSeating = true;
      } else if (s != 'occupied') {
        _seatedAt = '';
        _newSeating = false;
        if (s == 'available') {
          // Guests clear with the party; the section owner (server) stays —
          // reassignment is the dropdown's job, not a side effect.
          _guests = 0;
        }
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final t = widget.table;
    setState(() => _saving = true);
    final err = await widget.onSave({
      'id': t.id,
      'number': t.number,
      if (t.section != null) 'section': t.section,
      'status': _status,
      if (t.seats != null) 'capacity': t.seats,
      if (t.name != null) 'name': t.name,
      if (t.shape != null) 'shape': t.shape,
      'server': _server,
      'guests': _guests,
      'seated_at': _seatedAt,
      'notes': _notesCtrl.text.trim(),
      'newSeating': _newSeating,
      'bill_requested_at': _billRequestedAt,
      if (t.payment != null) 'payment': t.payment,
    });
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _saving = false);
      showErrorOn(ScaffoldMessenger.of(context), ApiError(err));
    }
  }

  /// The kitchen's table-turn (and the floor's shortcut): clear the party.
  /// Same contract as _save — null pops the sheet, a message is the server's
  /// explanation ("still has an unsettled check") surfaced verbatim.
  Future<void> _free() async {
    if (_freeing) return;
    setState(() => _freeing = true);
    final err = await widget.onFree();
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _freeing = false);
      showErrorOn(ScaffoldMessenger.of(context), ApiError(err));
    }
  }

  Future<void> _delete() async {
    final t = widget.table;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete Table ${t.number}?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Pal.of(ctx).danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    final done = await widget.onDelete();
    if (done && mounted) Navigator.of(context).pop();
  }

  Future<void> _release() async {
    final hold = _hold;
    if (hold == null || _releasing) return;
    final t = widget.table;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Release Table ${t.number}?'),
        content: Text(
            'Cancel ${hold.name?.isNotEmpty == true ? hold.name : 'this booking'}? '
            'The table becomes seatable for walk-ins.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Release')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _releasing = true);
    final done = await widget.onReleaseHold(hold);
    if (!mounted) return;
    setState(() => _releasing = false);
    if (done) Navigator.of(context).pop();
  }

  Future<void> _bill(bool request) async {
    if (_billBusy) return;
    setState(() => _billBusy = true);
    final r = request ? await widget.onRequestBill() : await widget.onCancelBillRequest();
    if (!mounted) return;
    setState(() => _billBusy = false);
    if (r == null) return; // failure already surfaced by the screen
    setState(() => _billRequestedAt = r);
    showInfoOn(
        ScaffoldMessenger.of(context),
        request
            ? 'Bill requested for table ${widget.table.number}'
            : 'Bill request cancelled');
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final t = widget.table;
    final hold = _hold;
    final name = (t.name?.isNotEmpty == true) ? t.name! : 'Table ${t.number}';

    return SafeArea(
      child: Padding(
        // Deterministic keyboard padding — the showFormSheet rule.
        padding: EdgeInsets.fromLTRB(
            0, 0, 0, math.max(MediaQuery.of(context).viewInsets.bottom,
                MediaQuery.of(context).padding.bottom)),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 12, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Table ${t.number} — $name',
                              style: TextStyle(
                                  fontFamily: kFontBody,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                  color: pal.heading)),
                          const SizedBox(height: 2),
                          Text(
                              '${t.section ?? 'Floor'} · ${t.seats ?? '?'} seats · ${t.shape ?? 'square'}',
                              style: TextStyle(
                                  fontFamily: kFontBody,
                                  fontSize: 11.5,
                                  color: pal.muted)),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, size: 20),
                      color: pal.muted,
                    ),
                  ],
                ),
              ),

              // The bill somebody asked for — the name the till will answer
              // to, and the kitchen's cue that the party is at its end. This
              // is the "who is requesting the bill" surface the chef's floor
              // view exists for.
              if (_billRequestedAt.isNotEmpty) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0x24EF4444),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(children: [
                      const Icon(Icons.receipt_long_outlined,
                          size: 16, color: Color(0xFFB91C1C)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            'Bill requested'
                            '${widget.table.billRequestedBy?.isNotEmpty == true ? ' by ${widget.table.billRequestedBy}' : ''}'
                            ' · asked ${occupancyTimer(_billRequestedAt)} ago',
                            style: const TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFB91C1C))),
                      ),
                    ]),
                  ),
                ),
              ],

              // The booking that holds this table — stated before the waiter
              // tries to seat anyone.
              if (hold != null) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _HoldBanner(
                    hold: hold,
                    isManager: widget.isManager,
                    releasing: _releasing,
                    onRelease: _release,
                  ),
                ),
              ],

              // Quick status buttons — party edits are floor-lead work; the
              // kitchen's read-only view skips them entirely.
              if (widget.canEditTable)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final s in const [
                        'available',
                        'occupied',
                        'reserved',
                        'cleaning'
                      ])
                        _QuickStatusButton(
                          status: s,
                          active: _status == s,
                          onTap: () => _quickStatus(s),
                        ),
                    ],
                  ),
                ),

              // Detail form — party edits are floor-lead work; the kitchen's
              // read-only view skips them entirely (the server would refuse
              // the PUT anyway).
              if (widget.canEditTable)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                child: LayoutBuilder(builder: (context, box) {
                  final twoCol = box.maxWidth >= 480;
                  final fields = <Widget>[
                    _LabeledField(
                      label: 'Assigned Server',
                      child: widget.isManager
                          ? _ServerDropdown(
                              value: _server,
                              servers: widget.servers,
                              onChanged: (v) => setState(() => _server = v),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _ReadOnlyField(
                                    value: _server.isEmpty ? '—' : _server),
                                const SizedBox(height: 4),
                                Text('Only a manager can change the assignment',
                                    style: TextStyle(
                                        fontFamily: kFontBody,
                                        fontSize: 10,
                                        color: pal.muted)),
                              ],
                            ),
                    ),
                    _LabeledField(
                      label: 'Guest Count',
                      child: TextFormField(
                        initialValue:
                            _guests > 0 ? '$_guests' : '',
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(hintText: '0'),
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 13,
                            color: pal.heading),
                        onChanged: (v) =>
                            _guests = int.tryParse(v.trim()) ?? 0,
                      ),
                    ),
                    _LabeledField(
                      label: 'Table Notes',
                      wide: true,
                      child: TextFormField(
                        controller: _notesCtrl,
                        decoration: const InputDecoration(
                            hintText: 'Special requests, preferences...'),
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 13,
                            color: pal.heading),
                      ),
                    ),
                  ];
                  // Grid: server + guests 2-up on wide, notes full width.
                  if (twoCol) {
                    return Column(children: [
                      Row(children: [
                        Expanded(child: fields[0]),
                        const SizedBox(width: 12),
                        Expanded(child: fields[1]),
                      ]),
                      const SizedBox(height: 12),
                      fields[2],
                    ]);
                  }
                  return Column(
                    children: [
                      for (final f in fields) ...[
                        f,
                        const SizedBox(height: 12),
                      ],
                    ],
                  );
                }),
              ),

              // Active orders for this table (occupied only)
              if (_status == 'occupied') ...[
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _DetailOrders(
                    orders: _detailOrders,
                    payment: t.payment,
                    billRequestedAt: _billRequestedAt,
                    billRequestedBy: t.billRequestedBy,
                    canServe: widget.canServe,
                    onServe: (o) async {
                      final ok = await widget.onServeOrder(o);
                      if (ok && mounted) _loadOrders();
                      return ok;
                    },
                  ),
                ),
              ],

              // Occupancy info
              if (_status == 'occupied' && _seatedAt.isNotEmpty) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(children: [
                    Icon(Icons.schedule,
                        size: 14,
                        color: occupancyUrgency(widget.table) == 'overdue'
                            ? pal.danger
                            : pal.info),
                    const SizedBox(width: 6),
                    Text('Seated ${occupancyTimer(_seatedAt)} ago',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                            color: pal.info)),
                    if (occupancyUrgency(
                            widget.table.copyWith(seatedAt: _seatedAt)) ==
                        'overdue')
                      Expanded(
                        child: Text(
                            '— past the 4h maximum, releases to cleaning automatically',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: pal.danger)),
                      ),
                  ]),
                ),
              ],

              // The table's memory — every ticket it ran in the last week,
              // any status, kept visible however the status chip turns
              // (owner request: click a table, see its history).
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: _DetailHistory(
                  orders: _detailHistory,
                  tableName: widget.table.name ?? 'Table ${widget.table.number}',
                ),
              ),

              // Actions
              Container(
                margin: const EdgeInsets.only(top: 14),
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: pal.border)),
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (widget.canOrder)
                      SizedBox(
                        height: 34,
                        child: FilledButton.icon(
                          onPressed: () {
                            Navigator.of(context).pop();
                            widget.onNewOrder();
                          },
                          icon: const Icon(Icons.add, size: 14),
                          label: Text(_status == 'occupied'
                              ? 'Add Round'
                              : 'New Order'),
                          style: FilledButton.styleFrom(
                            textStyle: const TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 12,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    if (widget.canFree && _status == 'occupied')
                      SizedBox(
                        height: 34,
                        child: OutlinedButton.icon(
                          onPressed: _freeing ? null : _free,
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: pal.border),
                            textStyle: const TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 12,
                                fontWeight: FontWeight.w600),
                          ),
                          icon: _freeing
                              ? const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Icon(Icons.event_seat_outlined,
                                  size: 14),
                          label: const Text('Free Table'),
                        ),
                      ),
                    if (_status == 'occupied' && widget.canRequestBill)
                      SizedBox(
                        height: 34,
                        child: OutlinedButton.icon(
                          onPressed: _billBusy ? null : () => _bill(_billRequestedAt.isEmpty),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                                color: _billRequestedAt.isNotEmpty
                                    ? pal.warning
                                    : pal.border),
                            textStyle: const TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 12,
                                fontWeight: FontWeight.w600),
                          ),
                          icon: Icon(
                              _billRequestedAt.isNotEmpty
                                  ? Icons.notifications_off_outlined
                                  : Icons.receipt_long_outlined,
                              size: 14),
                          label: Text(_billRequestedAt.isNotEmpty
                              ? 'Cancel Bill Request'
                              : 'Ask for the Bill'),
                        ),
                      ),
                    if (_status == 'occupied' && widget.canCheckout)
                      SizedBox(
                        height: 34,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(context).pop();
                            widget.onGoToCheckout();
                          },
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: pal.border),
                            textStyle: const TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 12,
                                fontWeight: FontWeight.w600),
                          ),
                          icon: const Icon(Icons.credit_card, size: 14),
                          label: const Text('Go to Checkout'),
                        ),
                      ),
                    if (widget.isManager)
                      SizedBox(
                        height: 34,
                        child: OutlinedButton.icon(
                          onPressed: widget.onShowQr,
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: pal.border),
                            textStyle: const TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 12,
                                fontWeight: FontWeight.w600),
                          ),
                          icon: const Icon(Icons.qr_code_2, size: 14),
                          label: const Text('QR Code'),
                        ),
                      ),
                    const SizedBox(width: 4),
                    SizedBox(
                      height: 34,
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text('Close',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 12.5,
                                color: pal.body)),
                      ),
                    ),
                    if (widget.canEditTable)
                      SizedBox(
                        height: 34,
                        child: FilledButton(
                          onPressed: _saving ? null : _save,
                          style: FilledButton.styleFrom(
                            textStyle: const TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700),
                          ),
                          child: Text(_saving ? 'Saving…' : 'Save Changes'),
                        ),
                      ),
                    if (widget.isManager)
                      SizedBox(
                        height: 34,
                        child: OutlinedButton.icon(
                          onPressed: _delete,
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: pal.danger),
                            foregroundColor: pal.danger,
                            textStyle: const TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 12,
                                fontWeight: FontWeight.w600),
                          ),
                          icon: const Icon(Icons.delete_outline, size: 14),
                          label: const Text('Delete'),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The booking banner: what holds the table, until when, and the rule that
/// decides whether it can be seated — spelled out rather than implied by a
/// disabled control.
class _HoldBanner extends StatelessWidget {
  final TableHold hold;
  final bool isManager;
  final bool releasing;
  final VoidCallback onRelease;

  const _HoldBanner({
    required this.hold,
    required this.isManager,
    required this.releasing,
    required this.onRelease,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final window = holdWindowLabel(hold.startAt, hold.endAt);
    final String rule;
    if (!hold.blocksNow) {
      rule =
          'The table is still usable until $leadMinutes minutes before the booking, so a short sitting can be seated now.';
    } else if (isManager) {
      rule =
          'You can release it for a walk-in. The booking is cancelled and recorded against your name.';
    } else {
      rule =
          'It cannot be seated until a manager releases it. It frees itself $graceMinutes minutes after the booked time if nobody arrives.';
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: pal.warningBg,
        border: Border.all(color: pal.warning, width: 1.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              'Reserved — ${hold.name?.isNotEmpty == true ? hold.name : 'no name given'}',
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: pal.heading)),
          const SizedBox(height: 2),
          Text(
              '$window${hold.guests > 0 ? ' · ${hold.guests} guest${hold.guests > 1 ? 's' : ''}' : ''}',
              style: TextStyle(
                  fontFamily: kFontBody, fontSize: 11.5, color: pal.body)),
          const SizedBox(height: 4),
          Text(rule,
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: pal.warning)),
          if (isManager) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 32,
              child: OutlinedButton(
                onPressed: releasing ? null : onRelease,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: pal.warning),
                  foregroundColor: pal.warning,
                  textStyle: const TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 12,
                      fontWeight: FontWeight.w700),
                ),
                child: Text(releasing ? 'Releasing…' : 'Release Table'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The four quick-status pills, each with its own active palette
/// (the web's qs-available/qs-occupied/qs-reserved/qs-cleaning rules).
class _QuickStatusButton extends StatelessWidget {
  final String status;
  final bool active;
  final VoidCallback onTap;

  const _QuickStatusButton({
    required this.status,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    Color bg = pal.surface;
    Color fg = pal.muted;
    Color border = pal.border;
    if (active) {
      switch (status) {
        case 'available':
          bg = dark ? const Color(0x2216A34A) : const Color(0xFFF0FDF4);
          fg = dark ? const Color(0xFF4ADE80) : const Color(0xFF166534);
          border = dark ? const Color(0xFF4ADE80) : const Color(0xFF4ADE80);
          break;
        case 'occupied':
          bg = pal.tintBg;
          fg = pal.primary;
          border = pal.tintBorder;
          break;
        case 'reserved':
          bg = dark ? const Color(0x22FBBF24) : const Color(0xFFFFFBEB);
          fg = dark ? const Color(0xFFFBBF24) : const Color(0xFF92400E);
          border = const Color(0xFFFBBF24);
          break;
        case 'cleaning':
          bg = pal.sunken;
          fg = pal.body;
          border = pal.borderStrong;
          break;
      }
    }
    final label = status.isEmpty
        ? status
        : '${status[0].toUpperCase()}${status.substring(1)}';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border, width: 1.5),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label,
            style: TextStyle(
                fontFamily: kFontBody,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: fg)),
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  final String label;
  final Widget child;
  final bool wide;
  const _LabeledField(
      {required this.label, required this.child, this.wide = false});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontFamily: kFontBody,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: pal.muted)),
        const SizedBox(height: 5),
        child,
      ],
    );
  }
}

class _ReadOnlyField extends StatelessWidget {
  final String value;
  const _ReadOnlyField({required this.value});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      width: double.infinity,
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: pal.sunken,
        border: Border.all(color: pal.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(value,
          style: TextStyle(
              fontFamily: kFontBody, fontSize: 13, color: pal.muted)),
    );
  }
}

/// Manager-only server picker: — Unassigned —, the active head-waiters, and
/// any pre-existing name the roster does not know about stays visible
/// instead of silently jumping to Unassigned on open.
class _ServerDropdown extends StatelessWidget {
  final String value;
  final List<String> servers;
  final ValueChanged<String> onChanged;

  const _ServerDropdown({
    required this.value,
    required this.servers,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final known = servers.map((s) => s.toLowerCase()).toSet();
    final custom = (value.trim().isNotEmpty && !known.contains(value.toLowerCase()))
        ? value
        : '';
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: pal.border),
        borderRadius: BorderRadius.circular(8),
        color: pal.surface,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value.isEmpty || value == custom || servers.contains(value)
              ? (value.isEmpty ? '' : value)
              : '',
          isDense: true,
          isExpanded: true,
          borderRadius: BorderRadius.circular(8),
          items: [
            DropdownMenuItem(
              value: '',
              child: Text('— Unassigned —',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 12.5,
                      color: pal.muted)),
            ),
            for (final s in servers)
              DropdownMenuItem(
                value: s,
                child: Text(s,
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 12.5,
                        color: pal.heading)),
              ),
            if (custom.isNotEmpty)
              DropdownMenuItem(
                value: custom,
                child: Text('$custom (kept)',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 12.5,
                        color: pal.heading)),
              ),
          ],
          onChanged: (v) => onChanged(v ?? ''),
        ),
      ),
    );
  }
}

/// The table's open checks — served-but-unpaid counts, that is the normal
/// state of a table between the kitchen finishing and the guest leaving.
class _DetailOrders extends StatelessWidget {
  final List<FufutOrder>? orders;
  final String? payment;
  final String billRequestedAt;
  final String? billRequestedBy;

  /// Mark Served on fulfilled checks — the waiter's action, right where the
  /// check is read. Null callback / false canServe hides it entirely.
  final bool canServe;
  final Future<bool> Function(FufutOrder order) onServe;

  const _DetailOrders({
    required this.orders,
    required this.payment,
    required this.billRequestedAt,
    required this.billRequestedBy,
    required this.canServe,
    required this.onServe,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('Active Orders',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: pal.heading)),
            if ((payment ?? '').isNotEmpty) ...[
              const SizedBox(width: 8),
              _PayBadge(state: payment!),
            ],
            if (billRequestedAt.isNotEmpty) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                decoration: BoxDecoration(
                  color: const Color(0x24EF4444),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                    'Bill requested${billRequestedBy?.isNotEmpty == true ? ' by $billRequestedBy' : ''}',
                    style: const TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 8.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                        color: Color(0xFFB91C1C))),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        if (orders == null)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (orders!.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: Text('No active orders for this table',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 11.5,
                      color: pal.muted)),
            ),
          )
        else
          for (final o in orders!) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: pal.sunken,
                border: Border.all(color: pal.border),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(shortId(o.id),
                        style: TextStyle(
                            fontFamily: kFontMono,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: pal.muted)),
                    const SizedBox(width: 8),
                    StatusBadge(status: o.status),
                    const Spacer(),
                    Text(formatETB(o.total),
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: pal.heading)),
                  ]),
                  const SizedBox(height: 6),
                  if (o.items.isNotEmpty)
                    Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      children: [
                        for (final line in o.items)
                          Text(
                              '${line.qty}x ${line.name}${line.modifiers.isNotEmpty ? ' (${line.modifiers.map((m) => '${m['name'] ?? ''}').where((n) => n.isNotEmpty).join(', ')})' : ''}',
                              style: TextStyle(
                                  fontFamily: kFontBody,
                                  fontSize: 11,
                                  color: pal.body)),
                      ],
                    )
                  else
                    Text(o.itemsRaw,
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11,
                            color: pal.body)),
                  const SizedBox(height: 6),
                  Row(children: [
                    Text(_fmtTime(o.created),
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 10.5,
                            color: pal.muted)),
                    if (o.customer != null &&
                        o.customer!.isNotEmpty &&
                        o.customer != 'Walk-in') ...[
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(o.customer!,
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w500,
                                color: pal.primary)),
                      ),
                    ],
                  ]),
                  // The floor's handoff word: the kitchen already said
                  // "picked up" (fulfilled) — this is where the waiter says
                  // "served" without leaving the table they are standing at.
                  if (canServe &&
                      o.status.toLowerCase() == 'fulfilled' &&
                      (o.paymentStatus ?? '').toLowerCase() != 'paid')
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: AsyncButton(
                        onPressed: () => onServe(o),
                        icon: Icons.room_service_rounded,
                        label: 'Mark Served',
                        height: 38,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }

  static String _fmtTime(String? iso) => fmtClockStamp(iso);
}

/// The table's history — every ticket it ran in the last seven days, any
/// status, newest first. The party leaving does not erase it: the owner's
/// rule is that clicking a table shows what happened on it, however the
/// status chip currently reads. Collapsed to the four latest tickets with
/// a show-all expander so the panel stays scannable.
class _DetailHistory extends StatefulWidget {
  final List<FufutOrder>? orders;
  final String tableName;

  const _DetailHistory({required this.orders, required this.tableName});

  @override
  State<_DetailHistory> createState() => _DetailHistoryState();
}

class _DetailHistoryState extends State<_DetailHistory> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final orders = widget.orders;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.history_rounded, size: 15, color: pal.muted),
          const SizedBox(width: 6),
          Text('History · last 7 days',
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: pal.heading)),
          const Spacer(),
          if (orders != null && orders.length > 4)
            TextButton(
              onPressed: () => setState(() => _showAll = !_showAll),
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                  _showAll
                      ? 'Show less'
                      : 'Show all (${orders.length})',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: pal.primary)),
            ),
        ]),
        const SizedBox(height: 8),
        if (orders == null)
          const Padding(
            padding: EdgeInsets.all(14),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (orders.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text('No orders on this table in the last 7 days',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 11.5, color: pal.muted)),
          )
        else
          for (final o in (_showAll ? orders : orders.take(4)))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                onTap: () => showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: pal.surface,
                  shape: const RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(16))),
                  constraints: BoxConstraints(
                      maxWidth: 680,
                      maxHeight: MediaQuery.sizeOf(context).height * 0.9),
                  builder: (_) => OrderDetailSheet(order: o),
                ),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: pal.sunken,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: pal.border),
                  ),
                  child: Row(children: [
                    Text(shortId(o.id),
                        style: TextStyle(
                            fontFamily: kFontMono,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: pal.heading)),
                    const SizedBox(width: 8),
                    StatusBadge(status: o.status),
                    const Spacer(),
                    Text(_fmtHistoryTime(o.created),
                        style: TextStyle(
                            fontFamily: kFontMono,
                            fontSize: 10.5,
                            color: pal.muted)),
                    const SizedBox(width: 10),
                    Text(formatETB(o.total),
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: pal.heading)),
                  ]),
                ),
              ),
            ),
      ],
    );
  }

  static String _fmtHistoryTime(String? iso) => fmtWhenStamp(iso);
}

// ─────────────────────────────────────────────────────────────────────────────
// QR modal — the same qrserver.com image the web draws, the guest URL, and
// Print QR Card (the web's print popup, native via a one-page PDF).
// ─────────────────────────────────────────────────────────────────────────────

class _QrModal extends StatelessWidget {
  final String tableNumber;
  final String url;

  const _QrModal({required this.tableNumber, required this.url});

  String get _imageUrl =>
      'https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=${Uri.encodeComponent(url)}';

  Future<void> _print(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // The QR PNG, fetched so the PDF card embeds the real image.
      final resp = await http.get(Uri.parse(_imageUrl));
      if (resp.statusCode != 200) {
        throw ApiError('Could not fetch the QR image');
      }
      final img = pw.MemoryImage(resp.bodyBytes);
      await Printing.layoutPdf(
        onLayout: (format) async {
          final doc = pw.Document();
          doc.addPage(pw.Page(
            pageFormat: format,
            build: (ctx) => pw.Center(
              child: pw.Container(
                padding: const pw.EdgeInsets.all(24),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(width: 2),
                  borderRadius: const pw.BorderRadius.all(
                      pw.Radius.circular(12)),
                ),
                child: pw.Column(
                  mainAxisSize: pw.MainAxisSize.min,
                  children: [
                    pw.Text('FU FUT COFFEE',
                        style: const pw.TextStyle(
                            fontSize: 20, fontWeight: pw.FontWeight.bold)),
                    pw.SizedBox(height: 4),
                    pw.Text('Table $tableNumber',
                        style: const pw.TextStyle(
                            fontSize: 16, fontWeight: pw.FontWeight.bold)),
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(vertical: 12),
                      child: pw.Image(img, width: 180, height: 180),
                    ),
                    pw.Text('Scan to view menu & order from your table'),
                  ],
                ),
              ),
            ),
          ));
          return doc.save();
        },
      );
    } catch (_) {
      showInfoOn(messenger,
          'Could not print the QR card — check your connection');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return AlertDialog(
      title: Text('Table $tableNumber QR Code',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontFamily: kFontBody,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: pal.heading)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Guests scan this code to view the menu and order',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: kFontBody, fontSize: 11.5, color: pal.muted)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Image.network(
              _imageUrl,
              width: 170,
              height: 170,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => SizedBox(
                width: 170,
                height: 170,
                child: Icon(Icons.qr_code_2, size: 64, color: pal.faint),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(url,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 10,
                  color: pal.muted)),
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Close',
              style: TextStyle(
                  fontFamily: kFontBody, color: pal.body)),
        ),
        FilledButton.icon(
          onPressed: () => _print(context),
          icon: const Icon(Icons.print_outlined, size: 15),
          label: const Text('Print QR Card'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Add Table modal (manager) — number, name, capacity, zone, shape picker.
// ─────────────────────────────────────────────────────────────────────────────

class _AddTableSheet extends StatefulWidget {
  final List<String> sections;
  final int defaultNumber;
  final Future<String?> Function({
    required String number,
    required int capacity,
    String? section,
    String? name,
    String shape,
  }) onAdd;

  const _AddTableSheet({
    required this.sections,
    required this.defaultNumber,
    required this.onAdd,
  });

  @override
  State<_AddTableSheet> createState() => _AddTableSheetState();
}

class _AddTableSheetState extends State<_AddTableSheet> {
  late final TextEditingController _numberCtrl =
      TextEditingController(text: '${widget.defaultNumber + 1}');
  late final TextEditingController _nameCtrl = TextEditingController();
  late final TextEditingController _capacityCtrl =
      TextEditingController(text: '4');
  late String _section =
      widget.sections.isNotEmpty ? widget.sections.first : 'Main Hall';
  String _shape = 'square';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _numberCtrl.dispose();
    _nameCtrl.dispose();
    _capacityCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    if (_numberCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Table number is required');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final err = await widget.onAdd(
      number: _numberCtrl.text.trim(),
      capacity: int.tryParse(_capacityCtrl.text.trim()) ?? 4,
      section: _section,
      name: _nameCtrl.text.trim(),
      shape: _shape,
    );
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            0, 0, 0, math.max(MediaQuery.of(context).viewInsets.bottom,
                MediaQuery.of(context).padding.bottom)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Add New Table',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: pal.heading)),
              const SizedBox(height: 2),
              Text('Configure a new table for the floor plan',
                  style: TextStyle(
                      fontFamily: kFontBody, fontSize: 11.5, color: pal.muted)),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: _LabeledField(
                    label: 'Table Number',
                    child: TextFormField(
                      controller: _numberCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(hintText: 'e.g. 16'),
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 13,
                          color: pal.heading),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _LabeledField(
                    label: 'Table Name',
                    child: TextFormField(
                      controller: _nameCtrl,
                      decoration:
                          const InputDecoration(hintText: 'e.g. Patio 4'),
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 13,
                          color: pal.heading),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: _LabeledField(
                    label: 'Capacity (seats)',
                    child: TextFormField(
                      controller: _capacityCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(hintText: '4'),
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 13,
                          color: pal.heading),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _LabeledField(
                    label: 'Section',
                    child: Container(
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        border: Border.all(color: pal.border),
                        borderRadius: BorderRadius.circular(8),
                        color: pal.surface,
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _section,
                          isDense: true,
                          isExpanded: true,
                          borderRadius: BorderRadius.circular(8),
                          items: [
                            for (final s in widget.sections)
                              DropdownMenuItem(
                                value: s,
                                child: Text(s,
                                    style: TextStyle(
                                        fontFamily: kFontBody,
                                        fontSize: 12.5,
                                        color: pal.heading)),
                              ),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _section = v);
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              _LabeledField(
                label: 'Shape',
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final sh in const ['round', 'square', 'long'])
                      _ShapeOption(
                        shape: sh,
                        active: _shape == sh,
                        onTap: () => setState(() => _shape = sh),
                      ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!,
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: pal.danger)),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text('Cancel',
                        style: TextStyle(
                            fontFamily: kFontBody, color: pal.body)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _saving ? null : _submit,
                    style: FilledButton.styleFrom(
                      textStyle: const TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700),
                    ),
                    child: Text(_saving ? 'Adding…' : 'Add Table'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The shape picker — round / square / long, drawn (no assets).
class _ShapeOption extends StatelessWidget {
  final String shape;
  final bool active;
  final VoidCallback onTap;

  const _ShapeOption({
    required this.shape,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? pal.tintBg : pal.surface,
          border: Border.all(color: active ? pal.primary : pal.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          CustomPaint(
            size: const Size(16, 16),
            painter: _ShapeGlyph(shape: shape, color: active ? pal.primary : pal.muted),
          ),
          const SizedBox(width: 6),
          Text(shape,
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: active ? pal.primary : pal.body)),
        ]),
      ),
    );
  }
}

class _ShapeGlyph extends CustomPainter {
  final String shape;
  final Color color;
  _ShapeGlyph({required this.shape, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    switch (shape) {
      case 'round':
        canvas.drawCircle(Offset(size.width / 2, size.height / 2),
            size.width * 0.38, paint);
        break;
      case 'long':
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(1, size.height * 0.3, size.width - 2,
                  size.height * 0.4),
              Radius.circular(size.height * 0.2)),
          paint,
        );
        break;
      default:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(size.width * 0.18, size.height * 0.18,
                  size.width * 0.64, size.height * 0.64),
              Radius.circular(size.width * 0.12)),
          paint,
        );
    }
  }

  @override
  bool shouldRepaint(covariant _ShapeGlyph oldDelegate) =>
      oldDelegate.shape != shape || oldDelegate.color != color;
}


