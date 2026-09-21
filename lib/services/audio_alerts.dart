/// Kitchen audio alerts — the web `useAudioAlerts.js`, native.
///
/// The web synthesizes tones with Web Audio oscillators; a native app can't
/// do that without audio DSP, so the same four tones ship as tiny WAV
/// assets (assets/audio/, synthesized to match: 440→660 ding, 330+440 chime,
/// 660/880/1100 triple beep). Mute persists per device, like the web's
/// localStorage flags.
library;

import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AlertSound { newOrder, orderReady, critical }

class AudioAlerts {
  AudioAlerts._();
  static final AudioAlerts instance = AudioAlerts._();

  static const _muteKey = 'fufut.pos.kitchenAudioMuted';
  final Map<AlertSound, AudioPlayer> _players = {};
  bool _muted = false;
  bool _loaded = false;

  bool get muted => _muted;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _muted = prefs.getBool(_muteKey) ?? false;
    } catch (_) {
      _muted = false;
    }
  }

  Future<void> setMuted(bool m) async {
    _muted = m;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_muteKey, m);
    } catch (_) {}
  }

  Future<void> play(AlertSound sound) async {
    if (_muted) return;
    try {
      final player =
          _players.putIfAbsent(sound, () => AudioPlayer(playerId: 'alert-${sound.name}'));
      await player.stop();
      await player.setReleaseMode(ReleaseMode.stop);
      await player.play(AssetSource(_assetOf(sound)));
    } catch (_) {
      // A missing codec or muted device must never take the board down.
    }
  }

  String _assetOf(AlertSound s) {
    switch (s) {
      case AlertSound.newOrder:
        return 'audio/new_order.wav';
      case AlertSound.orderReady:
        return 'audio/order_ready.wav';
      case AlertSound.critical:
        return 'audio/critical.wav';
    }
  }

  Future<void> dispose() async {
    for (final p in _players.values) {
      await p.dispose();
    }
    _players.clear();
  }
}
