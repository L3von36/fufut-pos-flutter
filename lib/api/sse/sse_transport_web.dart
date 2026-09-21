/// Web SSE transport: the browser's own `EventSource` (via `package:web`),
/// the exact primitive the PWA's `useSSE.js` uses. Cookies ride along
/// automatically on the same origin — no header surgery possible or needed.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'sse_transport_types.dart';

class WebSseTransport implements SseTransport {
  web.EventSource? _es;
  bool _closed = false;

  WebSseTransport(SseTransportConfig config) {
    final es = web.EventSource(config.url.toString());
    _es = es;

    void fail(Object err) {
      if (_closed) return;
      _closed = true;
      // Kill the browser's native auto-reconnect: our channel owns the
      // retry ladder (uniform with the native transport) and two reconnect
      // loops would double-connect after every drop.
      es.close();
      config.onError(err);
    }

    es.addEventListener(
        'open',
        ((web.Event _) {
          if (!_closed) config.onOpen();
        })
            .toJS);

    es.addEventListener('error',
        ((web.Event _) => fail(StateError('EventSource error'))).toJS);

    for (final name in config.eventNames) {
      es.addEventListener(
        name,
        ((web.Event e) {
          if (_closed) return;
          final raw = (e as web.MessageEvent).data;
          final data = raw == null
              ? ''
              : (raw.dartify() as String? ?? raw.toString());
          config.onEvent(name, data);
        }).toJS,
      );
    }
  }

  @override
  Future<void> close() async {
    _es?.close();
    _es = null;
    _closed = true;
  }
}

SseTransport createSseTransport(SseTransportConfig config) =>
    WebSseTransport(config);
