// Live end-to-end probe for the full-parity release: signs in with real
// staff accounts and hits EVERY new endpoint the parity screens use,
// proving the API surface wiring (paths, parsing, refusal handling) before
// the tag goes out.
//
//   dart run tool/parity_smoke.dart
// ignore_for_file: avoid_print
import 'package:fufut_pos/api/api_client.dart';
import 'package:fufut_pos/api/fufut_api.dart';

Future<void> main() async {
  const base = 'https://fufut-api.fufutcoffee.workers.dev';
  var failures = 0;

  void check(String name, bool ok, [String detail = '']) {
    print('${ok ? "PASS" : "FAIL"}  $name${detail.isEmpty ? "" : " — $detail"}');
    if (!ok) failures++;
  }

  // ── Head chef: the stock chain + reports extras ──────────────────────────
  {
    final client = ApiClient(baseUrl: base);
    final api = FufutApi(client);
    final session = await api.login('selam@fufut.coffee', 'selam@336');
    check('chef login', session.user.id.isNotEmpty, 'role=${session.user.role}');

    final inv = await api.inventory();
    check('GET inventory', inv.isNotEmpty, '${inv.length} items');
    check('inventory minLevel parses',
        inv.any((i) => i.minLevel >= 0));

    final recipes = await api.recipes();
    check('GET recipes', recipes.isNotEmpty, '${recipes.length} rows');
    if (recipes.isNotEmpty) {
      final cap = await api.recipeCapacity(recipes.first.id);
      check('GET recipes/:id/capacity', true, '${cap.servings} servings');
      final versions = await api.recipeVersions(recipes.first.id);
      check('GET recipes/:id/versions', versions.isNotEmpty,
          'v${versions.firstOrNull?.version}');
    }
    final units = await api.units();
    check('GET units', units.isNotEmpty, '${units.length} units');

    final reorder = await api.inventoryReorder();
    check('GET inventory/reorder', true, '${reorder.length} rows');
    final variance = await api.inventoryVariance(
        '2026-09-14T00:00:00.000Z', '2026-09-21T23:59:59.999Z');
    check('GET inventory/variance', true, '${variance.length} rows');
    final snapshot = await api.inventorySnapshot('2026-09-20');
    check('GET inventory/snapshot', true, '${snapshot.length} rows');
    final forecast = await api.inventoryForecast(
        '2026-09-14T00:00:00.000Z', '2026-09-21T23:59:59.999Z');
    check('GET inventory/forecast', true, '${forecast.length} rows');
    final capacity = await api.inventoryCapacity();
    check('GET inventory/capacity', true, '${capacity.length} rows');

    final sups = await api.suppliers();
    check('GET suppliers', sups.isNotEmpty, '${sups.length} rows');
    if (sups.isNotEmpty) {
      final st = await api.supplierStatement(sups.first.id);
      check('GET suppliers/:id (statement)', st != null);
    }
    final purchases = await api.purchases();
    check('GET purchases', purchases.isNotEmpty, '${purchases.length} rows');

    final shifts = await api.shifts();
    check('GET shifts', true, '${shifts.length} rows');
    final staff = await api.staff();
    check('GET staff', staff.isNotEmpty, '${staff.length} rows');

    final perf = await api.staffPerformance();
    check('GET reports/staff-performance', perf.isNotEmpty,
        '${perf.length} rows');
    final heat = await api.hourlyHeatmap();
    check('GET reports/hourly-heatmap', true, '${heat.length} rows');

    // Menu-86 write grant (toggle + restore, chef-permitted).
    final menu = await api.menu();
    if (menu.isNotEmpty) {
      final item = menu.first;
      await api.setAvailability(item.id, !item.available);
      await api.setAvailability(item.id, item.available);
      check('PUT menu/:id/availability (chef toggle+restore)', true,
          item.name);
    }

    // Chef must NOT be able to write suppliers (web grant: read-only).
    try {
      await api.postSupplier({'name': 'X'});
      check('POST suppliers refuses for chef', false, 'server accepted it!');
    } on ApiError catch (e) {
      check('POST suppliers refuses for chef', e.isForbidden, '${e.status}');
    }
  }

  // ── Head waiter: reservations book + refuse paths ────────────────────────
  {
    final client = ApiClient(baseUrl: base);
    final api = FufutApi(client);
    final session = await api.login('yonas@fufut.coffee', 'selam@336');
    check('waiter login', session.user.id.isNotEmpty,
        'role=${session.user.role}');

    final rows = await api.reservations();
    check('GET reservations', rows.isNotEmpty, '${rows.length} rows');

    final avail = await api.reservationAvailability('2026-12-24', '19:00', 90);
    check('GET reservations/availability', true, '${avail.length} taken');

    final past = DateTime.now().add(const Duration(days: -30));
    String pad(int v) => v.toString().padLeft(2, '0');
    final pastDay =
        '${past.year}-${pad(past.month)}-${pad(past.day)}';
    try {
      await api.postReservation(
          name: 'Parity Smoke',
          guests: 2,
          date: pastDay,
          time: '23:00',
          tableNum: '1');
      check('POST reservations (past slot) refused', false,
          'server accepted a past booking');
    } on ApiError catch (e) {
      check('POST reservations refusal surfaces message',
          e.message.isNotEmpty, '"${e.message}"');
    }

    final audit = await api.auditFiltered(from: '2026-09-21T00:00:00');
    check('GET audit (actor-scoped)', audit.isNotEmpty,
        '${audit.length} entries');

    // The waiter must not reach inventory (web grant leaves it off).
    try {
      await api.client.get('inventory');
      check('GET inventory refuses for head-waiter', false, 'accepted!');
    } on ApiError catch (e) {
      check('GET inventory refuses for head-waiter', e.isForbidden,
          '${e.status}');
    }
  }

  print(failures == 0 ? '\nALL PARITY PROBES PASS' : '\n$failures FAILURES');
}
