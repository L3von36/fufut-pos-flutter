/// SLA Alerts dashboard — the web `AlertsDashboardView.vue`: what the rules
/// engine watches (the 9-rule grid), open / acknowledged / resolved-today
/// lists, per-alert ack + acknowledge-all, 60s poll + SSE alerts channel.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../api/sse/sse_channel.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/roles.dart';
import '../theme.dart';
import '../widgets/alerts_banner.dart' show kAlertAckRoles;
import '../widgets/backoffice.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

class AlertsDashboardScreen extends StatefulWidget {
  final ValueNotifier<NavKey>? activeTab;
  final NavKey? self;

  const AlertsDashboardScreen({super.key, this.activeTab, this.self});

  @override
  State<AlertsDashboardScreen> createState() => _AlertsDashboardScreenState();
}

class _AlertsDashboardScreenState extends State<AlertsDashboardScreen> {
  List<OpsAlert> _open = [];
  List<OpsAlert> _acked = [];
  List<OpsAlert> _resolved = [];
  bool _loading = true;
  Object? _error;
  SseChannel? _channel;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _connect();
    _poll = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) _load(quiet: true);
    });
    widget.activeTab?.addListener(_lifecycle);
  }

  @override
  void dispose() {
    widget.activeTab?.removeListener(_lifecycle);
    _channel?.suspend();
    _poll?.cancel();
    super.dispose();
  }

  void _lifecycle() {
    final onStage = widget.activeTab?.value == widget.self;
    if (onStage) {
      _channel?.resume();
      _load(quiet: true);
    } else {
      _channel?.suspend();
    }
  }

  void _connect() {
    final app = context.read<AppState>();
    final ch = SseChannel(
        baseUrl: app.baseUrl,
        channel: 'alerts',
        sessionToken: app.client.sessionToken,
      );
    ch.stream.listen((evt) {
      if (!mounted) return;
      if (evt.event == 'alerts_update') _load(quiet: true);
    });
    _channel = ch;
    ch.connect();
  }

  String get _role => context.read<AppState>().roleKey ?? '';
  bool get _canAck => kAlertAckRoles.contains(_role);
  bool get _canAckAll => _role == 'manager';

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait<dynamic>([
        app.api.alertsByStatus('open', limit: 200),
        app.api.alertsByStatus('acknowledged', limit: 25),
        app.api.alertsByStatus('resolved', limit: 100),
      ]);
      final open = results[0] as List<OpsAlert>;
      final acked = results[1] as List<OpsAlert>;
      final resolved = results[2] as List<OpsAlert>;
      if (!mounted) return;
      setState(() {
        _open = open..sort(OpsAlert.rank);
        _acked = acked;
        _resolved = resolved;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) { await app.sessionExpired(); return; }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  Future<void> _ack(OpsAlert a) async {
    final messenger = ScaffoldMessenger.of(context);
    final app = context.read<AppState>();
    try {
      await app.api.acknowledgeAlert(a.id);
      showInfoOn(messenger, 'Acknowledged');
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Future<void> _ackAll() async {
    final messenger = ScaffoldMessenger.of(context);
    final app = context.read<AppState>();
    try {
      await app.api.acknowledgeAllAlerts();
      showInfoOn(messenger, 'All open alerts acknowledged');
      await _load(quiet: true);
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

  @override
  Widget build(BuildContext context) {
    if (_loading && _open.isEmpty && _acked.isEmpty && _resolved.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _open.isEmpty) {
      return LoadError(error: _error!, onRetry: () => _load());
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
      onRefresh: () => _load(quiet: true),
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
                        RowAction('Ack', () => _ack(a), color: pal.primary),
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
