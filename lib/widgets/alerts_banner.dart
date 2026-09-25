/// Operations alerts banner — the web POS `AlertsBanner.vue`, native.
///
/// The cron sweep writes SLA breaches to `/api/alerts`; this banner is how
/// the floor finds out. It mounts in the home shell ABOVE every tab (the
/// web mounts it in AppLayout above the content wrap), so a breach follows
/// the user from the floor to the till without re-mounting.
///
/// **Live via the shared ops alerts feed** — one `alerts` SSE channel (plus
/// the 60s always-on poll) lives in `state/live_feeds.dart`, shared with
/// the alerts dashboard. An `alerts_update` payload `{alerts:[...]}` or the
/// poll refreshes the watched list within seconds of the minute tick, and
/// the sounds ride the snapshot (critical breaches, and the
/// `order-ready-now` ping — "food on the pass for YOUR table" — aimed at
/// the waiter). The web ships the same always-on poll here — unlike the
/// kitchen board, a missed alert has no other screen to catch it.
///
/// **Roles** mirror the server exactly: read is wide (every floor role
/// except cleaner), per-alert Ack is manager / head-chef / head-waiter /
/// cashier, Ack-all is manager only. A role without the resource renders
/// nothing and never connects — the cleaner's tablet never asked for the
/// kitchen's clock.
///
/// **Quota notice** — the circuit breaker's human voice: the same
/// conserve/emergency/critical ladder text the web shows, driven by the
/// feed's quota mode (hello + `quota_mode` transitions).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../services/alerts_live.dart';
import '../services/audio_alerts.dart';
import '../state/app_state.dart';
import '../state/app_time.dart' show fmtClockStamp;
import '../state/audio_providers.dart';
import '../state/live_feeds.dart';
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

class OpsAlertsBanner extends ConsumerStatefulWidget {
  const OpsAlertsBanner({super.key});

  @override
  ConsumerState<OpsAlertsBanner> createState() => _OpsAlertsBannerState();
}

class _OpsAlertsBannerState extends ConsumerState<OpsAlertsBanner> {
  bool _expanded = false;
  String? _acking;

  final AlertsLive _live = AlertsLive();

  /// The open list the sound engine last saw — a new snapshot (push or
  /// poll) re-baselines the dedup sets; a mere connected/quota flip does
  /// not re-run sounds.
  List<OpsAlert>? _lastSynced;

  bool _canRead = false;
  bool _canAck = false;
  bool _canAckAll = false;

  @override
  void initState() {
    super.initState();
    final app = ref.read(appStateProvider);
    final role = app.roleKey ?? '';
    _canRead = kAlertReadRoles.contains(role);
    _canAck = kAlertAckRoles.contains(role);
    _canAckAll = kAlertAckAllRoles.contains(role);
  }

  /// Sound sync on every snapshot the banner sees. The mute gate is the
  /// [opsMutedProvider] switch, kept in step with the service by the
  /// notifier; [AlertsLive] decides WHAT deserves a tone.
  void _syncSound(List<OpsAlert> list) {
    final sync = _live.apply(list);
    if (ref.read(opsMutedProvider)) return;
    final audio = ref.read(audioAlertsProvider);
    if (sync.freshCriticals > 0) {
      audio.playOps(AlertSound.critical);
    }
    if (sync.freshPing) {
      // The warm order-ready chime — the same one the kitchen hears when a
      // ticket goes ready, here telling the waiter their table's food is up.
      audio.playOps(AlertSound.orderReady);
    }
  }

  void _toggleMute() {
    final m = ref.read(opsMutedProvider);
    ref.read(opsMutedProvider.notifier).set(!m);
  }

  Future<void> _ack(OpsAlert a) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _acking = a.id);
    try {
      await ref.read(opsAlertsFeedProvider.notifier).ack(a);
      if (!mounted) return;
      showInfoOn(messenger, 'Alert acknowledged');
    } catch (e) {
      showErrorOn(messenger, e);
    } finally {
      if (mounted) setState(() => _acking = null);
    }
  }

  Future<void> _ackAll() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(opsAlertsFeedProvider.notifier).ackAll();
      if (!mounted) return;
      showInfoOn(messenger, 'All alerts acknowledged');
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_canRead) return const SizedBox.shrink();
    final feed = ref.watch(opsAlertsFeedProvider);
    final muted = ref.watch(opsMutedProvider);
    final alerts = feed.open;
    if (!identical(_lastSynced, alerts)) {
      _lastSynced = alerts;
      _syncSound(alerts);
    }
    final quotaMode = feed.quotaMode;
    final pal = Pal.of(context);

    // The circuit breaker's human voice, web text verbatim.
    final quotaNotice = switch (quotaMode) {
      'conserve' || 'emergency' =>
        'Live updates slowed to conserve quota — boards refresh less often',
      'critical' =>
        'Live updates paused to protect the database quota — boards show the last known state; orders and payments still work',
      _ => null,
    };

    if (alerts.isEmpty && quotaNotice == null) return const SizedBox.shrink();

    final criticalCount = alerts.where((a) => a.severity == 'critical').length;
    final hasCritical = criticalCount > 0;
    final sorted = [...alerts]..sort(OpsAlert.rank);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (quotaNotice != null) _QuotaNotice(text: quotaNotice, critical: quotaMode == 'critical'),
          if (alerts.isNotEmpty)
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
                              '${alerts.length} operation${alerts.length == 1 ? '' : 's'} need${alerts.length == 1 ? 's' : ''} attention',
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
                                muted
                                    ? Icons.volume_off_outlined
                                    : Icons.volume_up_outlined,
                                size: 15,
                                color: muted ? pal.faint : pal.muted,
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
                        if (_canAckAll && alerts.length > 1) ...[
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

  String _shortTime(String stamp) => fmtClockStamp(stamp);
}
