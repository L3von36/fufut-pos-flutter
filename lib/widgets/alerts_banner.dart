/// Operations alerts banner — the web POS `AlertsBanner.vue`, native.
///
/// The cron sweep writes SLA breaches to `/api/alerts`; this banner is how
/// the floor finds out. It mounts in the home shell ABOVE every tab (the
/// web mounts it in AppLayout above the content wrap), so a breach follows
/// the user from the floor to the till without re-mounting.
///
/// **Live via SSE** — it rides the fufut-api `alerts` channel: an
/// `alerts_update` payload `{alerts:[...]}` replaces the list within
/// seconds of the minute tick, and the sounds ride the push (critical
/// breaches, and the `order-ready-now` ping — "food on the pass for YOUR
/// table" — aimed at the waiter). A 60s poll survives unconditionally for
/// tablets where EventSource quietly dies (the web ships the same
/// always-on poll here — unlike the kitchen board, a missed alert has no
/// other screen to catch it).
///
/// **Roles** mirror the server exactly: read is wide (every floor role
/// except cleaner), per-alert Ack is manager / head-chef / head-waiter /
/// cashier, Ack-all is manager only. A role without the resource renders
/// nothing and never connects — the cleaner's tablet never asked for the
/// kitchen's clock.
///
/// **Quota notice** — the circuit breaker's human voice: the same
/// conserve/emergency/critical ladder text the web shows, driven by the
/// channel's quota mode (hello + `quota_mode` transitions).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../api/sse/sse_channel.dart';
import '../models/models.dart';
import '../services/alerts_live.dart';
import '../services/audio_alerts.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Roles the server grants alerts read to. The server gates the endpoint;
/// this list only decides whether the banner exists at all, so a refused
/// fetch never even happens for the roles that must not see it.
const Set<String> kAlertReadRoles = {
  'manager',
  'head-chef',
  'assistant-chef',
  'head-waiter',
  'cashier',
  'delivery-staff',
  'barista',
};

/// Per-alert Ack: manager, head-chef, head-waiter, cashier — each can act
/// on a single alert relevant to them.
const Set<String> kAlertAckRoles = {
  'manager',
  'head-chef',
  'head-waiter',
  'cashier',
};

/// Bulk Ack-all is manager-only: the server's acknowledge-all refuses every
/// other role, so the button does not render for them (without this guard
/// the web shipped a 403 toast factory).
const Set<String> kAlertAckAllRoles = {'manager'};

class OpsAlertsBanner extends StatefulWidget {
  const OpsAlertsBanner({super.key});

  @override
  State<OpsAlertsBanner> createState() => _OpsAlertsBannerState();
}

class _OpsAlertsBannerState extends State<OpsAlertsBanner>
    with WidgetsBindingObserver {
  List<OpsAlert> _alerts = [];
  bool _expanded = false;
  String? _acking;
  String? _quotaMode;
  bool _lifecycleUp = true;

  final AlertsLive _live = AlertsLive();
  SseChannel? _sse;
  StreamSubscription<SseEvent>? _sseSub;
  Timer? _poll;

  AppState? _app;
  bool _muted = false;

  bool _canRead = false;
  bool _canAck = false;
  bool _canAckAll = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _app = context.read<AppState>();
    final role = _app?.roleKey ?? '';
    _canRead = kAlertReadRoles.contains(role);
    _canAck = kAlertAckRoles.contains(role);
    _canAckAll = kAlertAckAllRoles.contains(role);
    _loadMute();
    if (_canRead) {
      _load();
      // Always-on poll (web parity): the banner is the only thing watching
      // for breaches, so it keeps its 60s net even while the stream is up.
      _poll = Timer.periodic(const Duration(seconds: 60), (_) => _load(quiet: true));
      _connectSse();
    }
  }

  Future<void> _loadMute() async {
    await AudioAlerts.instance.load();
    if (mounted) setState(() => _muted = AudioAlerts.instance.opsMuted);
  }

  Future<void> _load({bool quiet = true}) async {
    final app = _app;
    if (app == null) return;
    try {
      final list = await app.api.alerts();
      if (!mounted) return;
      setState(() => _alerts = list);
      _syncSound(list);
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) {
        await app.sessionExpired();
        return;
      }
      // Refused or offline: silence, not an error banner on an error banner.
      if (!quiet && _alerts.isEmpty) setState(() => _alerts = []);
    } catch (_) {
      if (!mounted) return;
      if (!quiet && _alerts.isEmpty) setState(() => _alerts = []);
    }
  }

  void _syncSound(List<OpsAlert> list) {
    final sync = _live.apply(list);
    if (_muted) return;
    if (sync.freshCriticals > 0) {
      AudioAlerts.instance.playOps(AlertSound.critical);
    }
    if (sync.freshPing) {
      // The warm order-ready chime — the same one the kitchen hears when a
      // ticket goes ready, here telling the waiter their table's food is up.
      AudioAlerts.instance.playOps(AlertSound.orderReady);
    }
  }

  void _connectSse() {
    final app = _app;
    if (app == null) return;
    _sseSub?.cancel();
    _sse?.disconnect();
    final sse = SseChannel(
      baseUrl: app.baseUrl,
      channel: 'alerts',
      sessionToken: app.client.sessionToken,
    );
    _sse = sse;
    _sseSub = sse.stream.listen(_onSseEvent);
    sse.connected.addListener(_onConnectedChanged);
    sse.connect();
  }

  void _onConnectedChanged() {
    if (!mounted) return;
    final mode = _sse?.quotaMode.value;
    if (mode != null && mode != _quotaMode) setState(() => _quotaMode = mode);
  }

  void _onSseEvent(SseEvent event) {
    if (!mounted) return;
    if (event.event != 'alerts_update') return;

    final data = event.tryDecodeJson();
    final raw = data?['alerts'];
    if (raw is! List) {
      // Payload shape unexpected — fetch instead of showing a stale list.
      _load(quiet: true);
      return;
    }

    // Parse defensively: one malformed row must never take down the banner.
    final fresh = <OpsAlert>[];
    for (final row in raw.whereType<Map>()) {
      try {
        fresh.add(OpsAlert.fromJson(Map<String, dynamic>.from(row)));
      } catch (_) {}
    }

    setState(() => _alerts = fresh);
    _syncSound(fresh);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Web visibilitychange parity: a locked tablet must not pin a Worker
    // connection it cannot read. The banner has no tab gate — it is on
    // stage in every tab — so lifecycle is its only gate.
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _lifecycleUp = false;
    } else if (state == AppLifecycleState.resumed) {
      _lifecycleUp = true;
    } else {
      return;
    }
    final sse = _sse;
    if (sse == null) return;
    if (_lifecycleUp) {
      sse.resume();
    } else {
      sse.suspend();
    }
  }

  Future<void> _toggleMute() async {
    final next = !_muted;
    await AudioAlerts.instance.setOpsMuted(next);
    if (mounted) setState(() => _muted = next);
  }

  Future<void> _ack(OpsAlert a) async {
    final app = _app;
    if (app == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _acking = a.id);
    try {
      await app.api.acknowledgeAlert(a.id);
      if (!mounted) return;
      setState(() => _alerts.removeWhere((x) => x.id == a.id));
      showInfoOn(messenger, 'Alert acknowledged');
    } catch (e) {
      showErrorOn(messenger, e);
    } finally {
      if (mounted) setState(() => _acking = null);
    }
  }

  Future<void> _ackAll() async {
    final app = _app;
    if (app == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.acknowledgeAllAlerts();
      if (!mounted) return;
      setState(() => _alerts.clear());
      showInfoOn(messenger, 'All alerts acknowledged');
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _sse?.connected.removeListener(_onConnectedChanged);
    _sseSub?.cancel();
    _sse?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_canRead) return const SizedBox.shrink();
    final pal = Pal.of(context);

    // The circuit breaker's human voice, web text verbatim.
    final quotaNotice = switch (_quotaMode) {
      'conserve' || 'emergency' =>
        'Live updates slowed to conserve quota — boards refresh less often',
      'critical' =>
        'Live updates paused to protect the database quota — boards show the last known state; orders and payments still work',
      _ => null,
    };

    if (_alerts.isEmpty && quotaNotice == null) return const SizedBox.shrink();

    final criticalCount = _alerts.where((a) => a.severity == 'critical').length;
    final hasCritical = criticalCount > 0;
    final sorted = [..._alerts]..sort(OpsAlert.rank);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (quotaNotice != null) _QuotaNotice(text: quotaNotice, critical: _quotaMode == 'critical'),
          if (_alerts.isNotEmpty)
            Material(
              color: pal.surface,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: hasCritical
                          ? pal.danger.withValues(alpha: 0.6)
                          : pal.warning.withValues(alpha: 0.55),
                      width: 1.2,
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          _PulseDot(color: hasCritical ? pal.danger : pal.warning),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              '${_alerts.length} operation${_alerts.length == 1 ? '' : 's'} need${_alerts.length == 1 ? 's' : ''} attention',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontFamily: kFontBody,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: pal.heading),
                            ),
                          ),
                          if (criticalCount > 0) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: pal.danger.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '$criticalCount critical',
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: pal.danger),
                              ),
                            ),
                          ],
                          const SizedBox(width: 6),
                          // Sound toggle — stopPropagation equivalent: the
                          // row tap expands, this button must not.
                          GestureDetector(
                            onTap: _toggleMute,
                            child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: Icon(
                                _muted
                                    ? Icons.volume_off_outlined
                                    : Icons.volume_up_outlined,
                                size: 15,
                                color: _muted ? pal.faint : pal.muted,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _expanded ? 'Hide' : 'Show',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: pal.muted),
                          ),
                        ],
                      ),
                      if (_expanded) ...[
                        const SizedBox(height: 4),
                        Divider(height: 1, thickness: 0.7, color: pal.border),
                        for (final a in sorted)
                          _AlertRow(
                            alert: a,
                            canAck: _canAck,
                            acking: _acking == a.id,
                            onAck: _canAck ? () => _ack(a) : null,
                          ),
                        if (_canAckAll && _alerts.length > 1) ...[
                          const SizedBox(height: 4),
                          SizedBox(
                            height: 28,
                            child: OutlinedButton(
                              onPressed: _ackAll,
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(color: pal.border),
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                              ),
                              child: Text('Acknowledge all',
                                  style: TextStyle(
                                      fontFamily: kFontBody,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: pal.heading)),
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _QuotaNotice extends StatelessWidget {
  final String text;
  final bool critical;
  const _QuotaNotice({required this.text, required this.critical});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: (critical ? pal.danger : pal.warning).withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: (critical ? pal.danger : pal.warning).withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(critical ? Icons.pause_circle_outline : Icons.schedule,
              size: 13, color: critical ? pal.danger : pal.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 11,
                  color: pal.heading,
                  height: 1.25),
            ),
          ),
        ],
      ),
    );
  }
}

/// The breathing dot — a soft pulse in the banner's severity color.
class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
      ),
    );
  }
}

class _AlertRow extends StatelessWidget {
  final OpsAlert alert;
  final bool canAck;
  final bool acking;
  final VoidCallback? onAck;

  const _AlertRow({
    required this.alert,
    required this.canAck,
    required this.acking,
    this.onAck,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final critical = alert.severity == 'critical';
    final c = critical ? pal.danger : pal.warning;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(shape: BoxShape.circle, color: c)),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  alert.message,
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 11.5,
                      color: pal.heading,
                      height: 1.3),
                ),
                const SizedBox(height: 1),
                Text(
                  'Raised ${_shortTime(alert.created)}',
                  style: TextStyle(
                      fontFamily: kFontMono, fontSize: 9.5, color: pal.faint),
                ),
              ],
            ),
          ),
          if (canAck) ...[
            const SizedBox(width: 8),
            SizedBox(
              height: 24,
              child: TextButton(
                onPressed: acking ? null : onAck,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  side: BorderSide(color: pal.border),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                ),
                child: Text(acking ? '…' : 'Ack',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: pal.heading)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _shortTime(String stamp) {
    final t = DateTime.tryParse(stamp);
    if (t == null) return '';
    final local = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }
}
