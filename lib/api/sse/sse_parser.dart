/// SSE wire-format parser (the `text/event-stream` grammar, client side).
///
/// Pure Dart — no Flutter, no IO — so it unit-tests in isolation and runs on
/// every platform. The server (fufut-api `handlers/sse.js`) sends named
/// events with single-line JSON data and periodic `: comment` keepalives to
/// ride through Cloudflare's proxy idle window; this parser must never turn
/// a keepalive into an event.
///
/// Implemented per the WHATWG spec, client-relevant subset:
///  * lines end at \n, \r, or \r\n;
///  * `event:` sets the next dispatched event's name (default `message`);
///  * `data:` appends a line to the payload (joined with \n);
///  * a blank line dispatches the pending event, if it has any data;
///  * `:`-prefixed lines are comments — ignored;
///  * `id:`/`retry:` are accepted and ignored (the channel reconnects from
///    scratch with its own backoff — it never replays a lost event id).
library;

import 'dart:convert';

class SseEvent {
  final String event;
  final String data;

  const SseEvent(this.event, this.data);

  /// JSON-decode the payload, or null when it is not a JSON object (the
  /// caller decides whether that is fatal or a refetch trigger).
  Map<String, dynamic>? tryDecodeJson() {
    try {
      final v = jsonDecode(data);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'SseEvent($event, ${data.length} chars)';
}

class SseParser {
  /// Partial line carried between [feed] calls — chunks split anywhere.
  final StringBuffer _pending = StringBuffer();

  String _eventName = 'message';
  final StringBuffer _dataLines = StringBuffer();

  /// Feed a decoded text chunk; returns every event that was fully
  /// dispatched by the end of it.
  List<SseEvent> feed(String chunk) {
    final out = <SseEvent>[];
    final text = _pending.toString() + chunk;
    _pending.clear();

    var start = 0;
    while (true) {
      var i = start;
      var ends = 0; // 0 = not found yet, 1 = \n or \r, 2 = \r\n
      while (i < text.length) {
        final c = text[i];
        if (c == '\n') {
          ends = 1;
          break;
        }
        if (c == '\r') {
          ends = text.length > i + 1 && text[i + 1] == '\n' ? 2 : 1;
          break;
        }
        i++;
      }
      if (ends == 0) break; // no complete line left — buffer the tail
      final line = text.substring(start, i);
      start = i + ends;
      _handleLine(line, out);
    }
    _pending.write(text.substring(start));
    return out;
  }

  void _handleLine(String line, List<SseEvent> out) {
    if (line.isEmpty) {
      out.addAll(_dispatch());
      return;
    }
    if (line.startsWith(':')) return; // keepalive / comment

    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1); // single BOM-space

    switch (field) {
      case 'event':
        _eventName = value.isEmpty ? 'message' : value;
      case 'data':
        _dataLines.write(value);
        _dataLines.write('\n');
      default:
        break; // id:, retry:, unknown — ignored by design
    }
  }

  List<SseEvent> _dispatch() {
    if (_dataLines.isEmpty) {
      _eventName = 'message';
      return const [];
    }
    final data = _dataLines.toString();
    // The joining newline after the last data line is not part of the payload.
    final payload =
        data.endsWith('\n') ? data.substring(0, data.length - 1) : data;
    final ev = SseEvent(_eventName, payload);
    _eventName = 'message';
    _dataLines.clear();
    return [ev];
  }
}
