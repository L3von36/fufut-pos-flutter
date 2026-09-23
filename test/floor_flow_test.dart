import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fufut_pos/api/api_client.dart';
import 'package:fufut_pos/api/fufut_api.dart';
import 'package:fufut_pos/models/models.dart';
import 'package:fufut_pos/screens/kitchen_board.dart';
import 'package:fufut_pos/screens/orders_screen.dart';
import 'package:fufut_pos/state/app_state.dart';
import 'package:fufut_pos/state/order_scope.dart';
import 'package:fufut_pos/state/roles.dart';

/// The owner's 2026-09 floor rules, end to end:
///  * the kitchen hands off ("Picked up by waiter"), the floor serves —
///    and the chef never says "served";
///  * only SERVED orders settle;
///  * the kitchen board shows the service day only — previous-day open
///    tickets drop off with a visible count, not a silent vanish.
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

Map<String, Object?> _orderJson(
  String id,
  String status, {
  String? created,
  String table = '3',
  String paymentStatus = 'unpaid',
  double total = 120,
}) =>
    {
      'id': id,
      'status': status,
      'table_id': table,
      'total': total,
      'payment_status': paymentStatus,
      // `payment` is the till's derived state — the sheet's isPaid guard
      // reads it alongside payment_status, so the fixture must carry both.
      'payment': paymentStatus,
      'created': created ?? '${_todayKey()} 10:00:00',
      'items': [
        {'qty': 1, 'name': 'Macchiato'},
      ],
    };

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

  Future<void> pumpDetail(WidgetTester tester, FufutOrder order) async {
    tester.view.physicalSize = const Size(430, 2000);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding =
        const FakeViewPadding(top: 0, bottom: 0, left: 0, right: 0);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          home: Scaffold(
            body: OrderDetailSheet(order: order),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  group('serve grants', () {
    test('the floor and the till serve; the kitchen never does', () {
      for (final role in ['manager', 'head-waiter', 'cashier']) {
        expect(canMarkServed(role), isTrue,
            reason: '$role should mark orders served');
      }
      for (final role in ['head-chef', 'assistant-chef', 'barista']) {
        expect(canMarkServed(role), isFalse,
            reason: '$role must not mark orders served');
      }
    });
  });

  group('settle gate — only served orders take money', () {
    testWidgets('a brand-new unpaid order shows no settle button',
        (tester) async {
      app.roleKey = 'cashier';
      await pumpDetail(
          tester, FufutOrder.fromJson(_orderJson('O-new', 'new')));

      expect(find.text('Settle — take payment'), findsNothing);
      expect(find.text('Settle opens once the order is served.'),
          findsOneWidget);
    });

    testWidgets('a ready-but-unserved order still cannot settle',
        (tester) async {
      app.roleKey = 'cashier';
      await pumpDetail(
          tester, FufutOrder.fromJson(_orderJson('O-ready', 'ready')));

      expect(find.text('Settle — take payment'), findsNothing);
    });

    testWidgets('a served order settles for the checkout grant',
        (tester) async {
      app.roleKey = 'cashier';
      await pumpDetail(
          tester, FufutOrder.fromJson(_orderJson('O-served', 'served')));

      expect(find.text('Settle — take payment'), findsOneWidget);
    });

    testWidgets('the floor sees no settle button even on served tickets',
        (tester) async {
      app.roleKey = 'head-waiter';
      await pumpDetail(
          tester, FufutOrder.fromJson(_orderJson('O-served', 'served')));

      expect(find.text('Settle — take payment'), findsNothing);
    });
  });

  group('handoff flow — kitchen picks up, floor serves', () {
    testWidgets('the chef hands a ready ticket to the floor',
        (tester) async {
      app.roleKey = 'head-chef';
      await pumpDetail(
          tester, FufutOrder.fromJson(_orderJson('O-ready', 'ready')));

      expect(find.text('Picked up by waiter'), findsOneWidget);
      expect(find.text('Mark served'), findsNothing);
      expect(find.text('Settle — take payment'), findsNothing);

      await tester.tap(find.text('Picked up by waiter'));
      await settle(tester);
      final put = recorded.firstWhere((r) =>
          r.method == 'PUT' &&
          r.path == '/orders/O-ready' &&
          (r.body ?? '').contains('fulfilled'));
      expect(put, isNotNull);
    });

    testWidgets('the waiter marks a picked-up order served',
        (tester) async {
      app.roleKey = 'head-waiter';
      await pumpDetail(
          tester, FufutOrder.fromJson(_orderJson('O-ful', 'fulfilled')));

      expect(find.text('Mark served'), findsOneWidget);
      expect(find.text('Picked up by waiter'), findsNothing);

      await tester.tap(find.text('Mark served'));
      await settle(tester);
      final put = recorded.firstWhere((r) =>
          r.method == 'PUT' &&
          r.path == '/orders/O-ful' &&
          (r.body ?? '').contains('served'));
      expect(put, isNotNull);
    });

    testWidgets('the chef gets no serve action on a picked-up order',
        (tester) async {
      app.roleKey = 'head-chef';
      await pumpDetail(
          tester, FufutOrder.fromJson(_orderJson('O-ful', 'fulfilled')));

      expect(find.text('Mark served'), findsNothing);
      expect(find.text('No actions for your role on this stage.'),
          findsOneWidget);
    });
  });

  group('kitchen board — the service day only', () {
    testWidgets('previous-day open tickets drop off with a counted note',
        (tester) async {
      routes['GET /orders?open=1'] = (
        200,
        [
          // Today's ticket — stays (shortId renders the last 4: #aaaa).
          _orderJson('K-aaaa', 'new', created: '${_todayKey()} 09:40:00'),
          // The stale split from two days ago — the leak the owner hit
          // (ORD-SPLIT-mub7i79h-4 sat on the pass for days).
          _orderJson('K-bbbb', 'completed',
              created: '$_yesterdayKey 12:13:34'),
        ]
      );
      routes['GET /orders/items/active'] = (200, []);

      tester.view.physicalSize = const Size(430, 1600);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding =
          const FakeViewPadding(top: 0, bottom: 0, left: 0, right: 0);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: const MaterialApp(
            home: Scaffold(body: KitchenBoard()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await settle(tester);

      // Today's ticket on the board…
      expect(find.textContaining('#aaaa'), findsOneWidget);
      // …the stale ticket gone, but counted to the staff's face.
      expect(find.textContaining('#bbbb'), findsNothing);
      expect(find.textContaining('open ticket'), findsWidgets,
          reason: 'the hidden count must be visible');
    });

    testWidgets('a picked-up ticket leaves the board', (tester) async {
      routes['GET /orders?open=1'] = (
        200,
        [
          _orderJson('K-cccc', 'fulfilled',
              created: '${_todayKey()} 09:00:00'),
        ]
      );
      routes['GET /orders/items/active'] = (200, []);

      tester.view.physicalSize = const Size(430, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: app,
          child: const MaterialApp(
            home: Scaffold(body: KitchenBoard()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await settle(tester);

      expect(find.textContaining('#cccc'), findsNothing,
          reason: 'fulfilled = handed to the floor; the pass is clear');
      expect(find.text('All quiet on the pass'), findsOneWidget);
    });
  });
}
