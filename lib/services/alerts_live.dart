/// Alerts sound-sync engine — the web `AlertsBanner.vue` `syncSound()`
/// logic, extracted so it unit-tests without a widget.
///
/// The server push (`alerts_update`) and the 60s poll both carry the full
/// open-alerts list; this engine decides what deserves a sound:
///
///  * **Critical breaches** — a warning is the banner's job, a critical is
///    the room's. One critical tone per batch of NEW criticals (the sweep
///    can raise five at once on a cold start; five sirens is noise, not
///    signal). Every critical id is remembered so it fires exactly once
///    per lifetime of the banner — the web's `soundedCritical` set.
///  * **`order-ready-now` pings** — the one warning with its own sound:
///    the warm order-ready chime ("food on the pass for YOUR table"). The
///    FIRST snapshot after opening the banner is a baseline, not a
///    transition — an existing ping was raised before this tablet opened,
///    and replaying it now tells the waiter about food that was already
///    picked up (or already ignored). Only pings that ARRIVE after that
///    first load chime (`soundsArmed` on the web), once per ping id.
///
/// Like [KitchenLive], the sets persist across SSE reconnects: a reconnect
/// re-sends the whole open list and every id is already known.
library;

import '../models/models.dart';

/// What one applied snapshot wants the banner to play.
class AlertsSync {
  /// New critical breaches in this snapshot (play the critical tone).
  final int freshCriticals;

  /// A `order-ready-now` ping arrived after the baseline (play the chime).
  final bool freshPing;

  const AlertsSync({this.freshCriticals = 0, this.freshPing = false});

  bool get hasSound => freshCriticals > 0 || freshPing;
}

class AlertsLive {
  final Set<String> _criticalSounded = {};
  final Set<String> _pingsSounded = {};

  /// Pings are silenced only until the first load — criticals chime from
  /// the very first snapshot, exactly the web's asymmetry.
  bool _armed = false;

  bool get armed => _armed;
  Set<String> get criticalSounded => Set<String>.unmodifiable(_criticalSounded);
  Set<String> get pingsSounded => Set<String>.unmodifiable(_pingsSounded);

  /// Apply a full open-alerts snapshot (push or poll — same shape).
  AlertsSync apply(List<OpsAlert> list) {
    var freshCriticals = 0;
    var freshPing = false;

    for (final a in list) {
      if (a.severity == 'critical' && _criticalSounded.add(a.id)) {
        freshCriticals++;
      }
      if (a.ruleId != 'order-ready-now') continue;
      if (_armed && !_pingsSounded.contains(a.id)) freshPing = true;
      _pingsSounded.add(a.id);
    }

    _armed = true;
    return AlertsSync(freshCriticals: freshCriticals, freshPing: freshPing);
  }

  /// Forget everything — the next snapshot re-baselines (logout, account
  /// switch). The banner lives for the whole session, so this is mostly a
  /// test affordance.
  void reset() {
    _criticalSounded.clear();
    _pingsSounded.clear();
    _armed = false;
  }
}
