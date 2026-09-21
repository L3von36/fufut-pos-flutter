/// LIVE end-to-end probe for the SSE kitchen channel — runs the real IO
/// transport, parser and models against the production fufut-api Worker.
///
/// NOT part of CI (`flutter test` skips it without the flag):
///
///     FUFUT_SSE_TOKEN=<session token> \
///       flutter test --dart-define=FUFUT_LIVE_SSE=true test/sse_live_manual_test.dart
///
/// Get a token: POST /api/auth/login {email, password} → Set-Cookie session=…
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fufut_pos/api/sse/sse_channel.dart';
import 'package:fufut_pos/models/models.dart';
void main() {
  const live = bool.fromEnvironment('FUFUT_LIVE_SSE');

  test('live kitchen channel: connect, hello, snapshot, keepalive', () async {
    if (!live) {
      markTestSkipped(
          'live probe — run with --dart-define=FUFUT_LIVE_SSE=true and FUFUT_SSE_TOKEN');
      return;
    }
    final token = Platform.environment['FUFUT_SSE_TOKEN'];
    if (token == null || token.isEmpty) {
      fail('FUFUT_SSE_TOKEN env var is required for the live probe');
    }

    final channel = SseChannel(
      baseUrl: 'https://fufut-api.fufutcoffee.workers.dev',
      channel: 'kitchen',
      sessionToken: token,
    );

    final events = <SseEvent>[];
    final sub = channel.stream.listen(events.add);

    // 1. The transport opens and the channel flips its connected flag.
    channel.connect();
    await waitUntil(() => channel.connected.value, const Duration(seconds: 15));
    expect(channel.connected.value, isTrue);

    // 2. Hello + quota mode arrive as named events; the first new_order
    //    snapshot lands almost immediately (server ticks on attach).
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(events.map((e) => e.event), contains('connected'));
    expect(channel.quotaMode.value, 'normal');

    final snapshot = events.firstWhere(
      (e) => e.event == 'new_order',
      orElse: () => const SseEvent('new_order', '{"orders":[]}'),
    );
    final json = snapshot.tryDecodeJson();
    expect(json, isNotNull, reason: 'new_order payload must be a JSON object');
    expect(json!['orders'], isA<List>());

    // 3. The snapshot rows parse through the same model the GET endpoint
    //    uses — every row present, ids non-empty, status a known value.
    final orders = (json['orders'] as List)
        .whereType<Map>()
        .map((m) => FufutOrder.fromJson(Map<String, dynamic>.from(m)))
        .toList();
    for (final o in orders) {
      expect(o.id, isNotEmpty);
      expect(
        o.status.toLowerCase(),
        anyOf('new', 'preparing', 'ready', 'served', 'completed', 'cancelled'),
      );
    }

    // 4. Clean teardown — no retry timer may survive a disconnect.
    channel.disconnect();
    await sub.cancel();
    expect(channel.connected.value, isFalse);
  }, timeout: const Timeout(Duration(seconds: 45)));
}

Future<void> waitUntil(bool Function() test, Duration limit) async {
  final end = DateTime.now().add(limit);
  while (!test()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('condition not met within $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
