/// The audio service and its two mute switches, through the container.
///
/// `AudioAlerts.instance` is the app's only true singleton, and the UI used
/// to mirror its `_muted` / `_opsMuted` flags into widget setState fields
/// (kitchen board, alerts banner) — a global mutable read on every build
/// and a manual sync on every toggle. Here the notifier is the reactive
/// source of truth for the *switch*: it persists to prefs (same keys) and
/// keeps the service's internal gate in step so `play()`/`playOps()`
/// behave exactly as before. Widgets watch the provider instead of
/// mirroring anything.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/audio_alerts.dart';

/// The process-wide audio service. `load()` is idempotent; the players are
/// process-lifetime (the singleton is never disposed by design — the next
/// alert must not pay a cold start).
final audioAlertsProvider = Provider<AudioAlerts>((ref) {
  final a = AudioAlerts.instance;
  a.load();
  return a;
});

const _kitchenMuteKey = 'fufut.pos.kitchenAudioMuted';
const _opsMuteKey = 'fufut.pos.opsAlertsMuted';

/// Kitchen board mute — the gate in front of [AudioAlerts.play].
class KitchenMutedNotifier extends Notifier<bool> {
  @override
  bool build() {
    _restore();
    return false;
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      state = prefs.getBool(_kitchenMuteKey) ?? false;
    } catch (_) {
      // Unreadable prefs: stay unmuted.
    }
  }

  void set(bool m) {
    state = m;
    // Keep the service's own gate in step — play() reads it.
    AudioAlerts.instance.setMuted(m);
  }
}

final kitchenMutedProvider =
    NotifierProvider<KitchenMutedNotifier, bool>(KitchenMutedNotifier.new);

/// Ops-alerts banner mute — the gate in front of [AudioAlerts.playOps].
/// Independent of [kitchenMutedProvider]: muting the kitchen must not
/// silence "your table's food is up".
class OpsMutedNotifier extends Notifier<bool> {
  @override
  bool build() {
    _restore();
    return false;
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      state = prefs.getBool(_opsMuteKey) ?? false;
    } catch (_) {
      // Unreadable prefs: stay unmuted.
    }
  }

  void set(bool m) {
    state = m;
    AudioAlerts.instance.setOpsMuted(m);
  }
}

final opsMutedProvider =
    NotifierProvider<OpsMutedNotifier, bool>(OpsMutedNotifier.new);
