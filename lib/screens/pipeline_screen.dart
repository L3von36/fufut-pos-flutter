/// Pipeline — the web `PipelineView.vue`: every order as a kanban across
/// New / Preparing / Ready / Served / Cancelled, with the kitchen SSE channel
/// for push updates, a detail sheet with the status timeline and the legal
/// transitions, and manager-only cancel. Cards can be moved with the buttons
/// (drag on a kanban is a mouse luxury; taps are universal).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../api/sse/sse_channel.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/order_scope.dart';
import '../state/roles.dart';
import '../theme.dart';
import '../widgets/backoffice.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

class PipelineScreen extends StatefulWidget {
  final ValueNotifier<NavKey>? activeTab;
  final NavKey? self;

  const PipelineScreen({super.key, this.activeTab, this.self});

  @override
  State<PipelineScreen> createState() => _PipelineScreenState();
}

class _PipelineScreenState extends State<PipelineScreen> {
  List<FufutOrder> _orders = [];
  bool _loading = true;
  Object? _error;
  SseChannel? _channel;
  Timer? _poll;
  bool get _sseConnected => _channel?.connected.value ?? false;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _load();
    _connect();
    widget.activeTab?.addListener(_lifecycle);
    // Elapsed timers tick once a second, like the web's clockTimer.
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.activeTab?.removeListener(_lifecycle);
    _channel?.suspend();
    _poll?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  /// The keep-alive shell keeps this screen built while offstage; suspend the
  /// SSE connection exactly when the tab is not on stage (the kitchen board's
  /// connection hygiene).
  void _lifecycle() {
    final onStage = widget.activeTab?.value == widget.self;
    if (onStage) {
      _channel?.resume();
      _load(quiet: true);
    } else {
      _channel?.suspend();
      _poll?.cancel();
      _poll = null;
    }
  }

  void _connect() {
    final app = context.read<AppState>();
    final ch = SseChannel(
      baseUrl: app.baseUrl,
      channel: 'kitchen',
      sessionToken: app.client.sessionToken,
    );
    ch.connected.addListener(_onConnChange);
    ch.stream.listen((evt) {
      if (!mounted) return;
      if (evt.event == 'new_order' || evt.event == 'order_update') {
        // Both payloads carry the full orders snapshot — apply directly,
        // then refresh the per-line feed quietly.
        _applySnapshot(evt.data);
        _refreshFromApi();
      }
    });
    _channel = ch;
    ch.connect();
  }

  void _onConnChange() {
    if (!mounted) return;
    final connected = _sseConnected;
    if (connected) {
      _poll?.cancel();
      _poll = null;
      _load(quiet: true);
    } else {
      _poll ??= Timer.periodic(const Duration(seconds: 15), (_) {
        if (mounted && !_sseConnected) _load(quiet: true);
      });
    }
    setState(() {});
  }

  void _applySnapshot(dynamic data) {
    final rows = data is Map ? data['orders'] : data;
    if (rows is! List) return;
    final parsed = rows
        .whereType<Map>()
        .map((m) => FufutOrder.fromJson(Map<String, dynamic>.from(m)))
        .toList();
    if (!mounted) return;
    setState(() => _orders = parsed);
  }

  Future<void> _refreshFromApi() async {
    final app = context.read<AppState>();
    try {
      final rows = await app.api.orders();
      if (!mounted) return;
      setState(() => _orders = rows);
    } catch (_) {
      // Push already updated us; the refetch is best-effort.
    }
  }

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final rows = await app.api.orders();
      if (!mounted) return;
      setState(() { _orders = rows; _loading = false; });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) { await app.sessionExpired(); return; }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  String get _role => context.read<AppState>().roleKey ?? '';
  bool get _canCancel => _role == 'manager';

  static const _lanes = [
    ('new', 'New', Icons.fiber_new_outlined),
    ('preparing', 'Preparing', Icons.local_fire_department_outlined),
    ('ready', 'Ready', Icons.done_all_outlined),
    ('served', 'Served', Icons.room_service_outlined),
    ('cancelled', 'Cancelled', Icons.cancel_outlined),
  ];

  List<FufutOrder> _lane(String status) {
    // Today only: the pipeline is the kitchen's live board, not an archive.
    // Previous-day leftovers (usually stale tickets nobody closed out) go to
    // Order History; the count is surfaced so nothing silently vanishes.
    // Filtering at render covers every _orders writer — load, SSE snapshot
    // and the quiet refetch alike.
    final rows = _orders
        .where(orderIsToday)
        .where((o) => o.status.toLowerCase() == status)
        .toList();
    rows.sort((a, b) => (a.created ?? '').compareTo(b.created ?? ''));
    return rows;
  }

  int get _olderHiddenCount => _orders.where((o) => !orderIsToday(o)).length;

  Future<void> _advance(FufutOrder o, String status) async {
    final messenger = ScaffoldMessenger.of(context);
    final app = context.read<AppState>();
    // Optimistic move, revert on refusal — the web drag contract.
    setState(() {
      _orders = [
        for (final x in _orders)
          if (x.id == o.id)
            FufutOrder(
              id: x.id, status: status, type: x.type, tableNum: x.tableNum,
              customer: x.customer, customerPhone: x.customerPhone,
              notes: x.notes, total: x.total, subtotal: x.subtotal,
              discount: x.discount, tip: x.tip, deliveryFee: x.deliveryFee,
              payment: x.payment, paymentStatus: x.paymentStatus,
              created: x.created, updatedAt: x.updatedAt,
              createdByName: x.createdByName, createdById: x.createdById,
              items: x.items, itemsRaw: x.itemsRaw,
            )
          else
            x,
      ];
    });
    try {
      await app.api.updateStatus(o, status);
      showInfoOn(messenger, '#${shortId(o.id)} → $status');
    } catch (e) {
      if (!mounted) return;
      showErrorOn(messenger, e);
      await _load(quiet: true);
    }
  }

  Future<void> _detail(FufutOrder o) async {
    final pal = Pal.of(context);
    await showModalBottomSheet(
      context: context,
      backgroundColor: pal.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        // Bottom clears the edge-to-edge gesture nav bar on Android.
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.paddingOf(ctx).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Text('Order #${shortId(o.id)}',
                    style: TextStyle(
                        fontFamily: kFontMono,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: pal.heading)),
              ),
              Text(o.status.toUpperCase(),
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: pal.primary)),
            ]),
            const SizedBox(height: 4),
            Text(
                '${o.type ?? '—'}${o.tableNum != null ? ' · Table ${o.tableNum}' : ''}'
                ' · ${o.customer ?? 'Walk-in'} · ${money(o.total)}'
                '${o.createdByName != null ? ' · by ${o.createdByName}' : ''}',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 11, color: pal.muted)),
            const SizedBox(height: 10),
            for (final l in o.items.take(12))
              ListRow(
                  head: '${l.qty}× ${l.name}',
                  rest: l.notes,
                  trailing: money(l.lineTotal)),
            if (o.items.isEmpty)
              ListRow(head: o.itemsRaw, rest: null, trailing: ''),
            const SizedBox(height: 12),
            Text('Move to',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: pal.muted)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (status, label, _) in _lanes)
                  if (status != o.status)
                    RowAction(label, () {
                      Navigator.pop(ctx);
                      _advance(o, status);
                    }),
                if (_canCancel)
                  RowAction('Cancel', () {
                    Navigator.pop(ctx);
                    _advance(o, 'cancelled');
                  }, color: pal.danger),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _elapsed(FufutOrder o) {
    final c = DateTime.tryParse(o.created ?? '');
    if (c == null) return '';
    final d = DateTime.now().difference(c);
    if (d.isNegative) return '';
    final m = d.inMinutes;
    if (m < 60) return '${m}m';
    return '${d.inHours}h${m % 60}m';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _orders.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _orders.isEmpty) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final pal = Pal.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          child: Row(children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _sseConnected ? pal.success : pal.warning,
              ),
            ),
            const SizedBox(width: 6),
            Text(_sseConnected ? 'Live' : 'Offline — polling',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: _sseConnected ? pal.success : pal.warning)),
            const Spacer(),
            Text('${_orders.length} orders',
                style: TextStyle(
                    fontFamily: kFontMono, fontSize: 10.5, color: pal.faint)),
          ]),
        ),
        if (_olderHiddenCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
            child: Row(children: [
              Icon(Icons.history_rounded, size: 12, color: pal.warning),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '$_olderHiddenCount earlier ticket'
                  '${_olderHiddenCount != 1 ? 's' : ''} from previous days'
                  ' hidden — see Order History',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 10.5,
                      color: pal.muted),
                ),
              ),
            ]),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(quiet: true),
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(12),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (status, label, icon) in _lanes)
                      Container(
                        width: 252,
                        margin: const EdgeInsets.only(right: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 7),
                              decoration: BoxDecoration(
                                color: pal.sunken,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: pal.border),
                              ),
                              child: Row(children: [
                                Icon(icon, size: 13, color: pal.muted),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text('$label · ${_lane(status).length}',
                                      style: TextStyle(
                                          fontFamily: kFontBody,
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w700,
                                          color: pal.heading)),
                                ),
                              ]),
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: ListView(
                                children: [
                                  for (final o in _lane(status))
                                    _card(o, pal, status),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _card(FufutOrder o, Pal pal, String lane) {
    final elapsed = _elapsed(o);
    final late = (int.tryParse(elapsed.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0) > 10;
    return InkWell(
      onTap: () => _detail(o),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: pal.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: lane == 'cancelled'
                  ? pal.dangerBorder
                  : late
                      ? pal.warningBorder
                      : pal.border,
              width: late ? 1.2 : 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text('#${shortId(o.id)}',
                    style: TextStyle(
                        fontFamily: kFontMono,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: pal.heading)),
              ),
              Text(elapsed,
                  style: TextStyle(
                      fontFamily: kFontMono,
                      fontSize: 10,
                      color: late ? pal.warning : pal.faint)),
            ]),
            const SizedBox(height: 2),
            Text(
                '${o.type ?? '—'}${o.tableNum != null ? ' · T${o.tableNum}' : ''} · ${o.customer ?? 'Walk-in'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 10, color: pal.muted)),
            const SizedBox(height: 4),
            Text(
                o.items.isEmpty
                    ? o.itemsRaw
                    : o.items.take(3).map((l) => '${l.qty}×${l.name}').join(', '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 10.5, color: pal.body)),
            const SizedBox(height: 4),
            Text(money(o.total),
                style: TextStyle(
                    fontFamily: kFontMono,
                    fontSize: 11,
                    fontWeight: FontWeight.w700, color: pal.body)),
          ],
        ),
      ),
    );
  }
}
