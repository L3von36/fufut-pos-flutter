/// SSE channel — the Flutter port of the web POS `useSSE.js` composable.
///
/// One [SseChannel] per screen, mirroring the web's "one EventSource per
/// screen" rule. It owns:
///  * the named-event connection to `/api/events/{channel}` — the fufut-api
///    channels (`kitchen`, …) speak four data events plus the two control
///    events the channel itself interprets;
///  * reconnection with exponential backoff (1s doubling to a 30s cap,
///    reset on every successful open — same ladder as the web);
///  * the quota circuit-breaker mode the server announces on `connected`
///    and on every `quota_mode` transition, exposed for screens that want
///    to explain why live updates slowed;
///  * [suspend]/[resume] for app lifecycle (the web pauses on
///    `visibilitychange` — a backgrounded tablet must not pin a Worker
///    connection it cannot read).
///
/// Screens consume the broadcast [stream] and keep their own refresh path —
/// live updates are an enhancement, never a prerequisite (the web's own
/// rule: if EventSource is missing the page still works, just polled).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'sse_parser.dart' show SseEvent;
import 'sse_transport.dart';

/// Re-exported for consumers: screens receive [SseEvent]s from [SseChannel.stream].
export 'sse_parser.dart' show SseEvent;

/// Every named event fufut-api emits on its channels (handlers/sse.js).
/// The web transport needs the full list up front; the IO transport simply
/// passes through whatever arrives.
const kSseEventNames = <String>{
  'connected',
  'new_order',
  'order_update',
  'table_update',
  'alerts_update',
  'quota_mode',
};

class SseChannel {
  final String channel;

  /// Base URL without trailing slash ('' on web = same origin, matching the
  /// web POS's getSSEUrl()).
  final String baseUrl;

  /// The `session` cookie token. Unused on web (the browser attaches the
  /// cookie itself); required on native.
  final String? sessionToken;

  final ValueNotifier<bool> connected = ValueNotifier<bool>(false);

  /// 'normal' | 'conserve' | 'emergency' | 'critical' — the API's
  /// degradation ladder, stated on `connected` and updated on `quota_mode`.
  final ValueNotifier<String> quotaMode = ValueNotifier<String>('normal');

  final StreamController<SseEvent> _events =
      StreamController<SseEvent>.broadcast();

  SseTransport? _transport;
  Timer? _retry;
  int _attempt = 0;
  bool _manualClose = false;
  bool _suspended = false;
  bool _disposed = false;

  static const _initialDelay = Duration(seconds: 1);
  static const _maxDelay = Duration(seconds: 30);

  SseChannel({
    required this.baseUrl,
    required this.channel,
    this.sessionToken,
  });

  /// Every named event the server sends on this channel.
  Stream<SseEvent> get stream => _events.stream;

  void connect() {
    if (_disposed) return;
    _manualClose = false;
    _suspended = false;
    _open();
  }

  /// Close for good (screen disposed, logout). No reconnect fires after
  /// this; the channel cannot be reused.
  void disconnect() {
    if (_disposed) return;
    _disposed = true;
    _manualClose = true;
    _retry?.cancel();
    _retry = null;
    _closeTransport();
    connected.value = false;
    _events.close();
  }

  /// Pause without losing retry state (app went to background).
  void suspend() {
    if (_disposed || _manualClose || _suspended) return;
    _suspended = true;
    _retry?.cancel();
    _retry = null;
    _closeTransport();
    connected.value = false;
  }

  /// Resume after [suspend] (app foregrounded) — reconnect immediately,
  /// like the web's visibilitychange handler.
  void resume() {
    if (_disposed || _manualClose || !_suspended) return;
    _suspended = false;
    _attempt = 0; // foreground is a fresh start, not a failure streak
    _open();
  }

  void _open() {
    if (_disposed || _manualClose || _suspended) return;
    _closeTransport();

    // Same-origin on web ('' base), Worker URL on native — the web POS's
    // getSSEUrl() logic.
    final path = '/api/events/$channel';
    final url = baseUrl.isEmpty ? Uri.parse(path) : Uri.parse('$baseUrl$path');

    final headers = <String, String>{
      if (!kIsWeb && sessionToken != null) 'Cookie': 'session=$sessionToken',
    };

    try {
      _transport = createSseTransport(SseTransportConfig(
        url: url,
        headers: headers,
        eventNames: kSseEventNames,
        onOpen: _onOpen,
        onError: _onError,
        onEvent: _onEvent,
      ));
    } on UnsupportedError {
      // Stub platform (neither web nor io) — retrying is pointless; the
      // poll fallback carries the screen.
      return;
    }
  }

  void _onOpen() {
    if (_disposed) return;
    connected.value = true;
    _attempt = 0;
  }

  void _onError(Object error) {
    if (_disposed || _manualClose || _suspended) return;
    connected.value = false;
    _closeTransport();
    _scheduleRetry();
  }

  void _onEvent(String event, String data) {
    if (_disposed) return;
    // Control events the channel itself interprets (web useSSE parity):
    // the hello carries the current quota mode, transitions arrive later.
    if (event == 'connected' || event == 'quota_mode') {
      final json = SseEvent(event, data).tryDecodeJson();
      final mode = json?['mode'];
      if (mode is String && mode.isNotEmpty) quotaMode.value = mode;
    }
    if (!_events.isClosed) _events.add(SseEvent(event, data));
  }

  void _scheduleRetry() {
    if (_disposed || _manualClose || _suspended) return;
    _retry?.cancel();
    // 1s → 2s → 4s → 8s → 16s → 30s cap, exactly the web's ladder shape.
    final delay = _initialDelay * (1 << _attempt.clamp(0, 5));
    _attempt++;
    _retry = Timer(delay > _maxDelay ? _maxDelay : delay, _open);
  }

  void _closeTransport() {
    _transport?.close();
    _transport = null;
  }
}
