import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fufut_pos/api/api_client.dart';
import 'package:fufut_pos/api/fufut_api.dart';
import 'package:fufut_pos/models/models.dart';
import 'package:fufut_pos/screens/cart_sheet.dart';
import 'package:fufut_pos/state/app_state.dart';
import 'package:fufut_pos/state/cart.dart';

/// Service law 2 — the forced table pick. A dine-in cart without a table
/// cannot leave the cart panel: the banner stands before the tap, the send
/// tap refuses AND opens the Order details tile (the picker lives there),
/// and nothing touches the API until a table chip is chosen. Takeaway and
/// delivery never see any of it.
///
/// Same scripted-client harness as orders_today_test.dart: a route table of
/// `METHOD /path` → (status, payload), recorded calls asserted from the
/// tests. The cart rides a seeded CartNotifier so the panel starts with a
/// dine-in order already on it (mock prefs stay empty — the 12h restore
/// reads null and never touches the seed).
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
    final key = '${request.method} $path';
    final (status, payload) =
        routes[key] ?? (200, <String, dynamic>{});
    return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(payload))), status,
        headers: {'content-type': 'application/json'});
  }
}

MenuItem _item(String id, String name, double price) => MenuItem(
      id: id,
      name: name,
      category: 'HOT DRINKS',
      price: price,
    );

CartState _dineInCart() {
  final cart = CartState();
  cart.addItem(_item('MI1', 'Espresso', 150));
  cart.setOrderType('dine-in');
  return cart;
}

void main() {
  late AppState app;
  final routes = <String, (int, Object?)>{};
  final recorded = <({String method, String path, String? body})>[];

  setUp(() {
    // Per-test, NOT setUpAll: the cart persists every mutation to prefs,
    // and the next test's async _restore would read the previous test's
    // leftovers back over its seed (the takeaway case went dine-in).
    SharedPreferences.setMockInitialValues(<String, Object>{});
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
        id: 'S9', firstName: 'Selam', lastName: 'Bekele', role: 'waiter');
    app.roleKey = 'head-waiter';
    // The floor the picker renders: one free table, one occupied. Numbers
    // chosen so no assertion collides with quantity text elsewhere.
    routes['GET /tables'] = (
      200,
      [
        {'id': 'T1', 'number': '7', 'status': 'available'},
        {'id': 'T2', 'number': '9', 'status': 'occupied'},
      ]
    );
  });

  /// Pumps the cart panel as a PUSHED route (production shows it as a
  /// sheet — the send success pops the navigator, which needs a route to
  /// pop), with the app state and the seeded cart under one container.
  /// Returns the container so tests can read the cart after the panel
  /// pops itself off the navigation stack (the production send flow).
  Future<ProviderContainer> pumpCart(WidgetTester tester, CartState cart) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStateProvider.overrideWith(() => AppStateNotifier(seed: app)),
          cartProvider.overrideWith(() => CartNotifier(seed: cart)),
        ],
        child: MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    navKey.currentState!.push(MaterialPageRoute(
      builder: (_) => const Scaffold(body: CartPanel()),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return ProviderScope.containerOf(
        tester.element(find.byType(CartPanel)));
  }

  group('forced table pick — dine-in cannot leave without a table', () {
    testWidgets('banner stands before the tap; send refuses, opens the '
        'details tile, and nothing posts', (tester) async {
      await pumpCart(tester, _dineInCart());
      // The requirement is visible BEFORE any tap.
      expect(
        find.text('Dine-in orders need a table — pick one in Order details.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Send to Kitchen'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // The refusal names the miss…
      expect(find.text('Pick a table for dine-in orders'), findsOneWidget);
      // …the details tile opened itself (picker on screen, no hunting)…
      expect(find.text('Dine-in · no table picked'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      // …and no write reached the API.
      expect(recorded.where((r) => r.method == 'POST'), isEmpty);
    });

    testWidgets('picking a table releases the gate: claim, order, empty cart',
        (tester) async {
      routes['POST /orders'] = (200, {'id': 'Ogate1'});
      final cart = _dineInCart();
      final container = await pumpCart(tester, cart);

      await tester.tap(find.text('Send to Kitchen'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // First tap refused and opened the picker; the free table is there.
      await tester.tap(find.text('7'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // The banner is gone the moment a table is picked.
      expect(
        find.text('Dine-in orders need a table — pick one in Order details.'),
        findsNothing,
      );
      expect(find.text('Dine-in · Table 7'), findsOneWidget);

      await tester.tap(find.text('Send to Kitchen'));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // The claim PUT went out for the free table, then the order POST
      // carrying that table number.
      expect(
        recorded.map((r) => '${r.method} ${r.path}'),
        contains('PUT /tables/T1'),
      );
      final post = recorded.singleWhere((r) => r.method == 'POST');
      expect(post.path, '/orders');
      expect(post.body, contains('"tableNum":"7"'));

      // The cart emptied (read from the container — the panel popped its
      // own route on success, exactly as production does) and the success
      // toast names the new ticket.
      expect(find.textContaining('sent to kitchen'), findsOneWidget);
      expect(container.read(cartProvider).isEmpty, isTrue);
    });

    testWidgets('takeaway never sees the table law', (tester) async {
      final cart = CartState();
      cart.addItem(_item('MI1', 'Espresso', 150));
      cart.setOrderType('takeaway');
      await pumpCart(tester, cart);

      expect(
        find.text('Dine-in orders need a table — pick one in Order details.'),
        findsNothing,
      );
      expect(find.text('Dine-in · no table picked'), findsNothing);
    });
  });
}
