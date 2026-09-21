/// Standalone SSE probe — no Flutter, just the IO transport + parser.
/// Usage: FUFUT_SSE_TOKEN=... dart run scripts/sse_probe.dart
//
// ignore_for_file: avoid_print // a diagnostic tool; printing is the point
library;

import 'dart:async';
import 'dart:io';

import 'package:fufut_pos/api/sse/sse_transport.dart';

Future<void> main() async {
  final token = Platform.environment['FUFUT_SSE_TOKEN'];
  if (token == null || token.isEmpty) {
    stderr.writeln('FUFUT_SSE_TOKEN required');
    exit(2);
  }

  print('probe: connecting…');
  final transport = createSseTransport(SseTransportConfig(
    url: Uri.parse(
        'https://fufut-api.fufutcoffee.workers.dev/api/events/kitchen'),
    headers: {'Cookie': 'session=$token'},
    eventNames: const {'connected', 'new_order', 'order_update'},
    onOpen: () => print('probe: OPEN'),
    onError: (e) => print('probe: ERROR — $e'),
    onEvent: (name, data) => print(
        'probe: EVENT $name (${data.length} chars) ${data.length > 80 ? data.substring(0, 80) : data}'),
  ));

  await Future<void>.delayed(const Duration(seconds: 10));
  await transport.close();
  print('probe: closed');
  exit(0);
}
