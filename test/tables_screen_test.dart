// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fufut_pos/api/api_client.dart';
import 'package:fufut_pos/api/fufut_api.dart';
import 'package:fufut_pos/models/models.dart';
import 'package:fufut_pos/screens/tables_screen.dart';
import 'package:fufut_pos/state/app_state.dart';
import 'package:fufut_pos/state/cart.dart';

/// A scripted in-process http.Client injected into the ApiClient — the same
/// route-table pattern the contract suite uses, but as a pure Dart double:
/// inside the widget-test binding's fake-async zone, real sockets never
/// deliver, while microtask completions flush with a single pump. The fake
/// answers like the production Worker: JSON in, JSON out, {ok:false} softly.
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

    // The SSE transports connect and idle; the chip asserts the Offline
    // path (the poll carrying the floor), which is deterministic here.
    if (path.startsWith('/events')) {
      return http.StreamedResponse(
          Stream.value(utf8.encode('retry: 60000\n\n')), 200,
          headers: {'content-type': 'text/event-stream'});
    }

    final key = '${request.method} $path'
        '${request.url.query.isEmpty ? '' : '?${request.url.query}'}';
    final scripted = routes[key] ??
        routes['${request.method} $path'] ??
        // The kitchen feed asks for the FULL order list (the pipeline's
        // cancelled/served lanes need it); the scripted kitchen world
        // serves the same open list however the app asks.
        routes['${request.method} $path?open=1'];
    final (status, payload) = scripted ?? (200, <String, dynamic>{});
    return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(payload))), status,
        headers: {'content-type': 'application/json'});
  }
}

/// The floor plan, exercised end-to-end against a scripted API —
/// the TablesView.vue parity suite. The fixtures carry the exact live row
/// shape (name/shape/server/seated_at/notes/bill_requested_at/reservedHold/
/// payment), so the tests pin what the user actually sees on the web:
/// toolbar counts, the filter chips, the pending-QR strip, per-status card
/// content, the detail sheet's save payload, and the bill-request write.
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
        id: 'S6', firstName: 'Yonas', lastName: 'Girmay', role: 'head-waiter');
    app.roleKey = 'head-waiter';
  });

  /// The floor: every status the web card renders, one table per case.
  void scriptFloor() {
    final now = DateTime.now().toUtc();
    String isoAgo(Duration d) => now.subtract(d).toIso8601String();
    String isoIn(Duration d) => now.add(d).toIso8601String();

    routes['GET /tables'] = (
      200,
      [
        {
          'id': 'T2', 'number': 2, 'capacity': 2, 'section': 'Window',
          'status': 'occupied', 'name': 'Table 2', 'shape': 'square',
          'server': 'Yonas Girmay', 'guests': 2,
          'seated_at': isoAgo(const Duration(hours: 2)),
          'notes': '', 'bill_requested_at': '', 'payment': null,
          'reservedHold': null,
        },
        {
          'id': 'T3', 'number': 3, 'capacity': 6, 'section': 'Patio',
          'status': 'occupied', 'name': 'Table 3', 'shape': 'round',
          'server': '', 'guests': 2,
          'seated_at': isoAgo(const Duration(hours: 5)), // past the 4h max
          'notes': 'anniversary', 'bill_requested_at': isoAgo(const Duration(minutes: 3)),
          'bill_requested_by': 'Yonas', 'payment': 'partial',
          'reservedHold': null,
        },
        {
          'id': 'T4', 'number': 4, 'capacity': 4, 'section': 'Main Hall',
          'status': 'reserved', 'name': 'Table 4', 'shape': 'square',
          'server': '', 'guests': 0, 'seated_at': '', 'notes': '',
          'bill_requested_at': '', 'payment': null,
          'reservedHold': {
            'id': 'R1', 'name': 'Sara', 'guests': 4, 'blocksNow': true,
            'startAt': isoIn(const Duration(hours: 2)),
            'endAt': isoIn(const Duration(hours: 4)),
          },
        },
        {
          'id': 'T7', 'number': 7, 'capacity': 4, 'section': 'Main Hall',
          'status': 'available', 'name': 'Table 7', 'shape': 'square',
          'server': '', 'guests': 0, 'seated_at': '', 'notes': '',
          'bill_requested_at': '', 'payment': null, 'reservedHold': null,
        },
        {
          'id': 'T9', 'number': 9, 'capacity': 6, 'section': 'Patio',
          'status': 'cleaning', 'name': 'Table 9', 'shape': 'long',
          'server': '', 'guests': 0, 'seated_at': '', 'notes': '',
          'bill_requested_at': '', 'payment': null, 'reservedHold': null,
        },
        {
          'id': 'T8', 'number': 8, 'capacity': 2, 'section': 'Terrace',
          'status': 'available', 'name': 'Table 8', 'shape': 'round',
          'server': '', 'guests': 0, 'seated_at': '', 'notes': '',
          'bill_requested_at': '', 'payment': null, 'reservedHold': null,
        },
      ]
    );

    // Floor-relevant orders: the paid-fulfilled one must NOT count.
    routes['GET /orders'] = (
      200,
      [
        {
          'id': 'ORD1', 'status': 'ready', 'table_id': '2',
          'total': 120, 'payment_status': 'unpaid',
          'created': isoAgo(const Duration(minutes: 10)),
          'items': [
            {'qty': 2, 'name': 'Macchiato'},
          ],
        },
        {
          'id': 'ORD2', 'status': 'fulfilled', 'table_id': '3',
          'total': 80, 'payment_status': 'unpaid',
          'created': isoAgo(const Duration(minutes: 30)),
          'items': '1x Cake',
        },
        {
          'id': 'ORD3', 'status': 'fulfilled', 'table_id': '2',
          'total': 999, 'payment_status': 'paid',
          'created': isoAgo(const Duration(minutes: 40)),
        },
        {
          'id': 'ORD4', 'status': 'new', 'table_id': '3',
          'total': 50, 'payment_status': 'unpaid',
          'created': isoAgo(const Duration(minutes: 2)),
        },
      ]
    );

    // A guest's QR order waiting for Accept.
    routes['GET /orders/pending'] = (
      200,
      [
        {
          'id': 'PEN1', 'status': 'new', 'table_id': '2', 'source': 'qr',
          'total': 65, 'payment_status': 'unpaid',
          'created': isoAgo(const Duration(minutes: 1)),
          'items': [
            {'qty': 1, 'name': 'Latte'},
          ],
        },
      ]
    );

    routes['GET /tables/sections'] = (
      200,
      {
        'ok': true,
        'sections': ['Patio', 'Main Hall', 'Window', 'VIP Room', 'Bar'],
      }
    );
  }

  Future<void> settle(WidgetTester tester) async {
    // The Live chip and the Bill Requested chip animate forever — pump a
    // fixed window instead of pumpAndSettle.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> pumpFloor(WidgetTester tester) async {
    scriptFloor();
    tester.view.physicalSize = const Size(1366, 2400);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding =
        const FakeViewPadding(top: 0, bottom: 0, left: 0, right: 0);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStateProvider.overrideWith(() => AppStateNotifier(seed: app)),
        ],
        child: const MaterialApp(home: Scaffold(body: TablesScreen())),
      ),
    );
    // The scripted client completes in microtasks — two pump windows flush
    // the parallel bootstrap loads and the state updates.
    await tester.pump(const Duration(milliseconds: 120));
    await settle(tester);
  }

  testWidgets('floor plan renders the web toolbar, strips and cards',
      (tester) async {
    await pumpFloor(tester);

    // Toolbar — title, table count, occupancy percent (2/6 = 33%).
    expect(find.text('Floor Plan'), findsOneWidget);
    expect(find.text('6 tables · 33% occupied'), findsOneWidget);
    // Live chip — the SSE transport owns its own (faked-in-zone) client, so
    // on the VM the channel reads Offline while the poll carries the floor.
    expect(find.textContaining('Live'), findsNothing);
    expect(find.text('Offline'), findsOneWidget);
    // Zone picker — server sections + the merged legacy Terrace zone.
    expect(find.text('All sections'), findsOneWidget);
    expect(find.text('Terrace'), findsOneWidget);

    // Status strip — counts and sub-labels, web wording.
    expect(find.text('Free'), findsOneWidget);
    expect(find.text('6 seats'), findsOneWidget);
    expect(find.text('Seated'), findsOneWidget);
    expect(find.text('4 guests'), findsOneWidget);
    expect(find.text('Reserved'), findsOneWidget);
    expect(find.text('Cleaning'), findsOneWidget);

    // Section headers with counts.
    expect(find.text('Main Hall'), findsOneWidget);
    // The web renders "{n} tables" literally — no pluralization on section
    // headers (Window and Terrace each hold exactly one).
    expect(find.text('1 tables'), findsNWidgets(2));
    expect(find.text('2 tables'), findsNWidgets(2));

    // Card content, by status:
    expect(find.text('T-02'), findsOneWidget); // padded number
    // T2: 1 floor-relevant order (the paid-fulfilled one excluded), timer.
    expect(find.text('1 Order'), findsOneWidget);
    expect(find.text('120 ETB'), findsOneWidget);
    // Open Tab: T2 rides a ready-unpaid check, T3 a served-unpaid one —
    // both count as open tabs (the web's isResumableCheck rule).
    expect(find.text('Open Tab'), findsNWidgets(2));
    expect(find.text('YG'), findsOneWidget); // server initials badge
    // T3: overdue + bill requested + partial payment.
    expect(find.text('Releases soon — past 4h'), findsOneWidget);
    expect(find.text('Bill Requested'), findsOneWidget);
    expect(find.text('Partly Paid'), findsOneWidget);
    // T7: available → capacity + size word.
    expect(find.text('4 Persons · Small'), findsOneWidget);
    // T9: cleaning.
    expect(find.text('Needs cleaning'), findsOneWidget);
    // T4: reserved hold with name + future window label ("from HH:MM").
    expect(find.text('Sara'), findsOneWidget);
    // Hold window on T4's card — "from HH:MM" against the fixture clock.
    expect(find.textContaining(RegExp(r'from \d\d:\d\d')), findsOneWidget);
  });

  testWidgets('status strip chips filter the floor; second tap clears',
      (tester) async {
    await pumpFloor(tester);

    await tester.tap(find.text('Free'));
    await settle(tester);
    expect(find.text('T-07'), findsOneWidget);
    expect(find.text('T-08'), findsOneWidget);
    expect(find.text('T-02'), findsNothing);
    expect(find.text('No tables in any section'), findsNothing);

    await tester.tap(find.text('Free'));
    await settle(tester);
    expect(find.text('T-02'), findsOneWidget);
    expect(find.text('T-07'), findsOneWidget);
  });

  testWidgets('zone picker narrows the floor to one section',
      (tester) async {
    await pumpFloor(tester);

    await tester.tap(find.text('All sections'));
    await settle(tester);
    await tester.tap(find.text('Patio').last);
    await settle(tester);

    expect(find.text('T-03'), findsOneWidget);
    expect(find.text('T-09'), findsOneWidget);
    expect(find.text('T-02'), findsNothing);
    expect(find.text('T-07'), findsNothing);
  });

  testWidgets('pending strip: QR order awaits Accept and leaves on tap',
      (tester) async {
    await pumpFloor(tester);

    expect(find.text('1 order from guests waiting'), findsOneWidget);
    expect(find.text('The kitchen has not seen these yet'), findsOneWidget);
    expect(find.text('QR'), findsOneWidget);
    expect(find.text('Table 2'), findsOneWidget);
    expect(find.text('1x Latte'), findsOneWidget);
    expect(find.text('65 ETB'), findsOneWidget);

    routes['POST /orders/PEN1/accept'] = (200, {'ok': true});
    await tester.tap(find.text('Accept'));
    await settle(tester);

    expect(
      recorded.any((r) =>
          r.method == 'POST' && r.path == '/orders/PEN1/accept'),
      isTrue,
      reason: 'Accept POSTs the order into the kitchen',
    );
    expect(find.text('1 order from guests waiting'), findsNothing,
        reason: 'the accepted order drops immediately (the web drops it '
            'rather than waiting for the reload)');
    expect(find.textContaining('Sent to the kitchen'), findsOneWidget);
  });

  testWidgets('detail sheet: quick status occupied → PUT with newSeating',
      (tester) async {
    await pumpFloor(tester);

    await tester.ensureVisible(find.text('T-07'));
    await settle(tester);
    await tester.tap(find.text('T-07'));
    await settle(tester);

    // Header + sub line — the web's detail modal header.
    expect(find.text('Table 7 — Table 7'), findsOneWidget);
    expect(find.text('Main Hall · 4 seats · square'), findsOneWidget);
    // Non-manager: server field read-only with the explanation.
    expect(find.text('Only a manager can change the assignment'),
        findsOneWidget);
    // Actions available to the floor.
    expect(find.text('New Order'), findsOneWidget);

    // Seat the party: quick status → occupied, then save.
    await tester.tap(find.text('Occupied'));
    await settle(tester);
    expect(find.text('Seated just now ago'), findsOneWidget);
    await tester.tap(find.text('Save Changes'));
    await settle(tester);

    final put = recorded
        .firstWhere((r) => r.method == 'PUT' && r.path == '/tables/T7');
    final payload = jsonDecode(put.body!) as Map<String, dynamic>;
    expect(payload['status'], 'occupied');
    expect(payload['newSeating'], isTrue,
        reason: 'a fresh party is a new seating, not an edit');
    expect(payload['guests'], 0);
    expect((payload['seated_at'] as String).isNotEmpty, isTrue);
    expect(find.text('Table updated'), findsOneWidget);
  });

  testWidgets('detail sheet on an occupied table: Ask for the Bill rides',
      (tester) async {
    await pumpFloor(tester);

    await tester.ensureVisible(find.text('T-02'));
    await settle(tester);
    await tester.tap(find.text('T-02'));
    await settle(tester);

    // Active Orders section lists the table's open check.
    expect(find.text('Active Orders'), findsOneWidget);
    expect(find.text('2x Macchiato'), findsOneWidget);
    // card + detail list + the History row (the 7-day history fetch rides
    // the same scripted fixture and shows the same ticket).
    expect(find.text('120 ETB'), findsNWidgets(3));

    // Head-waiter may raise the bill request. The sheet comes first: the
    // guest's intended method rides the request (owner's friend, 2026-09),
    // so the test taps through it exactly like the floor does.
    routes['POST /tables/T2/request-bill'] =
        (200, {'ok': true, 'requestedAt': '2026-09-22T12:00:00Z'});
    await tester.tap(find.text('Ask for the Bill'));
    await settle(tester);
    expect(find.textContaining('How will the guest pay?'), findsOneWidget);
    await tester.tap(find.text('Request the bill · Cash'));
    await settle(tester);

    final billPost = recorded.firstWhere(
        (r) => r.method == 'POST' && r.path == '/tables/T2/request-bill');
    expect(billPost, isNotNull);
    expect(jsonDecode(billPost.body!)['method'], 'cash');
    expect(find.textContaining('Bill requested for table 2'), findsOneWidget);
    // The sheet now offers the cancel side of the toggle.
    expect(find.text('Cancel Bill Request'), findsOneWidget);
  });

  // ── The kitchen's floor view (owner's call, 2026-09) ─────────────────────

  testWidgets('chef floor view: bill requester named, Free Table rides, no ordering',
      (tester) async {
    app.user = const StaffUser(
        id: 'S2', firstName: 'Selam', lastName: 'Wondimu', role: 'Head Chef');
    app.roleKey = 'head-chef';
    await pumpFloor(tester);

    // T-03: occupied, bill requested by Yonas three minutes ago.
    await tester.ensureVisible(find.text('T-03'));
    await settle(tester);
    await tester.tap(find.text('T-03'));
    await settle(tester);

    // The kitchen sees WHO is asking for the bill — banner + the Active
    // Orders badge both carry the name.
    expect(find.textContaining('Bill requested by Yonas'), findsWidgets);
    // ...gets the table-turn...
    expect(find.text('Free Table'), findsOneWidget);
    // ...and none of the floor's writes: no ticket, no party edits, no
    // quick-status chips.
    expect(find.text('Add Round'), findsNothing);
    expect(find.text('New Order'), findsNothing);
    expect(find.text('Save Changes'), findsNothing);
    expect(find.text('Occupied'), findsNothing);
    expect(find.text('Ask for the Bill'), findsNothing);

    routes['POST /tables/T3/free'] = (200, {'ok': true, 'freed': true});
    await tester.tap(find.text('Free Table'));
    await settle(tester);

    expect(
      recorded.any((r) => r.method == 'POST' && r.path == '/tables/T3/free'),
      isTrue,
      reason: 'the kitchen turns the table without holding the tables write',
    );
    expect(find.text('Table freed'), findsOneWidget);
  });

  testWidgets('chef freeing a table with an unpaid check is refused in words',
      (tester) async {
    app.user = const StaffUser(
        id: 'S2', firstName: 'Selam', lastName: 'Wondimu', role: 'Head Chef');
    app.roleKey = 'head-chef';
    await pumpFloor(tester);

    // T-02: occupied, no bill requested — the free button still rides.
    await tester.ensureVisible(find.text('T-02'));
    await settle(tester);
    await tester.tap(find.text('T-02'));
    await settle(tester);
    expect(find.text('Free Table'), findsOneWidget);

    routes['POST /tables/T2/free'] = (409, {
      'ok': false,
      'error':
          'Table 2 still has 1 unsettled check. Settle at the till before freeing.',
    });
    await tester.tap(find.text('Free Table'));
    await settle(tester);

    // The server's explanation surfaces verbatim — the kitchen learns the
    // bill comes first instead of staring at a stuck table.
    expect(find.textContaining('unsettled check'), findsOneWidget);
    expect(
      recorded.any((r) => r.method == 'POST' && r.path == '/tables/T2/free'),
      isTrue,
    );
  });

  testWidgets('cart add-round context: startAddRound wires the open ticket',
      (tester) async {
    // The "Add Round" write depends on the cart carrying the open check —
    // the web orderStore's isAddRound/activeOpenOrderId pair.
    final cart = CartState();
    cart.startAddRound(orderId: 'ORD1', tableNum: 'T2');
    expect(cart.addingRound, isTrue);
    expect(cart.activeOpenOrderId, 'ORD1');
    expect(cart.tableNum, 'T2');
    expect(cart.orderType, 'dine-in');

    cart.startNewOrderForTable('T7');
    expect(cart.addingRound, isFalse);
    expect(cart.activeOpenOrderId, isNull);
    expect(cart.tableNum, 'T7');

    cart.clear();
    expect(cart.tableNum, '');
    expect(cart.addingRound, isFalse);
  });
}
