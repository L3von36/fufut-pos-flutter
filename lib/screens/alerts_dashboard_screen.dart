/// SLA Alerts dashboard — the web `AlertsDashboardView.vue`: what the rules
/// engine watches (the 9-rule grid), open / acknowledged / resolved-today
/// lists, per-alert ack + acknowledge-all. Data lives in the shared ops
/// alerts feed (one SSE channel + 60s safety poll for banner AND dashboard).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../state/live_feeds.dart';
import '../state/session_providers.dart';
import '../theme.dart';
import '../widgets/alerts_banner.dart' show kAlertAckRoles;
import '../widgets/backoffice.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

class AlertsDashboardScreen extends ConsumerStatefulWidget {
  const AlertsDashboardScreen({super.key});

  @override
  ConsumerState<AlertsDashboardScreen> createState() => _AlertsDashboardScreenState();
}

class _AlertsDashboardScreenState extends ConsumerState<AlertsDashboardScreen> {
  /// build() watches the shared feed — these read the same snapshot.
  List<OpsAlert> get _open => ref.read(opsAlertsFeedProvider).open;
  List<OpsAlert> get _acked => ref.read(opsAlertsFeedProvider).acknowledged;
  List<OpsAlert> get _resolved => ref.read(opsAlertsFeedProvider).resolved;

  Future<void> _reload() =>
      ref.read(opsAlertsFeedProvider.notifier).refresh(quiet: false);

  Future<void> _ack(OpsAlert a) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(opsAlertsFeedProvider.notifier).ack(a);
      showInfoOn(messenger, 'Acknowledged');
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Future<void> _ackAll() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(opsAlertsFeedProvider.notifier).ackAll();
      showInfoOn(messenger, 'All open alerts acknowledged');
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  List<AlertRuleMeta> get _rules => [
        for (final r in kAlertRules)
          AlertRuleMeta(
            ruleId: r['ruleId']!,
            name: r['name']!,
            watches: r['watches']!,
            threshold: r['threshold']!,
            open: _open.where((a) => a.ruleId == r['ruleId']).toList(),
          ),
      ];

  Color _severityColor(Pal pal, String s) =>
      s == 'critical' ? pal.danger : pal.warning;

  bool get _canAck => kAlertAckRoles.contains(ref.watch(roleProvider));
  bool get _canAckAll => ref.watch(roleProvider) == 'manager';

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(opsAlertsFeedProvider);
    if (feed.loading && feed.open.isEmpty && feed.acknowledged.isEmpty && feed.resolved.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (feed.error != null && feed.open.isEmpty) {
      return LoadError(error: feed.error!, onRetry: () => _reload());
    }
    final pal = Pal.of(context);
    final rules = _rules;
    final criticals = _open.where((a) => a.severity == 'critical').length;
    final today = DateTime.now();
    final todayKey = '${today.year.toString().padLeft(4, '0')}-'
        '${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final resolvedToday =
        _resolved.where((a) => a.created.startsWith(todayKey)).length;

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: KpiCard(label: 'Open',
                    value: '${_open.length}',
                    valueColor: _open.isNotEmpty ? pal.warning : pal.success,
                    icon: Icons.notifications_active_outlined)),
            const SizedBox(width: 8),
            Expanded(
                child: KpiCard(label: 'Critical',
                    value: '$criticals',
                    valueColor: criticals > 0 ? pal.danger : pal.success,
                    icon: Icons.priority_high_outlined)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: KpiCard(label: 'Acknowledged',
                    value: '${_acked.length}', icon: Icons.visibility_outlined)),
            const SizedBox(width: 8),
            Expanded(
                child: KpiCard(label: 'Resolved today',
                    value: '$resolvedToday',
                    valueColor: pal.success,
                    icon: Icons.check_circle_outline)),
          ]),
          const SizedBox(height: 12),
          if (_canAck && _open.isNotEmpty)
            SizedBox(
              height: 34,
              child: OutlinedButton.icon(
                onPressed: _canAckAll ? _ackAll : null,
                icon: const Icon(Icons.done_all, size: 16),
                label: Text(_canAckAll
                    ? 'Acknowledge all (${_open.length})'
                    : 'Acknowledge all — manager only'),
              ),
            ),
          if (_canAck && _open.isNotEmpty) const SizedBox(height: 12),
          SectionCard(
            title: 'Open',
            trailing: Text('critical first',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 9.5, color: pal.faint)),
            children: [
              for (final a in _open.take(50))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 3),
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _severityColor(pal, a.severity)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(a.message,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: pal.heading)),
                            const SizedBox(height: 1),
                            Text(
                                '${a.entityLabel} · ${a.created.length >= 16 ? a.created.substring(11, 16) : a.created} · ${a.ruleId}',
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 10.5, color: pal.faint)),
                          ],
                        ),
                      ),
                      if (_canAck)
                        AsyncRowAction('Ack', () => _ack(a), color: pal.primary),
                    ],
                  ),
                ),
              if (_open.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                      child: Text('Nothing open — the pass is clean',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 11.5, color: pal.success))),
                ),
            ],
          ),
          const SizedBox(height: 10),
          SectionCard(
            title: 'What the sweep watches',
            children: [
              for (final r in rules)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(r.name,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: pal.heading)),
                            Text('${r.watches} · ${r.threshold}',
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
                          color: r.open.isEmpty
                              ? pal.successBg
                              : _severityColor(pal, r.open.first.severity)
                                  .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                            r.open.isEmpty
                                ? 'CLEAR'
                                : r.open.first.severity == 'critical'
                                    ? 'CRITICAL ${r.open.length}'
                                    : 'WARN ${r.open.length}',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w800,
                                color: r.open.isEmpty
                                    ? pal.success
                                    : _severityColor(
                                        pal, r.open.first.severity))),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (_acked.isNotEmpty)
            SectionCard(
              title: 'Acknowledged',
              children: [
                for (final a in _acked.take(25))
                  ListRow(
                      head: a.message,
                      rest: a.created,
                      trailing: a.severity),
              ],
            ),
        ],
      ),
    );
  }
}
