/// My Activity — the web `MyPerformanceView.vue`, native.
///
/// The signed-in staff member's own audit trail: `GET /api/audit?actor_id=me`
/// over a range (today / week / month / year), with KPI tiles computed from
/// the entries exactly like the web's per-role `buildKpis()`, by-area and
/// by-action breakdowns, and a tappable timeline whose rows open a
/// before → after diff.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

/// The signed-in member's audit trail for a range. The actor is the session
/// user — read, not watched; the screen remounts per login and autoDispose
/// clears the trail on logout — so the range is the only key that changes
/// the server call.
final myActivityProvider =
    FutureProvider.family<List<AuditEntry>, String>((ref, from) async {
  // Read, never watch: the fetch must not rebuild on its own session echo.
  final app = ref.read(appStateProvider);
  final me = app.user;
  if (me == null) return const <AuditEntry>[];
  try {
    return await app.api.audit(actorId: me.id, from: from);
  } on ApiError catch (e) {
    if (e.isAuthError) await app.sessionExpired();
    rethrow;
  }
});

class MyActivityScreen extends ConsumerStatefulWidget {
  const MyActivityScreen({super.key});

  @override
  ConsumerState<MyActivityScreen> createState() => _MyActivityScreenState();
}

class _MyActivityScreenState extends ConsumerState<MyActivityScreen> {
  String _range = 'today';

  void _reload() => ref.invalidate(myActivityProvider(_from));

  /// `from` for each range chip — local-time stamps, same as the web.
  String get _from {
    final n = DateTime.now();
    String two(int v) => v < 10 ? '0$v' : '$v';
    final today = '${n.year}-${two(n.month)}-${two(n.day)}';
    switch (_range) {
      case 'week':
        final w = n.subtract(const Duration(days: 7));
        return '${w.year}-${two(w.month)}-${two(w.day)}';
      case 'month':
        final m = DateTime(n.year, n.month - 1, n.day);
        return '${m.year}-${two(m.month)}-${two(m.day)}';
      case 'year':
        final y = DateTime(n.year - 1, n.month, n.day);
        return '${y.year}-${two(y.month)}-${two(y.day)}';
      default:
        return today;
    }
  }

  List<(String, int)> _kpisFor(String role, List<AuditEntry> entries) {
    int countByEntity(String entity) => entries
        .where((e) => e.entity.toLowerCase() == entity)
        .length;
    int countWhere(bool Function(AuditEntry) test) =>
        entries.where(test).length;
    String afterStatus(AuditEntry e) {
      final a = e.after;
      if (a is Map) return '${a['status'] ?? ''}'.toLowerCase();
      if (a is String) {
        try {
          final m = jsonDecode(a);
          if (m is Map) return '${m['status'] ?? ''}'.toLowerCase();
        } catch (_) {}
      }
      return '';
    }

    switch (role) {
      case 'manager':
      case 'accountant':
        return [
          ('Orders touched', countByEntity('orders')),
          ('Payments verified', countByEntity('payments')),
          ('Expenses booked', countByEntity('expenses')),
          ('Staff edits', countByEntity('staff')),
          ('Cash drawer ops', countByEntity('cashdrawer')),
          ('Deliveries settled', countByEntity('delivery')),
        ];
      case 'head-chef':
      case 'assistant-chef':
        final dishesSent = countWhere((e) =>
            e.entity.toLowerCase() == 'orders' &&
            e.action.toLowerCase() == 'update' &&
            ['ready', 'served'].contains(afterStatus(e)));
        final tickets = countWhere((e) =>
            e.entity.toLowerCase() == 'orders' &&
            afterStatus(e) == 'preparing');
        return [
          ('Dishes sent', dishesSent),
          ('Tickets started', tickets),
          ('Inventory adjusts', countByEntity('inventory')),
          ('Waste logged', countByEntity('waste')),
        ];
      case 'head-waiter':
        return [
          ('Orders taken',
              countWhere((e) => e.action.toLowerCase() == 'create')),
          ('Tables touched', countByEntity('tables')),
          ('Tips recorded', countByEntity('tips')),
          ('Reservations', countByEntity('reservations')),
        ];
      case 'cashier':
        return [
          ('Payments verified',
              countWhere((e) => ['verify', 'create'].contains(e.action.toLowerCase()))),
          ('Cash drawer ops', countByEntity('cashdrawer')),
          ('Orders settled', countWhere((e) =>
              e.entity.toLowerCase() == 'orders' &&
              RegExp(r'paid|settled|completed').hasMatch(afterStatus(e)))),
          ('Refunds issued', countByEntity('refunds')),
        ];
      case 'delivery-staff':
        return [
          ('Jobs taken', countWhere((e) => afterStatus(e) == 'assigned')),
          ('Picked up', countWhere((e) => afterStatus(e) == 'picked_up')),
          ('Delivered', countWhere((e) => afterStatus(e) == 'delivered')),
          ('Payments recorded', countByEntity('payments')),
        ];
      case 'cleaner':
        return [
          ('Waste logged', countByEntity('waste')),
          ('Tables cleared', countByEntity('tables')),
          ('Time clock punches', countByEntity('timeclock')),
        ];
      default:
        return [
          ('Orders touched', countByEntity('orders')),
          ('Payments', countByEntity('payments')),
          ('Tables', countByEntity('tables')),
          ('Other actions', entries.length),
        ];
    }
  }

  List<(String, int)> _topBy(bool byArea, List<AuditEntry> entries) {
    final counts = <String, int>{};
    for (final e in entries) {
      final key = (byArea ? e.entity : e.action).toLowerCase();
      if (key.isEmpty) continue;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final rows = counts.entries.map((e) => (e.key, e.value)).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return rows.take(6).toList();
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(myActivityProvider(_from));
    final entries = entriesAsync.value ?? const <AuditEntry>[];
    if (entriesAsync.isLoading && entries.isEmpty) {
      return const DashboardSkeleton();
    }
    if (entriesAsync.hasError && entries.isEmpty) {
      return LoadError(error: entriesAsync.error!, onRetry: _reload);
    }
    final pal = Pal.of(context);
    final app = ref.read(appStateProvider);
    final role = app.roleKey ?? '';
    final kpis = _kpisFor(role, entries);
    final byArea = _topBy(true, entries);
    final byAction = _topBy(false, entries);

    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 4),
          Text('${entries.length} actions in range',
              style: TextStyle(
                  fontFamily: kFontMono,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: pal.muted)),
          const SizedBox(height: 10),
          // ── Range chips ─────────────────────────────────────────────────
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final r in const [
                  ('today', 'Today'),
                  ('week', 'This Week'),
                  ('month', 'This Month'),
                  ('year', 'This Year'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(r.$2),
                      selected: _range == r.$1,
                      labelStyle: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _range == r.$1 ? Colors.white : pal.body),
                      selectedColor: pal.primary,
                      backgroundColor: pal.sunken,
                      side: BorderSide(
                          color: _range == r.$1 ? pal.primary : pal.border),
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) {
                        setState(() => _range = r.$1);
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // ── KPI tiles ───────────────────────────────────────────────────
          for (var i = 0; i < kpis.length; i += 2)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(
                  child: KpiCard(
                      label: kpis[i].$1, value: '${kpis[i].$2}'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: i + 1 < kpis.length
                      ? KpiCard(
                          label: kpis[i + 1].$1,
                          value: '${kpis[i + 1].$2}')
                      : const SizedBox.shrink(),
                ),
              ]),
            ),
          const SizedBox(height: 4),
          // ── Breakdowns ──────────────────────────────────────────────────
          if (byArea.isNotEmpty)
            _breakdown(context, 'By Area', byArea),
          if (byAction.isNotEmpty) ...[
            const SizedBox(height: 10),
            _breakdown(context, 'By Action', byAction),
          ],
          const SizedBox(height: 12),
          // ── Timeline ────────────────────────────────────────────────────
          SectionCard(
            title: 'Activity Timeline',
            trailing: Icon(Icons.history, size: 15, color: pal.faint),
            children: [
              if (entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                    child: Text('Nothing logged in this range',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11.5,
                            color: pal.faint)),
                  ),
                )
              else
                for (final e in entries.take(50))
                  _timelineRow(context, e),
            ],
          ),
        ],
      ),
    );
  }

  Widget _breakdown(BuildContext context, String title, List<(String, int)> rows) {
    final pal = Pal.of(context);
    final max = rows.fold<int>(0, (m, r) => r.$2 > m ? r.$2 : m);
    return SectionCard(
      title: title,
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 104,
                  child: Text(r.$1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: pal.body)),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: max == 0 ? 0 : r.$2 / max,
                      minHeight: 6,
                      backgroundColor: pal.sunken,
                      color: pal.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 26,
                  child: Text('${r.$2}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          fontFamily: kFontMono,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: pal.heading)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _timelineRow(BuildContext context, AuditEntry e) {
    final pal = Pal.of(context);
    return InkWell(
      onTap: () => _openDetail(context, e),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: pal.border, width: 0.5)),
        ),
        child: Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: pal.tintBg,
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(e.entity.isEmpty ? 'other' : e.entity,
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: pal.primary)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  text: e.action,
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: pal.heading),
                  children: [
                    if (e.reason.isNotEmpty)
                      TextSpan(
                          text: '  ·  ${e.reason}',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                              color: pal.muted)),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(_fmtTime(e.at),
                style: TextStyle(
                    fontFamily: kFontMono,
                    fontSize: 10.5,
                    color: pal.faint)),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 14, color: pal.faint),
          ],
        ),
      ),
    );
  }

  void _openDetail(BuildContext context, AuditEntry e) {
    final pal = Pal.of(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: pal.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      builder: (_) => _EntryDetailSheet(entry: e),
    );
  }

  static String _fmtTime(String? at) {
    if (at == null || at.isEmpty) return '';
    final t = DateTime.tryParse(at);
    if (t == null) return at;
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${two(t.hour)}:${two(t.minute)}';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Detail sheet — when / what / why, and the before → after diff.
// ─────────────────────────────────────────────────────────────────────────────

class _EntryDetailSheet extends StatelessWidget {
  final AuditEntry entry;
  const _EntryDetailSheet({required this.entry});

  static const _moneyFields = ['total', 'amount', 'price', 'cost', 'subtotal', 'tip'];
  static const _skipFields = ['id', 'created', 'updated_at'];

  Map<String, dynamic> _asMap(dynamic v) {
    if (v is Map) return Map<String, dynamic>.from(v);
    if (v is String && v.isNotEmpty) {
      try {
        final m = jsonDecode(v);
        if (m is Map) return Map<String, dynamic>.from(m);
      } catch (_) {}
    }
    return {};
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final before = _asMap(entry.before);
    final after = _asMap(entry.after);
    final keys = <String>{
      ...before.keys.where((k) => !_skipFields.contains(k)),
      ...after.keys.where((k) => !_skipFields.contains(k)),
    }.toList()..sort();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                      '${entry.entity.isEmpty ? 'Other' : entry.entity} · ${entry.action}',
                      style:
                          T.screenTitle.copyWith(color: pal.heading)),
                ),
              ],
            ),
            Text(
              '${entry.at}  ·  ${entry.actorName}'
              '${entry.actorRole.isNotEmpty ? ' (${entry.actorRole})' : ''}'
              '${entry.entityId.isNotEmpty ? '  ·  ${shortId(entry.entityId)}' : ''}',
              style: TextStyle(
                  fontFamily: kFontMono, fontSize: 10.5, color: pal.muted),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (entry.reason.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: pal.sunken.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.sticky_note_2_outlined,
                                size: 14, color: pal.muted),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text('Reason: ${entry.reason}',
                                  style: TextStyle(
                                      fontFamily: kFontBody,
                                      fontSize: 11.5,
                                      color: pal.body)),
                            ),
                          ],
                        ),
                      ),
                    if (keys.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: pal.border),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: pal.sunken,
                                borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(10)),
                              ),
                              child: Row(children: [
                                Expanded(
                                    child: Text('FIELD',
                                        style: TextStyle(
                                            fontFamily: kFontBody,
                                            fontSize: 9,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.8,
                                            color: pal.muted))),
                                SizedBox(
                                    width: 92,
                                    child: Text('BEFORE',
                                        style: TextStyle(
                                            fontFamily: kFontBody,
                                            fontSize: 9,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.8,
                                            color: pal.muted))),
                                SizedBox(
                                    width: 92,
                                    child: Text('AFTER',
                                        style: TextStyle(
                                            fontFamily: kFontBody,
                                            fontSize: 9,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.8,
                                            color: pal.muted))),
                              ]),
                            ),
                            for (final k in keys)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  border: Border(
                                      top: BorderSide(
                                          color: pal.border, width: 0.5)),
                                ),
                                child: Row(children: [
                                  Expanded(
                                      child: Text(k,
                                          style: TextStyle(
                                              fontFamily: kFontBody,
                                              fontSize: 10.5,
                                              color: pal.body))),
                                  SizedBox(
                                      width: 92,
                                      child: Text(_fmtVal(k, before[k]),
                                          style: TextStyle(
                                              fontFamily: kFontMono,
                                              fontSize: 10.5,
                                              color: pal.faint))),
                                  SizedBox(
                                      width: 92,
                                      child: Text(_fmtVal(k, after[k]),
                                          style: TextStyle(
                                              fontFamily: kFontMono,
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w600,
                                              color: pal.heading))),
                                ]),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtVal(String key, dynamic v) {
    if (v == null) return '—';
    if (_moneyFields.contains(key)) {
      final d = double.tryParse('$v');
      if (d != null) return money(d);
    }
    final s = '$v';
    return s.length > 18 ? '${s.substring(0, 17)}…' : s;
  }
}
