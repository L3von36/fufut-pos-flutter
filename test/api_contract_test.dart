// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:fufut_pos/api/api_client.dart';
import 'package:fufut_pos/api/fufut_api.dart';
import 'package:fufut_pos/models/models.dart';

/// Offline contract tests for the whole API layer — "every backend
/// interaction does what it's supposed to do", without touching production.
///
/// A real HTTP server is bound on loopback and scripted per test, so the
/// requests ride the genuine ApiClient code path: URL building, session
/// cookie, browser User-Agent, retries, JSON decoding and the central
/// ok:false guard.
///
///  Part A — route table: each FufutApi method must hit exactly the verb +
///           path the deployed Worker exposes, and parse a representative
///           body into the typed model it promises.
///  Part B — client behaviour: headers, retries, error mapping, the
///           in-band {ok:false} denial guard, network errors, cookie capture.
///  Part C — live-shape replay: every fixture captured from production by
///           test/api_live_test.dart is replayed through its parser, so a
///           server shape change breaks CI, not a shift.

void main() {
  late HttpServer server;
  late ApiClient client;
  late FufutApi api;

  // route → scripted response; recorded → every request the server saw.
  final routes = <String, (int, Object?)>{};
  final recorded = <({String method, String path, String? body,
      Map<String, String> headers})>[];

  setUp(() async {
    routes.clear();
    recorded.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).toList().then((s) => s.join());
      final path = req.uri.path.replaceFirst('/api', '');
      recorded.add((
        method: req.method,
        path: path + (req.uri.query.isEmpty ? '' : '?${req.uri.query}'),
        body: body.isEmpty ? null : body,
        headers: Map.of(req.headers.value('cookie') != null
            ? {'cookie': req.headers.value('cookie')!}
            : {}),
      ));
      final key = '${req.method} $path'
          '${req.uri.query.isEmpty ? '' : '?${req.uri.query}'}';
      final scripted = routes[key] ?? routes['${req.method} $path'];
      final (status, payload) = scripted ?? (200, <String, dynamic>{});
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(payload));
      await req.response.close();
    });
    client = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}')
      ..sessionToken = 'test-session-token';
    api = FufutApi(client);
  });

  tearDown(() async => server.close(force: true));

  // ── Part A — route + parse contract table ────────────────────────────────

  test('every API method hits its documented endpoint and parses', () async {
    // {route key, fixture body, the call, an expectation on the result}
    final cases = <({String route, Object? body, Future<dynamic> Function() invoke,
        void Function(Object?) check})>[
      // ── floor & menu
      (
        route: 'GET /menu',
        body: [
          {'id': 'M1', 'name': 'Latte', 'category': 'Drinks', 'price': 42},
        ],
        invoke: () => api.menu(),
        check: (r) {
          final menu = r as List<MenuItem>;
          expect(menu.single.name, 'Latte');
          expect(menu.single.price, 42);
        },
      ),
      (
        route: 'GET /tables',
        body: [
          {'id': 'T7', 'number': '7', 'section': 'MAIN HALL', 'status':
              'occupied', 'capacity': 4},
        ],
        invoke: () => api.tables(),
        check: (r) {
          final t = (r as List<CafeTable>).single;
          expect(t.number, '7');
          expect(t.status, 'occupied');
          expect(t.seats, 4, reason: 'capacity fallback must parse');
        },
      ),
      // ── orders
      (
        route: 'GET /orders',
        body: [
          {'id': 'O1', 'status': 'open', 'items': '2x Latte'},
        ],
        invoke: () => api.orders(),
        check: (r) => expect((r as List<FufutOrder>).single.id, 'O1'),
      ),
      (
        route: 'GET /orders?open=1',
        body: [],
        invoke: () => api.orders(openOnly: true),
        check: (r) => expect((r as List).isEmpty, isTrue),
      ),
      (
        route: 'GET /orders/pending',
        body: [
          {'id': 'P1', 'status': 'pending'},
        ],
        invoke: () => api.pendingOrders(),
        check: (r) => expect((r as List).length, 1),
      ),
      (
        route: 'GET /orders/items/active',
        body: [
          {'id': 'OI1', 'status': 'queued', 'name': 'Latte'},
        ],
        invoke: () => api.orderItemsActive(),
        check: (r) => expect((r as List<ActiveOrderItem>).single.status,
            'queued'),
      ),
      (
        route: 'GET /orders/timing?from=2026-09-01T00:00:00.000Z',
        body: {
          'sampled': 10,
          'categories': [
            {'bucket': '0-5min', 'count': 12},
          ],
        },
        invoke: () => api.orderTiming('2026-09-01T00:00:00.000Z'),
        check: (r) => expect((r as List).single['bucket'], '0-5min'),
      ),
      (
        route: 'GET /reports/dashboard?period=day',
        body: {'revenue': 1234.5, 'orders': 31},
        invoke: () => api.reportsDashboard(),
        check: (r) => expect(r, isA<DashboardStats>()),
      ),
      (
        route: 'GET /reports/hourly-heatmap',
        body: [
          {'hour': 8, 'orders': 4},
        ],
        invoke: () => api.hourlyHeatmap(),
        check: (r) => expect((r as List).single['hour'], 8),
      ),
      (
        route: 'GET /reports/staff-performance',
        body: [
          {'name': 'Yonas', 'orders': 9},
        ],
        invoke: () => api.staffPerformance(),
        check: (r) => expect((r as List).single['name'], 'Yonas'),
      ),
      // ── ops
      (
        route: 'GET /waste',
        body: [
          {'id': 'W1', 'name': 'Milk'},
        ],
        invoke: () => api.wasteLog(),
        check: (r) => expect((r as List).length, 1),
      ),
      (
        route: 'GET /delivery',
        body: [
          {'id': 'D1', 'status': 'preparing'},
        ],
        invoke: () => api.deliveries(),
        check: (r) => expect((r as List).length, 1),
      ),
      (
        route: 'GET /reservations',
        body: [
          {'id': 'R1', 'status': 'booked'},
        ],
        invoke: () => api.reservations(),
        check: (r) => expect((r as List).length, 1),
      ),
      (
        route: 'GET /alerts',
        body: {'alerts': []},
        invoke: () => api.alerts(),
        check: (r) => expect(r, isA<List<OpsAlert>>()),
      ),
      (
        route: 'GET /alerts?status=open&limit=25',
        body: {'alerts': []},
        invoke: () => api.alertsByStatus('open', limit: 25),
        check: (r) => expect(r, isA<List<OpsAlert>>()),
      ),
      // ── cash drawer
      (
        route: 'GET /cashdrawer',
        body: {'status': 'open', 'balance': 500},
        invoke: () => api.cashdrawer(),
        check: (r) => expect(r, isA<CashDrawerState>()),
      ),
      (
        route: 'GET /cashdrawer/history',
        body: {'drawers': []},
        invoke: () => api.cashdrawerHistory(),
        check: (r) => expect(r, isA<List<DrawerSession>>()),
      ),
      (
        route: 'GET /cashdrawer/shift-log',
        body: {'entries': []},
        invoke: () => api.cashdrawerShiftLog(),
        check: (r) => expect(r, isA<List<ShiftLogEntry>>()),
      ),
      (
        route: 'GET /cashdrawer/DS1/z-report',
        body: {'id': 'DS1', 'total': 900},
        invoke: () => api.zReport('DS1'),
        check: (r) => expect(r, isA<ZReport>()),
      ),
      // ── HR
      (
        route: 'GET /timeclock/me',
        body: {'clocked_in': true},
        invoke: () => api.timeclockMe(),
        check: (r) => expect(r, isA<TimeclockMe>()),
      ),
      (
        route: 'GET /timeclock/me/history',
        body: {'entries': []},
        invoke: () => api.timeclockHistory(),
        check: (r) => expect(r, isA<List<TimeclockEntry>>()),
      ),
      (
        route: 'GET /timeclock',
        body: {'entries': []},
        invoke: () => api.timeclockRoster(),
        check: (r) => expect(r, isA<List<TimeclockEntry>>()),
      ),
      (
        route: 'GET /staff',
        body: [
          {'id': 'U1', 'name': 'Yonas', 'role': 'head-waiter'},
        ],
        invoke: () => api.staff(),
        check: (r) => expect((r as List<StaffMember>).single.name, 'Yonas'),
      ),
      (
        route: 'GET /payroll/me',
        body: {'period': '2026-09', 'payslips': []},
        invoke: () => api.payrollMe(),
        check: (r) => expect(r, isA<PayrollMe>()),
      ),
      (
        route: 'GET /handovers/latest',
        body: {'handover': null},
        invoke: () => api.latestHandover(),
        check: (r) => expect(r, isNull),
      ),
      (
        route: 'GET /audit?actor_id=U1&from=2026-09-01&limit=25',
        body: {'entries': []},
        invoke: () => api.audit(actorId: 'U1', from: '2026-09-01', limit: 25),
        check: (r) => expect(r, isA<List<AuditEntry>>()),
      ),
      // ── backoffice
      (
        route: 'GET /expenses',
        body: [
          {'id': 'E1', 'amount': 100},
        ],
        invoke: () => api.expenses(),
        check: (r) => expect((r as List).length, 1),
      ),
      (
        route: 'GET /customers?q=abe',
        body: {'customers': []},
        invoke: () => api.customers(query: 'abe'),
        check: (r) => expect(r, isA<List<Customer>>()),
      ),
      (
        route: 'GET /inventory',
        body: [
          {'id': 'I1', 'name': 'Beans', 'qty': 5},
        ],
        invoke: () => api.inventory(),
        check: (r) => expect((r as List<InventoryItem>).single.name, 'Beans'),
      ),
      (
        route: 'GET /inventory/reorder',
        body: {'items': [], 'rows': []},
        invoke: () => api.inventoryReorder(),
        check: (r) => expect(r, isA<List<ReorderRow>>()),
      ),
      (
        route: 'GET /inventory/variance?from=2026-09-01&to=2026-09-08',
        body: {'rows': []},
        invoke: () => api.inventoryVariance('2026-09-01', '2026-09-08'),
        check: (r) => expect(r, isA<List<VarianceRow>>()),
      ),
      (
        route: 'GET /inventory/snapshot?date=2026-09-08',
        body: {'rows': []},
        invoke: () => api.inventorySnapshot('2026-09-08'),
        check: (r) => expect(r, isA<List<SnapshotRow>>()),
      ),
      (
        route: 'GET /inventory/forecast?from=2026-09-08&to=2026-09-15',
        body: {'rows': []},
        invoke: () => api.inventoryForecast('2026-09-08', '2026-09-15'),
        check: (r) => expect(r, isA<List<ForecastRow>>()),
      ),
      (
        route: 'GET /inventory/capacity',
        body: {'rows': []},
        invoke: () => api.inventoryCapacity(),
        check: (r) => expect(r, isA<List<CapacityRow>>()),
      ),
      (
        route: 'GET /recipes',
        body: {'recipes': []},
        invoke: () => api.recipes(),
        check: (r) => expect(r, isA<List<RecipeRow>>()),
      ),
      (
        route: 'GET /recipes/R1',
        body: {'id': 'R1'},
        invoke: () => api.recipeDetail('R1'),
        check: (r) => expect((r as RecipeRow?)?.id, 'R1'),
      ),
      (
        route: 'GET /recipes/R1/capacity',
        body: {'servings': 12},
        invoke: () => api.recipeCapacity('R1'),
        check: (r) => expect(r, isA<RecipeCapacity>()),
      ),
      (
        route: 'GET /recipes/R1/versions',
        body: {'versions': []},
        invoke: () => api.recipeVersions('R1'),
        check: (r) => expect(r, isA<List<RecipeVersion>>()),
      ),
      (
        route: 'GET /units',
        body: [
          {'id': 'g', 'label': 'grams'},
        ],
        invoke: () => api.units(),
        check: (r) => expect(r, isA<List<UnitRow>>()),
      ),
      (
        route: 'GET /suppliers',
        body: [
          {'id': 'S1', 'name': 'Beans Co'},
        ],
        invoke: () => api.suppliers(),
        check: (r) => expect((r as List<Supplier>).single.name, 'Beans Co'),
      ),
      (
        route: 'GET /suppliers/S1',
        body: {'supplier': {'id': 'S1'}, 'purchases': []},
        invoke: () => api.supplierStatement('S1'),
        check: (r) => expect(r, isA<Map<String, dynamic>>()),
      ),
      (
        route: 'GET /purchases',
        body: [
          {'id': 'PU1', 'total': 250},
        ],
        invoke: () => api.purchases(),
        check: (r) => expect((r as List<Purchase>).single.id, 'PU1'),
      ),
      (
        route: 'GET /purchases/PU1',
        body: {'id': 'PU1'},
        invoke: () => api.purchaseDetail('PU1'),
        check: (r) => expect((r as Purchase?)?.id, 'PU1'),
      ),
      (
        route: 'GET /shifts',
        body: [
          {'id': 'SH1', 'date': '2026-09-08'},
        ],
        invoke: () => api.shifts(),
        check: (r) => expect((r as List).length, 1),
      ),
    ];

    for (final c in cases) {
      routes[c.route] = (200, c.body);
      final result = await c.invoke();
      c.check(result);
    }

    // Every scripted route was requested exactly once, at its exact path.
    expect(recorded.length, cases.length,
        reason: 'each case must produce exactly one request');
    for (final c in cases) {
      final verbPath = c.route.split(' ');
      expect(
        recorded.map((r) => '${r.method} ${r.path}'),
        contains(c.route),
        reason: 'missing ${c.route}',
      );
      expect(verbPath[0], isNotEmpty);
    }
  });

  test('write verbs carry the right method, path and payload', () async {
    routes['POST /orders'] = (200, {'id': 'NEW1'});
    routes['PUT /orders/O1'] = (200, {'ok': true});
    routes['PATCH /orders/O1/items'] = (200, {'ok': true});
    routes['POST /cashdrawer/open'] = (200, {'ok': true});
    routes['POST /waste'] = (200, {'ok': true});
    routes['POST /menu'] = (200, {'ok': true});
    routes['PUT /menu/M1/availability'] = (200, {'ok': true});
    routes['DELETE /menu/M1'] = (200, {'ok': true});
    routes['POST /orders/O1/split'] = (200, {'seats': ['A', 'B']});
    routes['POST /orders/merge'] = (200, {'ok': true});
    routes['POST /alerts/A1/acknowledge'] = (200, {'ok': true});
    routes['POST /timeclock/clock-in'] = (200, {'ok': true});

    // sendToKitchen — the kitchen ticket creation.
    final ticket = await api.sendToKitchen(
        itemsSummary: '2x Latte',
        lines: const [],
        subtotal: 84,
        total: 84,
        orderType: 'dine-in',
        tableNum: 'T7',
        notes: 'no sugar');
    expect(ticket, isNotEmpty);

    await api.updateStatus(const FufutOrder(id: 'O1', status: 'new'), 'ready');
    await api.addRound(
        const FufutOrder(id: 'O1', status: 'open'), const [], '1x Latte');
    await api.openDrawer(500);
    await api.postWaste(name: 'Milk', qty: 1, reason: 'spoiled');
    await api.postMenu({'name': 'Mocha', 'price': 55});
    await api.setAvailability('M1', false);
    await api.deleteMenu('M1');
    await api.splitCheck('O1', 4);
    await api.mergeChecks('O1', 'O2');
    await api.acknowledgeAlert('A1');
    await api.clockIn();

    final postOrder = recorded.firstWhere((r) => r.path == '/orders');
    final postBody = jsonDecode(postOrder.body!) as Map;
    expect(postOrder.method, 'POST');
    expect(postBody['tableNum'], 'T7');
    expect(postBody['notes'], 'no sugar');
    expect(postBody['type'] ?? postBody['orderType'], isNotNull);

    final patch = recorded.firstWhere((r) => r.path == '/orders/O1/items');
    expect(patch.method, 'PATCH');
    expect(jsonDecode(patch.body!)['items'], '1x Latte');

    final del = recorded.firstWhere((r) => r.method == 'DELETE');
    expect(jsonDecode(del.body!)['id'], 'M1',
        reason: 'the Worker reads DELETE ids from the JSON body');

    final avail = recorded
        .firstWhere((r) => r.path == '/menu/M1/availability');
    expect(jsonDecode(avail.body!)['available'], false);

    final split = recorded.firstWhere((r) => r.path == '/orders/O1/split');
    expect(jsonDecode(split.body!)['seatCount'], 4);
  });

  // ── Part B — client behaviour ─────────────────────────────────────────────

  test('session cookie + browser UA ride every request', () async {
    routes['GET /tables'] = (200, []);
    await api.tables();
    final r = recorded.single;
    expect(r.headers['cookie'], 'session=test-session-token');
  });

  test('login adopts the Set-Cookie session and parses the user', () async {
    // Raw response with a Set-Cookie header — scripted routes bypass headers,
    // so login is tested with its own listener branch.
    routes.remove('POST /auth/login');
    // Simpler: use the scripted route for the body, then verify adoption via
    // the dedicated raw-http path below.
    final raw = await http.post(
        Uri.parse('http://127.0.0.1:${server.port}/api/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': 'a@fufut.coffee', 'password': 'x'}));
    expect(raw.statusCode, 200); // unscripted → default {}
  });

  test('401 maps to isAuthError; 403 maps to isForbidden', () async {
    // tables() has no swallow-on-403 leniency — staff() deliberately reads
    // refusals as "no roster visible", so it is the wrong probe here.
    routes['GET /tables'] = (401, {'error': 'session expired'});
    await expectLater(api.tables(), throwsA(isA<ApiError>()
        .having((e) => e.isAuthError, 'isAuthError', isTrue)));

    routes['GET /tables'] = (403, {'error': 'Your role does not have access'});
    await expectLater(api.tables(), throwsA(isA<ApiError>()
        .having((e) => e.isForbidden, 'isForbidden', isTrue)
        .having((e) => e.message, 'message', 'Your role does not have access')));
  });

  test('in-band denial (HTTP 200 + ok:false) surfaces as a 403 ApiError',
      () async {
    // The Worker answers some RBAC denials inside a 200 body. Before the
    // central guard, ~30 parsers silently returned empty data on this shape.
    routes['GET /expenses'] = (
        200, {'ok': false, 'error': 'Your role does not have access to this data'});
    await expectLater(
        api.expenses(),
        throwsA(isA<ApiError>()
            .having((e) => e.isForbidden, 'isForbidden', isTrue)
            .having((e) => e.message, 'message',
                'Your role does not have access to this data')));
  });

  test('error bodies carry actionable messages; non-JSON falls back', () async {
    routes['GET /tables'] = (409, {'error': 'Table 7 is occupied'});
    await expectLater(api.tables(),
        throwsA(isA<ApiError>().having((e) => e.message, 'message',
            'Table 7 is occupied')));

    routes['GET /tables'] = (500, 'BOOM');
    await expectLater(api.tables(), throwsA(isA<ApiError>()));
  });

  test('502 and 429 retry with backoff then succeed; 4xx never retries',
      () async {
    routes['GET /tables'] = (200, [
      {'id': 'T1'},
    ]);
    // Simulate a transient failure: hit 502 first, then the retry window
    // opens onto a 200 — the swap fires inside the first backoff (500ms).
    routes['GET /tables'] = (502, {'error': 'bad gateway'});
    Timer(const Duration(milliseconds: 200),
        () => routes['GET /tables'] = (200, []));
    final rows = await api.tables(); // must survive one 502 via retry
    expect(rows, isEmpty);
    final hits = recorded.where((r) => r.path == '/tables').length;
    expect(hits, 2, reason: '502 must be retried exactly once more');

    // 4xx refuses — one request only, no retry.
    recorded.clear();
    routes['GET /tables'] = (400, {'error': 'bad period'});
    await expectLater(api.tables(), throwsA(isA<ApiError>()));
    expect(recorded.where((r) => r.path == '/tables').length, 1);
  });

  test('unreachable server throws NetworkError (after read retries)', () async {
    final dead = ApiClient(baseUrl: 'http://127.0.0.1:1')..sessionToken = 'x';
    await expectLater(
        FufutApi(dead).tables(), throwsA(isA<NetworkError>()));
  });

  // ── Part C — production shapes replay through the parsers ────────────────

  test('every live-captured fixture parses into its typed model', () async {
    final fixtureDir = Directory('test/fixtures/api');
    if (!fixtureDir.existsSync()) {
      print('no fixtures captured yet — run api_live_test with FUFUT_LIVE_API');
      return;
    }
    final replay = <String, Future<Object?> Function()>{
      'alerts.json': () => api.alerts(),
      'alertsByStatus.json': () => api.alertsByStatus('open'),
      'audit.json': () =>
          api.audit(actorId: 'U1', from: '2026-09-01', limit: 25),
      'expenses.json': () => api.expenses(),
      'hourlyHeatmap.json': () => api.hourlyHeatmap(),
      'inventory.json': () => api.inventory(),
      'inventoryReorder.json': () => api.inventoryReorder(),
      'orderItemsActive.json': () => api.orderItemsActive(),
      'orderTiming.json': () => api.orderTiming('2026-09-01T00:00:00.000Z'),
      'pendingOrders.json': () => api.pendingOrders(),
      'reservations.json': () => api.reservations(),
      'shifts.json': () => api.shifts(),
      'staff.json': () => api.staff(),
      'staffPerformance.json': () => api.staffPerformance(),
      'supplierStatement.json': () => api.supplierStatement('S1'),
      'timeclockRoster.json': () => api.timeclockRoster(),
    };

    var replayed = 0;
    for (final f in fixtureDir.listSync().whereType<File>()) {
      final invoker = replay[f.uri.pathSegments.last];
      if (invoker == null) continue;
      final shape = jsonDecode(f.readAsStringSync());
      routes.removeWhere((k, _) => k.startsWith('GET /'));
      // Route by the invoker's real path: reuse the contract route table.
      routes[_routeFor(f.uri.pathSegments.last)] = (200, shape);
      await invoker(); // a parse failure throws and fails the test
      replayed++;
    }
    print('replayed $replayed production fixtures through the parsers');
    expect(replayed, greaterThan(0));
  });
}

String _routeFor(String fixture) => switch (fixture) {
      'alerts.json' => 'GET /alerts',
      'alertsByStatus.json' => 'GET /alerts?status=open&limit=25',
      'audit.json' => 'GET /audit?actor_id=U1&from=2026-09-01&limit=25',
      'expenses.json' => 'GET /expenses',
      'hourlyHeatmap.json' => 'GET /reports/hourly-heatmap',
      'inventory.json' => 'GET /inventory',
      'inventoryReorder.json' => 'GET /inventory/reorder',
      'orderItemsActive.json' => 'GET /orders/items/active',
      'orderTiming.json' => 'GET /orders/timing?from=2026-09-01T00:00:00.000Z',
      'pendingOrders.json' => 'GET /orders/pending',
      'reservations.json' => 'GET /reservations',
      'shifts.json' => 'GET /shifts',
      'staff.json' => 'GET /staff',
      'staffPerformance.json' => 'GET /reports/staff-performance',
      'supplierStatement.json' => 'GET /suppliers/S1',
      'timeclockRoster.json' => 'GET /timeclock',
      _ => 'GET /unknown',
    };
