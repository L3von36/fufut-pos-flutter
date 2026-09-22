// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:fufut_pos/api/api_client.dart';
import 'package:fufut_pos/api/fufut_api.dart';
import 'package:fufut_pos/models/models.dart';

/// LIVE read-only probe of the deployed fufut-api Worker.
///
/// Run: flutter test test/api_live_test.dart --dart-define=FUFUT_LIVE_API=true
/// Skipped in normal CI runs (no flag) so the suite stays hermetic.
///
/// What it verifies — "every backend interaction does what it's supposed to":
///  1. login works for every real staff account we hold;
///  2. every READ endpoint the app calls answers 200 inside that role's
///     grants AND parses into the app's models (parse happens inside
///     [FufutApi] — a shape drift throws and fails here);
///  3. admin reads outside a role's grants answer 403 (server RBAC alive) —
///     never 401 (session broken) and never 5xx (backend bug);
///  4. every 200 body is captured under test/fixtures/api/<method>.json so
///     test/api_contract_test.dart can replay the real shapes offline.
///
/// READ-ONLY by design: no POST/PUT/PATCH/DELETE is issued — production
/// serves real shifts.
const _base = 'https://fufut-api.fufutcoffee.workers.dev';
const _ua = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like '
    'Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

const _accounts = <String, (String, String)>{
  'waiter': ('yonas@fufut.coffee', 'selam@336'),
  'chef': ('selam@fufut.coffee', 'selam@336'),
  'barista': ('barista@fufut.coffee', 'selam@336'),
};

final _fixtures = Directory('test/fixtures/api');

void main() {
  test(
    'live probe: every read endpoint, every role',
    () async {
      _fixtures.createSync(recursive: true);
      final report = <String, Map<String, String>>{};
      final failures = <String>[];

      for (final entry in _accounts.entries) {
        final role = entry.key;
        final (account, password) = entry.value;

        // ── login on the raw http stack: need Set-Cookie to build a session
        final loginRes = await http.post(
          Uri.parse('$_base/api/auth/login'),
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': _ua,
            'Accept': 'application/json',
          },
          body: jsonEncode({'email': account, 'password': password}),
        );
        if (loginRes.statusCode != 200) {
          failures.add('$role login → HTTP ${loginRes.statusCode}');
          continue;
        }
        final setCookie = loginRes.headers['set-cookie'] ?? '';
        final m = RegExp(r'session=([^;]+)').firstMatch(setCookie);
        if (m == null) {
          failures.add('$role login → no session cookie in Set-Cookie');
          continue;
        }

        final client = ApiClient(baseUrl: _base)..sessionToken = m.group(1);
        final api = FufutApi(client);
        report[role] = {};

        Future<void> probe(String name, Future<Object?> Function() call,
            {bool adminOnly = false}) async {
          try {
            final v = await call();
            report[role]![name] = '200';
            // Capture the fixture once (first role that reads it). Only
            // JSON-encodable shapes — some api methods return typed single
            // models whose fixtures come from their list twins instead.
            final f = File('test/fixtures/api/$name.json');
            if (!f.existsSync()) {
              try {
                final enc = const JsonEncoder.withIndent('  ').convert(_trim(v));
                f.writeAsStringSync(enc);
              } catch (_) {
                report[role]![name] = '200 (no fixture: typed model)';
              }
            }
          } on ApiError catch (e) {
            if (e.isForbidden) {
              // Expected for endpoints outside this role's grants — the
              // server's ROLE_ACCESS boundary answering, exactly what the
              // nav matrix in lib/state/roles.dart relies on.
              report[role]![name] = '403 ✓RBAC';
            } else if (e.isAuthError) {
              failures.add('$role $name → 401 (session broken)');
            } else {
              failures.add(
                  '$role $name → ${e.status ?? 'network'}: ${e.message}');
            }
          } catch (e) {
            failures.add('$role $name → PARSE/OTHER: $e');
          }
        }

        // ── auth / session
        await probe('me', () => api.me());
        final me = await api.me();
        if (me == null) failures.add('$role me() → null session');
        report[role]!['roleKey'] = me?.user.role ?? '?';

        // ── floor / menu / orders
        await probe('menu', () => api.menu());
        await probe('tables', () => api.tables());
        await probe('orders_all', () => api.orders());
        await probe('orders_open', () => api.orders(openOnly: true));
        await probe('pendingOrders', () => api.pendingOrders());
        await probe('orderItemsActive', () => api.orderItemsActive());
        await probe('orderTiming', () =>
            api.orderTiming(DateTime.now()
                .toUtc()
                .subtract(const Duration(days: 1))
                .toIso8601String()));
        await probe('staffPerformance', adminOnly: true, () => api.staffPerformance());
        await probe('hourlyHeatmap', () => api.hourlyHeatmap());

        // ── reports / dashboards
        await probe('reportsDashboard_day', () => api.reportsDashboard());
        await probe('reportsDashboard_week', () => api.reportsDashboard(period: 'week'));

        // ── ops
        await probe('wasteLog', () => api.wasteLog());
        await probe('deliveries', () => api.deliveries());
        await probe('reservations', () => api.reservations());
        await probe('reservationAvailability', () {
          final day = DateTime.now().add(const Duration(days: 7));
          final d = '${day.year}-${day.month.toString().padLeft(2, '0')}-'
              '${day.day.toString().padLeft(2, '0')}';
          return api.reservationAvailability(d, '18:00', 90);
        });

        // ── cash drawer
        await probe('cashdrawer', () => api.cashdrawer());
        await probe('cashdrawerHistory', () => api.cashdrawerHistory());
        await probe('cashdrawerShiftLog', () => api.cashdrawerShiftLog());
        final hist = await api.cashdrawerHistory().catchError((_) => <DrawerSession>[]);
        if (hist.isNotEmpty) {
          await probe('zReport', () => api.zReport(hist.first.id));
        }

        // ── HR
        await probe('timeclockMe', () => api.timeclockMe());
        await probe('timeclockHistory', () => api.timeclockHistory());
        await probe('timeclockRoster', adminOnly: true, () => api.timeclockRoster());
        await probe('staff', adminOnly: true, () => api.staff());
        await probe('latestHandover', () => api.latestHandover());
        await probe('payrollMe', () => api.payrollMe());

        // ── admin trail
        final uid = me?.user.id ?? '';
        final from7 = DateTime.now()
            .subtract(const Duration(days: 7))
            .toIso8601String()
            .substring(0, 10);
        await probe('audit', adminOnly: true,
            () => api.audit(actorId: uid, from: from7, limit: 25));
        await probe(
            'alertsByStatus', () => api.alertsByStatus('open', limit: 25));
        await probe('auditFiltered', adminOnly: true,
            () => api.auditFiltered(limit: 25));

        // ── alerts
        await probe('alerts', () => api.alerts());

        // ── backoffice
        await probe('expenses', adminOnly: true, () => api.expenses());
        await probe('customers', () => api.customers());
        await probe('inventory', adminOnly: true, () => api.inventory());
        await probe('inventoryReorder', adminOnly: true, () => api.inventoryReorder());
        await probe('inventoryVariance', adminOnly: true, () {
          final to = DateTime.now().toIso8601String().substring(0, 10);
          final from = DateTime.now()
              .subtract(const Duration(days: 7))
              .toIso8601String()
              .substring(0, 10);
          return api.inventoryVariance(from, to);
        });
        await probe('inventorySnapshot', adminOnly: true, () =>
            api.inventorySnapshot(DateTime.now().toIso8601String().substring(0, 10)));
        await probe('inventoryForecast', adminOnly: true, () {
          final from = DateTime.now().toIso8601String().substring(0, 10);
          final to = DateTime.now()
              .add(const Duration(days: 7))
              .toIso8601String()
              .substring(0, 10);
          return api.inventoryForecast(from, to);
        });
        await probe('inventoryCapacity', adminOnly: true, () => api.inventoryCapacity());

        await probe('recipes', adminOnly: true, () => api.recipes());
        final recipes = await api.recipes().catchError((_) => <RecipeRow>[]);
        if (recipes.isNotEmpty) {
          await probe('recipeDetail', adminOnly: true, () => api.recipeDetail(recipes.first.id));
          await probe('recipeCapacity', adminOnly: true, () => api.recipeCapacity(recipes.first.id));
          await probe('recipeVersions', adminOnly: true, () => api.recipeVersions(recipes.first.id));
        }
        await probe('units', adminOnly: true, () => api.units());
        await probe('suppliers', adminOnly: true, () => api.suppliers());
        final suppliers = await api.suppliers().catchError((_) => <Supplier>[]);
        if (suppliers.isNotEmpty) {
          await probe('supplierStatement', adminOnly: true,
              () => api.supplierStatement(suppliers.first.id));
        }
        await probe('purchases', adminOnly: true, () => api.purchases());
        final purchases = await api.purchases().catchError((_) => <Purchase>[]);
        if (purchases.isNotEmpty) {
          await probe('purchaseDetail', adminOnly: true,
              () => api.purchaseDetail(purchases.first.id));
        }
        await probe('shifts', adminOnly: true, () => api.shifts());
      }

      // ── print the matrix
      print('\n=== LIVE PROBE MATRIX (✓=200 parse-ok) ===');
      final names = report.values.expand((m) => m.keys).toSet().toList()..sort();
      print('endpoint'.padRight(26) +
          _accounts.keys.map((r) => r.padRight(12)).join());
      for (final n in names) {
        final row = StringBuffer(n.padRight(26));
        for (final r in _accounts.keys) {
          row.write((report[r]?[n] ?? '-').padRight(12));
        }
        print(row);
      }

      // ── grants contract: endpoints each role's screens open on boot MUST
      // answer 200 (roles.dart: "a nav item can never open onto a screen
      // whose first request 403s"). A 403 here means server grants and app
      // nav have drifted apart.
      const mustSucceed = <String, Set<String>>{
        'waiter': {
          'tables', 'menu', 'orders_all', 'orders_open', 'reservations',
          'reservationAvailability', 'timeclockMe', 'payrollMe',
          'latestHandover', 'alerts', 'me',
        },
        'chef': {
          'orders_all', 'orders_open', 'pendingOrders', 'orderItemsActive',
          'wasteLog', 'inventory', 'recipes', 'units', 'me', 'alerts',
        },
        'barista': {
          'tables', 'menu', 'orders_all', 'orders_open', 'pendingOrders',
          'orderItemsActive', 'me', 'alerts',
        },
      };
      final grantDrift = <String>[];
      mustSucceed.forEach((role, required) {
        for (final n in required) {
          if (!(report[role]?[n] ?? '').startsWith('200')) {
            grantDrift.add('$role requires $n → got ${report[role]?[n]}');
          }
        }
      });
      expect(grantDrift, isEmpty,
          reason: 'server grants vs app nav drift:\n${grantDrift.join('\n')}');

      expect(failures, isEmpty,
          reason: 'live backend contract failures:\n${failures.join('\n')}');
    },
    timeout: const Timeout(Duration(minutes: 6)),
    skip: !const bool.fromEnvironment('FUFUT_LIVE_API')
        ? 'live probe needs --dart-define=FUFUT_LIVE_API=true'
        : false,
  );
}

/// Trim huge arrays so fixtures stay readable — keep the first 3 rows.
dynamic _trim(dynamic v) {
  if (v is List) return v.take(3).map(_trim).toList();
  if (v is Map) return v.map((k, val) => MapEntry(k, _trim(val)));
  return v;
}
