/// Pipeline — the web `PipelineView.vue`: every order as a kanban across
/// New / Preparing / Ready / Served / Cancelled, with the shared kitchen
/// feed for push updates, a detail sheet with the status timeline and the
/// legal transitions, and manager-only cancel. Cards can be moved with the
/// buttons (drag on a kanban is a mouse luxury; taps are universal).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../state/app_time.dart' show fmtDur, parseStamp;
import '../state/clock.dart';
import '../state/live_feeds.dart';
import '../state/order_scope.dart';
import '../state/session_providers.dart';
import '../theme.dart';
import '../widgets/backoffice.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

class PipelineScreen extends ConsumerStatefulWidget {
  const PipelineScreen({super.key});

  @override
  ConsumerState<PipelineScreen> createState() => _PipelineScreenState();
}

class _PipelineScreenState extends ConsumerState<PipelineScreen> {
  /// build() watches the shared kitchen feed — these getters read the same
  /// snapshot during that build. No private channel, poll or clock: the
  /// feed pushes, the poll fallback lives there, and the 1s elapsed
  /// refresh is the wall clock.
  List<FufutOrder> get _orders => ref.read(kitchenFeedProvider).orders;
  bool get _sseConnected => ref.read(kitchenFeedProvider).connected;

  bool get _canCancel => ref.watch(roleProvider) == 'manager';

  Future<void> _reload() =>
      ref.read(kitchenFeedProvider.notifier).refresh();

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
    final feed = ref.read(kitchenFeedProvider.notifier);
    // Optimistic move, revert on refusal — the web drag contract.
    feed.applyOptimistic(o.id, status);
    try {
      await ref.read(fufutApiProvider).updateStatus(o, status);
      showInfoOn(messenger, '#${shortId(o.id)} → $status');
    } catch (e) {
      if (!mounted) return;
      showErrorOn(messenger, e);
      await _reload(); // wholesale revert to server truth
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
                    AsyncRowAction(label, () async {
                      Navigator.pop(ctx);
                      await _advance(o, status);
                    }),
                if (_canCancel)
                  AsyncRowAction('Cancel', () async {
                    Navigator.pop(ctx);
                    await _advance(o, 'cancelled');
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
    final c = parseStamp(o.created);
    if (c == null) return '';
    final d = DateTime.now().difference(c);
    if (d.isNegative) return '';
    return fmtDur(d);
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(kitchenFeedProvider);
    // Elapsed timers tick once a second, like the web's clockTimer — the
    // shared wall clock instead of a private Timer.
    ref.watch(wallClockProvider);
    if (feed.loading && feed.orders.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (feed.error != null && feed.orders.isEmpty) {
      return LoadError(error: feed.error!, onRetry: () => _reload());
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
            onRefresh: _reload,
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
