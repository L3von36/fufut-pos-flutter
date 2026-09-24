/// Audit log — the web `AuditLogView.vue`: the read-only system trail with
/// entity/action/actor/date filters. Manager only (the grant). Max 500 rows
/// per pull — the "narrow the range" note is the same on both.
///
/// Tier-2: the fetch lives in a screen-scoped FutureProvider keyed by the
/// filter record; the session is READ inside the provider, never watched
/// (the fetch must not rebuild on its own session echo).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/backoffice.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

const kAuditEntities = [
  'orders', 'menu', 'tables', 'inventory', 'waste', 'purchases', 'suppliers',
  'expenses', 'payments', 'cashdrawer', 'reservations', 'delivery', 'staff',
  'timeclock', 'recipes', 'alerts', 'customers', 'shifts',
];

const kAuditActions = [
  'create', 'update', 'delete', 'adjust', 'status', 'login', 'logout',
  'void', 'verify', 'open', 'close', 'pay', 'count', 'accept', 'release',
];

/// The filter exactly as it reaches the server — the record is the
/// provider key, so any chip/date/actor change is a new fetch.
typedef AuditFilter = ({
  String entity,
  String action,
  String actor,
  String from,
  String to,
});

final auditLogProvider =
    FutureProvider.family<List<AuditEntry>, AuditFilter>((ref, f) async {
  final app = ref.read(appStateProvider);
  try {
    return await app.api.auditFiltered(
      entity: f.entity == 'All' ? null : f.entity,
      action: f.action == 'All' ? null : f.action,
      actorId: f.actor.isEmpty ? null : f.actor,
      from: '${f.from}T00:00:00',
      to: '${f.to}T23:59:59',
      limit: 500,
    );
  } on ApiError catch (e) {
    if (e.isAuthError) await app.sessionExpired();
    rethrow;
  }
});

class AuditLogScreen extends ConsumerStatefulWidget {
  const AuditLogScreen({super.key});

  @override
  ConsumerState<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends ConsumerState<AuditLogScreen> {
  String _entity = 'All';
  String _action = 'All';
  final _actorC = TextEditingController();
  String _from = '';
  String _to = '';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateRangeRow.fmt(now.add(const Duration(days: -7)));
    _to = DateRangeRow.fmt(now);
  }

  @override
  void dispose() {
    _actorC.dispose();
    super.dispose();
  }

  AuditFilter get _filter => (
        entity: _entity,
        action: _action,
        actor: _actorC.text.trim(),
        from: _from,
        to: _to,
      );

  /// Re-key the watch to the current filter values, then invalidate: a new
  /// combination fetches via the key change, an unchanged one via the
  /// invalidate — and the rebuild applies a freshly typed actor id, like
  /// the old _load() read it on every pull.
  void _reload() {
    setState(() {});
    ref.invalidate(auditLogProvider(_filter));
  }

  Color _actionColor(Pal pal, String action) {
    switch (action.toLowerCase()) {
      case 'delete':
      case 'void':
        return pal.danger;
      case 'create':
      case 'open':
        return pal.success;
      case 'adjust':
      case 'update':
        return pal.info;
      default:
        return pal.muted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final rowsAsync = ref.watch(auditLogProvider(_filter));
    final rows = rowsAsync.value ?? const <AuditEntry>[];
    if (rowsAsync.isLoading && rows.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rowsAsync.hasError && rows.isEmpty) {
      return LoadError(error: rowsAsync.error!, onRetry: _reload);
    }
    final pal = Pal.of(context);

    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: KpiCard(
                  label: 'Entries in range',
                  value: rows.length >= 500 ? '500 (max)' : '${rows.length}',
                  icon: Icons.receipt_long_outlined,
                  sub: rows.length >= 500 ? 'Narrow the range for more' : null),
            ),
          ]),
          const SizedBox(height: 10),
          SearchField(
              controller: _actorC,
              hint: 'Actor id…',
              onChanged: (_) {}),
          const SizedBox(height: 8),
          ChipSelect(
            value: _entity,
            options: [('All', 'All entities'),
              ...kAuditEntities.map((e) => (e, e))],
            onChanged: (v) { _entity = v; _reload(); },
          ),
          const SizedBox(height: 8),
          ChipSelect(
            value: _action,
            options: [('All', 'All actions'),
              ...kAuditActions.map((a) => (a, a))],
            onChanged: (v) { _action = v; _reload(); },
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: DateRangeRow(
                  from: _from, to: _to,
                  onFrom: (v) { _from = v; _reload(); },
                  onTo: (v) { _to = v; _reload(); }),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.filter_alt_outlined, size: 15),
              label: const Text('Apply'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 34)),
            ),
          ]),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Trail',
            children: [
              for (final e in rows.take(300))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                '${e.actorName.isEmpty ? 'System' : e.actorName}'
                                '${e.entityId.isNotEmpty ? ' · ${e.entity} #${shortId(e.entityId)}' : ' · ${e.entity}'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: pal.heading)),
                            const SizedBox(height: 1),
                            Text(
                                '${e.at} · ${e.reason.isEmpty ? 'no reason given' : e.reason}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 10.5, color: pal.faint)),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: _actionColor(pal, e.action)
                              .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(e.action.toUpperCase(),
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w800,
                                color: _actionColor(pal, e.action))),
                      ),
                    ],
                  ),
                ),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                      child: Text('No audit entries in this filter',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 11.5, color: pal.faint))),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
