/// Audit log — the web `AuditLogView.vue`: the read-only system trail with
/// entity/action/actor/date filters. Manager only (the grant). Max 500 rows
/// per pull — the "narrow the range" note is the same on both.
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

class AuditLogScreen extends ConsumerStatefulWidget {
  const AuditLogScreen({super.key});

  @override
  ConsumerState<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends ConsumerState<AuditLogScreen> {
  List<AuditEntry> _rows = [];
  bool _loading = true;
  Object? _error;
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
    _load();
  }

  @override
  void dispose() {
    _actorC.dispose();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final app = ref.read(appStateProvider);
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final rows = await app.api.auditFiltered(
        entity: _entity == 'All' ? null : _entity,
        action: _action == 'All' ? null : _action,
        actorId: _actorC.text.trim().isEmpty ? null : _actorC.text.trim(),
        from: '${_from}T00:00:00',
        to: '${_to}T23:59:59',
        limit: 500,
      );
      if (!mounted) return;
      setState(() { _rows = rows; _loading = false; });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) { await app.sessionExpired(); return; }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
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
    if (_loading && _rows.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _rows.isEmpty) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final pal = Pal.of(context);

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: KpiCard(
                  label: 'Entries in range',
                  value: _rows.length >= 500 ? '500 (max)' : '${_rows.length}',
                  icon: Icons.receipt_long_outlined,
                  sub: _rows.length >= 500 ? 'Narrow the range for more' : null),
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
            onChanged: (v) { _entity = v; _load(); },
          ),
          const SizedBox(height: 8),
          ChipSelect(
            value: _action,
            options: [('All', 'All actions'),
              ...kAuditActions.map((a) => (a, a))],
            onChanged: (v) { _action = v; _load(); },
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: DateRangeRow(
                  from: _from, to: _to,
                  onFrom: (v) { _from = v; _load(); },
                  onTo: (v) { _to = v; _load(); }),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: () => _load(),
              icon: const Icon(Icons.filter_alt_outlined, size: 15),
              label: const Text('Apply'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 34)),
            ),
          ]),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Trail',
            children: [
              for (final e in _rows.take(300))
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
              if (_rows.isEmpty)
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
