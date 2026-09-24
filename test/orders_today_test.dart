import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fufut_pos/api/api_client.dart';
import 'package:fufut_pos/api/fufut_api.dart';
import 'package:fufut_pos/models/models.dart';
import 'package:fufut_pos/screens/orders_screen.dart';
import 'package:fufut_pos/screens/pipeline_screen.dart';
import 'package:fufut_pos/state/app_state.dart';
import 'package:fufut_pos/state/order_scope.dart';

/// Today-only scoping, end to end: the Orders screen reads the live service
/// day, the Pipeline hides previous-day tickets (with a visible count), Open
/// Checks groups the older unpaid tabs instead of mixing them into the day,
/// and the Order History screen pages through any day window.
///
/// Same scripted-client harness as tables_screen_test.dart: a route table of
/// `METHOD /path?query` → (status, payload), recorded calls asserted from the
/// tests. All stamps are venue-local "YYYY-MM-DD HH:MM:SS" strings — the
/// shape production rows actually carry.
const _fakeBaseUrl = 'http://fake.fufut.test';

class _ScriptedClient extends http.BaseClient {
  final Map<String, (int, Object?)> routes;
  final List<({String method, String path, String? body})> recorded;
  _ScriptedClient(this.routes, this.recorded);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : null;
    final path = request.url.path.replaceFirst('/api', '');
    recorded.add((
      method: request.method,
      path: path + (request.url.query.isEmpty ? '' : '?${request.url.query}'),
      body: (body == null || body.isEmpty) ? null : body,
    ));

    // The kitchen SSE channel connects and idles — the Offline path is what
    // the pipeline tests exercise, deterministic here.
    if (path.startsWith('/events')) {
      return http.StreamedResponse(
          Stream.value(utf8.encode('retry: 60000\n\n')), 200,
          headers: {'content-type': 'text/event-stream'});
    }

    final key = '${request.method} $path'
        '${request.url.query.isEmpty ? '' : '?${request.url.query}'}';
    final scripted = routes[key] ?? routes['${request.method} $path'];
    final (status, payload) = scripted ?? (200, <String, dynamic>{});
    return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(payload))), status,
        headers: {'content-type': 'application/json'});
  }
}

String _todayKey() => localTodayKey();

String _yesterdayKey() {
  final y = DateTime.now().subtract(const Duration(days: 1));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${y.year}-${two(y.month)}-${two(y.day)}';
}

String _yesterdayStamp() => '${_yesterdayKey()} 09:30:00';

Map<String, Object?> _orderJson(
  String id,
  String status, {
  String? created,
  String? tableId,
  String paymentStatus = 'unpaid',
  double total = 120,
  String? voidedAt,
}) =>
    {
      'id': id,
      'status': status,
      'table_id': tableId,
      'total': total,
      'payment_status': paymentStatus,
      'created': created ?? '${_todayKey()} 10:00:00',
      if (voidedAt != null) 'voided_at': voidedAt,
      'items': [
        {'qty': 1, 'name': 'Macchiato'},
      ],
    };

FufutOrder _order(String id, String status,
        {String? created, String? voidedAt}) =>
    FufutOrder.fromJson(
        _orderJson(id, status, created: created, voidedAt: voidedAt));

void main() {
  late AppState app;
  final routes = <String, (int, Object?)>{};
  final recorded = <({String method, String path, String? body})>[];

  setUpAll(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  setUp(() {
    routes.clear();
    recorded.clear();
    final client = ApiClient(
      baseUrl: _fakeBaseUrl,
      sessionToken: 'test-session-token',
      httpClient: _ScriptedClient(routes, recorded),
    );
    app = AppState();
    app.client = client;
    app.api = FufutApi(client);
    app.user = const StaffUser(
        id: 'S1', firstName: 'Marta', lastName: 'Alemu', role: 'manager');
    app.roleKey = 'manager';
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpOrders(WidgetTester tester,
      {bool openOnly = false}) async {
    tester.view.physicalSize = const Size(430, 2400);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding =
        const FakeViewPadding(top: 0, bottom: 0, left: 0, right: 0);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStateProvider.overrideWith(() => AppStateNotifier(seed: app)),
        ],
        child: MaterialApp(
          home: Scaffold(
              body: OrdersScreen(openOnlyDefault: openOnly)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await settle(tester);
  }

  group('day-scope helpers', () {
    test('localTodayKey formats the device-local calendar day', () {
      expect(localTodayKey(DateTime(2026, 9, 7, 5, 3)), '2026-09-07');
      expect(localTodayKey(DateTime(2026, 1, 30, 23, 59)), '2026-01-30');
    });

    test('orderIsToday matches the local day prefix, not UTC math', () {
      // Post-midnight local: an order stamped 00:20 today IS today even
      // though its UTC instant falls on yesterday's calendar day.
      final now = DateTime(2026, 9, 22, 0, 20);
      expect(orderIsToday(_order('A', 'new', created: '2026-09-22 00:20:00'),
          now: now), isTrue);
      expect(orderIsToday(_order('B', 'new', created: '2026-09-21 23:59:00'),
          now: now), isFalse);
      expect(orderIsToday(_order('C', 'new', created: ''), now: now),
          isFalse);
    });

    test('orderIsReal mirrors REAL_ORDERS — voided or cancelled excluded',
        () {
      expect(orderIsReal(_order('A', 'fulfilled')), isTrue);
      expect(
          orderIsReal(_order('B', 'cancelled',
              voidedAt: '2026-09-21 12:00:00')),
          isFalse);
      expect(
          orderIsReal(_order('C', 'new', voidedAt: '2026-09-21 12:00:00')),
          isFalse);
    });
  });

  group('OrdersScreen — today only', () {
    testWidgets('fetches the day window and hides yesterday even if served',
        (tester) async {
      routes['GET /orders?from=${_todayKey()}&to=${_todayKey()}'] = (
        200,
        [
          _orderJson('O-today', 'ready', tableId: '2'),
          // The server should never return this for today's window, but a
          // stale offline cache could — the client guard is the second lock.
          _orderJson('O-yesterday', 'fulfilled',
              created: _yesterdayStamp()),
        ]
      );

      await pumpOrders(tester);

      expect(find.textContaining('O-today'), findsOneWidget);
      expect(find.textContaining('O-yesterday'), findsNothing);

      // The server was asked for today's window, not the plain last-200.
      expect(
        recorded.map((r) => '${r.method} ${r.path}'),
        contains('GET /orders?from=${_todayKey()}&to=${_todayKey()}'),
      );
    });

    testWidgets('history action pushes the Order History screen',
        (tester) async {
      routes['GET /orders?from=${_todayKey()}&to=${_todayKey()}'] =
          (200, []);
      // The history screen derives its default yesterday window from the
      // clock at runtime — the mock must be derived the same way or the
      // route misses the day the calendar rolls over (2026-09-21 was pinned
      // and CI went red the next midnight).
      final historyWindow =
          'GET /orders?from=${_yesterdayKey()}&to=${_yesterdayKey()}&limit=100&offset=0';
      routes[historyWindow] = (
        200,
        [
          _orderJson('H1', 'completed',
              created: '${_yesterdayKey()} 15:00:00', total: 90),
        ]
      );

      await pumpOrders(tester);

      await tester.tap(find.byIcon(Icons.history_rounded).first);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);

      expect(find.text('Order History'), findsWidgets);
      // The history screen asked for the yesterday default window, paged.
      // (History tiles render the short id: #H1.)
      expect(find.textContaining('#H1'), findsOneWidget);
      expect(
        recorded.map((r) => '${r.method} ${r.path}'),
        contains(historyWindow),
      );
    });
  });

  group('OrdersScreen — Open Checks mode', () {
    testWidgets('today leads; previous-day tabs group under a toggle',
        (tester) async {
      routes['GET /orders?open=1'] = (
        200,
        [
          _orderJson('O-today-open', 'new', tableId: '4'),
          _orderJson('O-old-tab', 'served',
              created: _yesterdayStamp(), tableId: '7', total: 340),
        ]
      );

      await pumpOrders(tester, openOnly: true);

      expect(find.textContaining('O-today-open'), findsOneWidget);
      // The older tab is grouped, not shown inline…
      expect(find.textContaining('O-old-tab'), findsNothing);
      expect(
          find.textContaining('Older open checks (1)'), findsOneWidget);

      // …and one tap brings it back — an unpaid tab is money owed.
      await tester.tap(find.textContaining('Older open checks'));
      await settle(tester);
      expect(find.textContaining('O-old-tab'), findsOneWidget);
    });

    testWidgets('with no checks today, the daynote still points to the debt',
        (tester) async {
      routes['GET /orders?open=1'] = (
        200,
        [
          _orderJson('O-old-tab', 'new',
              created: _yesterdayStamp(), tableId: '2'),
        ]
      );

      await pumpOrders(tester, openOnly: true);

      expect(find.textContaining('No checks opened today'), findsOneWidget);
      expect(
          find.textContaining('Older open checks (1)'), findsOneWidget);
    });
  });

  group('PipelineScreen — today only', () {
    testWidgets('previous-day tickets are hidden from the lanes and counted',
        (tester) async {
      routes['GET /orders'] = (
        200,
        [
          _orderJson('PT1', 'new', tableId: '3'),
          _orderJson('PS9', 'preparing',
              created: _yesterdayStamp(), tableId: '5'),
        ]
      );

      tester.view.physicalSize = const Size(1366, 1200);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding =
          const FakeViewPadding(top: 0, bottom: 0, left: 0, right: 0);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => AppStateNotifier(seed: app)),
          ],
          child: const MaterialApp(home: Scaffold(body: PipelineScreen())),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await settle(tester);

      // Lane cards render the short id (#PT1 / #PS9).
      expect(find.textContaining('#PT1'), findsOneWidget);
      expect(find.textContaining('#PS9'), findsNothing);
      // The hidden count is surfaced so nothing silently vanishes.
      expect(find.textContaining('1 earlier ticket from previous days'),
          findsOneWidget);
    });
  });
}
