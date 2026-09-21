/// Native SSE transport: a streamed HTTP GET (`package:http`), one byte
/// stream parsed by [SseParser]. Works on Android, iOS, Windows, macOS and
/// Linux — everywhere `dart:io` lives.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sse_parser.dart';
import 'sse_transport_types.dart';

class IoSseTransport implements SseTransport {
  final http.Client _client = http.Client();
  bool _closed = false;
  StreamSubscription<void>? _sub;

  IoSseTransport(SseTransportConfig config) {
    _run(config);
  }

  Future<void> _run(SseTransportConfig config) async {
    final request = http.Request('GET', config.url)
      ..headers['Accept'] = 'text/event-stream'
      ..headers['Cache-Control'] = 'no-cache'
      ..followRedirects = true;
    config.headers.forEach((k, v) => request.headers[k] = v);

    http.StreamedResponse response;
    try {
      // No timeout: the whole point of this request is to never finish.
      response = await _client.send(request);
    } catch (e) {
      if (_closed) return;
      config.onError(StateError('SSE connect failed: $e'));
      return;
    }
    if (_closed) return;

    if (response.statusCode != 200) {
      // Read a bounded snippet of the error body so the channel can log
      // something actionable (401 session expired vs 403 role gate).
      var snippet = '';
      try {
        final bytes = await response.stream
            .cast<List<int>>()
            .take(1)
            .first
            .timeout(const Duration(seconds: 5));
        snippet = utf8.decode(bytes, allowMalformed: true);
        if (snippet.length > 200) snippet = snippet.substring(0, 200);
      } catch (_) {}
      config.onError(StateError(
          'SSE ${config.url.path} answered ${response.statusCode} $snippet'));
      return;
    }

    // 200 = the stream is live. Fire onOpen before the first bytes flow so
    // the channel flips its connected flag the moment data can arrive (the
    // web transport gets this for free from EventSource's open event).
    config.onOpen();

    final parser = SseParser();
    _sub = response.stream
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
      (chunk) {
        if (_closed) return;
        for (final ev in parser.feed(chunk)) {
          config.onEvent(ev.event, ev.data);
        }
      },
      onError: (Object e) {
        if (_closed) return;
        config.onError(StateError('SSE stream failed: $e'));
      },
      onDone: () {
        if (_closed) return;
        // The server closed (deploy, proxy timeout, kill signal). Not an
        // exception, but the transport is over either way — the channel
        // reconnects with backoff.
        config.onError(StateError('SSE stream ended'));
      },
      cancelOnError: true,
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub?.cancel();
    _client.close();
  }
}

SseTransport createSseTransport(SseTransportConfig config) =>
    IoSseTransport(config);
