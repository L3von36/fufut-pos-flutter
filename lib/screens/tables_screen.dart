/// Floor plan — the web POS `TablesView.vue`, native.
///
/// Table cards grouped by section, colored by state. Tap an open table to
/// seat the party; tap an occupied one to open the menu against it (the cart
/// carries the table number into the ticket) or to see its open check.
///
/// **Live via SSE** — the screen subscribes to the fufut-api `tables` event
/// channel (the web's exact wire: a `table_update` snapshot carrying the
/// full floor). Pushes replace the grid within seconds of any seat / claim /
/// bill request from ANY device, then one quiet GET refreshes the open
/// checks the payload does not carry (the badges). The header shows a
/// Live / Offline chip — the web's `tm-live-btn` — and a 15s poll runs only
/// while the stream is disconnected, the kitchen board's safety-net gate.
/// The server role-gates the channel (403 for the kitchen roles); this
/// screen is only reachable for roles whose nav grant includes tables, so
/// no refused connection ever happens.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../api/sse/sse_channel.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/cart.dart';
import '../state/roles.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

class TablesScreen extends StatefulWidget {
  final ValueChanged<NavKey>? onNavigate;

  /// The shell's active-tab notifier — the kitchen board's keep-alive
  /// contract. An offstage floor must not pin a Worker connection.
  final ValueNotifier<NavKey>? activeTab;
  final NavKey? self;

  const TablesScreen({super.key, this.onNavigate, this.activeTab, this.self});

  @override
  State<TablesScreen> createState() => _TablesScreenState();
}

class _TablesScreenState extends State<TablesScreen>
    with WidgetsBindingObserver {
  List<CafeTable> _tables = [];
  List<FufutOrder> _openOrders = [];
  bool _loading = true;
  Object? _error;

  // SSE live channel — one per screen instance, web useSSE parity.
  SseChannel? _sse;
  StreamSubscription<SseEvent>? _sseSub;

  // Same two gates as the kitchen board: app foregrounded AND this screen
  // the shell's active tab (Offstage keep-alive).
  bool _lifecycleUp = true;
  bool _tabUp = true;

  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabUp = widget.self == null || widget.activeTab?.value == widget.self;
    widget.activeTab?.addListener(_onTabChanged);
    _load();
    if (_tabUp) _connectSse();
    // Refresh fallback: only while SSE is NOT connected — when the stream
    // is alive the server pushes every state change within seconds (the
    // kitchen board's identical gate).
    _poll = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_tabUp) return;
      final sse = _sse;
      if (sse == null || !sse.connected.value) _load(quiet: true);
    });
  }

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        app.api.tables(),
        app.api.orders(openOnly: true),
      ]);
      if (!mounted) return;
      setState(() {
        _tables = results[0] as List<CafeTable>;
        _openOrders = results[1] as List<FufutOrder>;
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

  FufutOrder? _checkFor(CafeTable t) {
    for (final o in _openOrders) {
      if (o.tableNum == t.number && !o.isClosed) return o;
    }
    return null;
  }

  void _onTabChanged() {
    if (!mounted) return;
    final up = widget.activeTab?.value == widget.self;
    if (up == _tabUp) return;
    _tabUp = up;
    _syncSse();
    if (up) {
      // Back on stage: the floor may have moved while we were dark.
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
    final app = context.read<AppState>();
    _sseSub?.cancel();
    _sse?.disconnect();
    final sse = SseChannel(
      baseUrl: app.baseUrl,
      channel: 'tables',
      sessionToken: app.client.sessionToken,
    );
    _sse = sse;
    _sseSub = sse.stream.listen(_onSseEvent);
    sse.connect();
  }

  void _onSseEvent(SseEvent event) {
    if (!mounted) return;
    if (event.event != 'table_update') return;

    final data = event.tryDecodeJson();
    final raw = data?['tables'];
    if (raw is! List) {
      // Payload shape unexpected — fetch instead of rendering a stale floor
      // (the web's fallback branch).
      _load(quiet: true);
      return;
    }

    // Parse defensively: one malformed row must never take down the floor.
    final fresh = <CafeTable>[];
    for (final row in raw.whereType<Map>()) {
      try {
        fresh.add(CafeTable.fromJson(Map<String, dynamic>.from(row)));
      } catch (_) {}
    }

    setState(() {
      _tables = fresh;
      _loading = false;
      _error = null;
    });

    // The snapshot carries tables only — one GET refreshes the open checks
    // the badges read (kitchen board's _refreshLines pattern).
    _refreshOrders();
  }

  Future<void> _refreshOrders() async {
    final app = context.read<AppState>();
    try {
      final orders = await app.api.orders(openOnly: true);
      if (!mounted) return;
      setState(() => _openOrders = orders);
    } catch (_) {
      // The checks feed is allowed to fail on its own: the floor still
      // renders from the pushed tables.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Web visibilitychange parity: hidden screens pause the stream so a
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
    _sseSub?.cancel();
    _sse?.disconnect();
    super.dispose();
  }

  Future<void> _claim(CafeTable t) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.claimTable(t);
      showInfoOn(messenger, 'Table ${t.number} seated');
      await _load(quiet: true);
      // Straight into the order — the web jumps to the menu the same way.
      if (mounted) {
        context.read<CartState>().setTable(t.number);
        widget.onNavigate?.call(NavKey.menuView);
      }
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Future<void> _openMenuFor(CafeTable t) async {
    context.read<CartState>().setTable(t.number);
    widget.onNavigate?.call(NavKey.menuView);
  }

  void _tableTap(CafeTable t) {
    final occupied = t.status == 'occupied';
    if (!occupied) {
      _claim(t);
      return;
    }
    final check = _checkFor(t);
    // Bill-request write is head-waiter + manager, exactly the web's
    // canRequestBill = ['head-waiter','manager'].
    final app = context.read<AppState>();
    final canRequestBill = app.roleKey == 'head-waiter' || app.roleKey == 'manager';
    showModalBottomSheet(
      context: context,
      builder: (ctx) => _TableSheet(
        table: t,
        check: check,
        canRequestBill: canRequestBill,
        onRequestBill: () {
          Navigator.pop(ctx);
          _requestBill(t);
        },
        onCancelBillRequest: () {
          Navigator.pop(ctx);
          _cancelBillRequest(t);
        },
        onAddRound: () {
          Navigator.pop(ctx);
          _openMenuFor(t);
        },
        onViewCheck: check == null
            ? null
            : () {
                Navigator.pop(ctx);
                widget.onNavigate?.call(NavKey.openChecks);
              },
      ),
    );
  }

  /// `POST /api/tables/:id/request-bill` — the party wants the bill; it
  /// rides to the cashier's dashboard Bill Requests card.
  Future<void> _requestBill(CafeTable t) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.requestBill(t.id);
      showInfoOn(messenger, 'Bill requested for table ${t.number}');
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Future<void> _cancelBillRequest(CafeTable t) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.cancelBillRequest(t.id);
      showInfoOn(messenger, 'Bill request withdrawn');
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _tables.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _tables.isEmpty) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final pal = Pal.of(context);
    // Section order: server rows grouped, sections alphabetically, unsectioned last.
    final sections = <String, List<CafeTable>>{};
    for (final t in _tables) {
      sections.putIfAbsent(t.section?.trim().isNotEmpty == true
          ? t.section!.trim()
          : 'Floor', () => []).add(t);
    }
    final names = sections.keys.toList()..sort();

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          // Legend — the floor's color code, same hues as the web.
          Row(children: [
            _legendDot(pal.success, 'Free'),
            const SizedBox(width: 10),
            _legendDot(pal.warning, 'Occupied'),
            const SizedBox(width: 10),
            _legendDot(pal.info, 'Reserved'),
            const SizedBox(width: 10),
            _legendDot(pal.goldDark, 'Cleaning'),
            const Spacer(),
            _LiveChip(connected: _sse?.connected),
            const SizedBox(width: 8),
            Text(
              '${_tables.where((t) => t.status == "occupied").length}/${_tables.length} seated',
              style: TextStyle(
                  fontFamily: kFontMono,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: pal.muted),
            ),
          ]),
          for (final name in names) ...[
            const SizedBox(height: 14),
            Text(name.toUpperCase(),
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: pal.muted)),
            const SizedBox(height: 8),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.5,
              ),
              itemCount: sections[name]!.length,
              itemBuilder: (context, i) =>
                  _TableCard(table: sections[name]![i], onTap: _tableTap),
            ),
          ],
        ],
      ),
    );
  }

  Widget _legendDot(Color c, String label) {
    final pal = Pal.of(context);
    return Row(children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: c)),
      const SizedBox(width: 4),
      Text(label,
          style: TextStyle(fontFamily: kFontBody, fontSize: 10.5, color: pal.muted)),
    ]);
  }
}

/// The web's `tm-live-btn`: a green-pulsing Live chip while the tables
/// stream is up, a dim Offline chip while the 15s poll carries the floor.
class _LiveChip extends StatelessWidget {
  final ValueNotifier<bool>? connected;
  const _LiveChip({required this.connected});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final listenable = connected;
    if (listenable == null) return _chip(pal, false);
    return ValueListenableBuilder<bool>(
      valueListenable: listenable,
      builder: (context, up, _) => _chip(pal, up),
    );
  }

  Widget _chip(Pal pal, bool up) {
    final color = up ? pal.success : pal.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: up ? 0.12 : 0.07),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 4),
        Text(up ? 'Live' : 'Offline',
            style: TextStyle(
                fontFamily: kFontBody,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: color)),
      ]),
    );
  }
}

class _TableCard extends StatelessWidget {
  final CafeTable table;
  final ValueChanged<CafeTable> onTap;

  const _TableCard({required this.table, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final status = table.status.toLowerCase();
    final Color color;
    switch (status) {
      case 'occupied': color = pal.warning;
      case 'reserved': color = pal.info;
      case 'cleaning': color = pal.goldDark;
      default: color = pal.success;
    }
    return Material(
      color: pal.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: () => onTap(table),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.55), width: 1.2),
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(children: [
                Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
                const SizedBox(width: 5),
                Expanded(
                  child: Text('T${table.number}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: pal.heading)),
                ),
                if (table.seats != null)
                  Text('${table.seats}p',
                      style: TextStyle(
                          fontFamily: kFontMono, fontSize: 10, color: pal.faint)),
              ]),
              const SizedBox(height: 2),
              Row(children: [
                Expanded(
                  child: Text(
                    status == 'occupied' ? 'Seated' : status,
                    style: TextStyle(
                        fontFamily: kFontBody, fontSize: 10, color: color),
                  ),
                ),
                if (table.billRequested) ...[
                  Icon(Icons.notifications_active,
                      size: 11, color: pal.danger),
                  const SizedBox(width: 3),
                  Text('BILL',
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 8.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                          color: pal.danger)),
                ],
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _TableSheet extends StatelessWidget {
  final CafeTable table;
  final FufutOrder? check;
  final bool canRequestBill;
  final VoidCallback onAddRound;
  final VoidCallback? onRequestBill;
  final VoidCallback? onCancelBillRequest;
  final VoidCallback? onViewCheck;

  const _TableSheet({
    required this.table,
    required this.check,
    required this.onAddRound,
    this.canRequestBill = false,
    this.onRequestBill,
    this.onCancelBillRequest,
    this.onViewCheck,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Table ${table.number}',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: pal.heading)),
            if (check != null) ...[
              const SizedBox(height: 4),
              Text(
                '${shortId(check!.id)} · ${check!.itemsRaw} · ${money(check!.total)} ${check!.isPaid ? '· PAID' : '· UNPAID'}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 11.5, color: pal.muted),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              height: 36,
              child: FilledButton.icon(
                onPressed: onAddRound,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add a round'),
              ),
            ),
            if (onViewCheck != null) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 36,
                child: OutlinedButton.icon(
                  onPressed: onViewCheck,
                  icon: const Icon(Icons.credit_card, size: 16),
                  label: const Text('Open check'),
                ),
              ),
            ],
            // Bill request — the web's "Ask for the Bill" flow. Occupied
            // tables only, head-waiter / manager only.
            if (canRequestBill && !table.billRequested) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 36,
                child: OutlinedButton.icon(
                  onPressed: onRequestBill,
                  style: OutlinedButton.styleFrom(
                      side: BorderSide(color: pal.warning)),
                  icon: const Icon(Icons.notifications_active_outlined,
                      size: 16),
                  label: Text('Ask for the Bill',
                      style: TextStyle(color: pal.warning)),
                ),
              ),
            ],
            if (canRequestBill && table.billRequested) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 36,
                child: OutlinedButton.icon(
                  onPressed: onCancelBillRequest,
                  style: OutlinedButton.styleFrom(
                      side: BorderSide(color: pal.danger)),
                  icon: const Icon(Icons.notifications_off_outlined,
                      size: 16),
                  label: Text('Cancel Bill Request',
                      style: TextStyle(color: pal.danger)),
                ),
              ),
            ],
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}
