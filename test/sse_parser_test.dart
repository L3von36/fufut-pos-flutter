/// SSE wire-format parser tests — the grammar the fufut-api channels speak.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fufut_pos/api/sse/sse_parser.dart';

void main() {
  group('SseParser', () {
    test('single named event, single line of data', () {
      final p = SseParser();
      final evs = p.feed('event: new_order\ndata: {"orders":[]}\n\n');
      expect(evs, hasLength(1));
      expect(evs.single.event, 'new_order');
      expect(evs.single.data, '{"orders":[]}');
    });

    test('event split across chunks at arbitrary points', () {
      final p = SseParser();
      expect(p.feed('event: conne'), isEmpty);
      expect(p.feed('cted\nda'), isEmpty);
      expect(p.feed('ta: {"ok":true}\n'), isEmpty);
      final evs = p.feed('\n');
      expect(evs, hasLength(1));
      expect(evs.single.event, 'connected');
      expect(evs.single.data, '{"ok":true}');
    });

    test('multi-line data joins with \\n, trailing joiner stripped', () {
      final p = SseParser();
      final evs = p.feed('event: note\ndata: line one\ndata: line two\n\n');
      expect(evs.single.data, 'line one\nline two');
    });

    test('keepalive comments never produce events', () {
      final p = SseParser();
      expect(p.feed(': ping\n\n'), isEmpty);
      expect(p.feed(': keep-alive 2026-09-21T12:00:00Z\n\n'), isEmpty);
    });

    test('CRLF line endings', () {
      final p = SseParser();
      final evs = p.feed('event: quota_mode\r\ndata: {"mode":"normal"}\r\n\r\n');
      expect(evs.single.event, 'quota_mode');
      expect(evs.single.data, '{"mode":"normal"}');
    });

    test('data-only event defaults to "message"', () {
      final p = SseParser();
      final evs = p.feed('data: hello\n\n');
      expect(evs.single.event, 'message');
      expect(evs.single.data, 'hello');
    });

    test('id: and retry: accepted and ignored', () {
      final p = SseParser();
      final evs = p.feed(
          'id: 42\nretry: 3000\nevent: new_order\ndata: {"orders":[]}\n\n');
      expect(evs.single.event, 'new_order');
    });

    test('two consecutive events in one chunk', () {
      final p = SseParser();
      final evs = p.feed('event: connected\ndata: {"ok":true}\n\n'
          'event: quota_mode\ndata: {"mode":"normal"}\n\n');
      expect(evs.map((e) => e.event), ['connected', 'quota_mode']);
    });

    test('field value without a space after the colon', () {
      final p = SseParser();
      final evs = p.feed('event:new_order\ndata:{"a":1}\n\n');
      expect(evs.single.event, 'new_order');
      expect(evs.single.data, '{"a":1}');
    });

    test('blank lines without pending data emit nothing', () {
      final p = SseParser();
      expect(p.feed('\n\n\nevent: x\ndata: 1\n\n'), hasLength(1));
    });

    test('tryDecodeJson returns null for non-JSON payloads', () {
      final p = SseParser();
      final evs = p.feed('data: not json at all\n\n');
      expect(evs.single.tryDecodeJson(), isNull);
    });

    test('realistic production snapshot shape parses', () {
      const payload =
          'event: new_order\ndata: {"orders":[{"id":"ORD-1","status":"new","items":"2x Latte","tableNum":"4"}]}\n\n'
          ': ping\n\n';
      final p = SseParser();
      final evs = p.feed(payload);
      expect(evs, hasLength(1));
      final json = evs.single.tryDecodeJson();
      expect(json, isNotNull);
      expect((json!['orders'] as List).first['id'], 'ORD-1');
    });
  });
}
