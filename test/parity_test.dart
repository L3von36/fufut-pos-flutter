import 'package:flutter_test/flutter_test.dart';

import 'package:fufut_pos/models/models.dart';
import 'package:fufut_pos/state/roles.dart';
import 'package:fufut_pos/utils/csv.dart';

/// Locks down the pure logic behind the full-parity release: the web grants
/// matrix, the backoffice model math, and the CSV export shapes.
void main() {
  // ── The grants matrix (web ROLE_PERMISSIONS verbatim) ────────────────────

  test('every role carries the HR self-service trio', () {
    for (final role in kRolePermissions.keys) {
      final nav = navForRole(role);
      for (final key in kHrNavKeys) {
        expect(nav.any((e) => e.key == key), isTrue,
            reason: '$role must carry ${key.name}');
      }
      expect(nav.last.key, NavKey.settings, reason: '$role: Settings last');
    }
  });

  test('role landing screens match the web ROLE_DEFAULT_VIEW', () {
    expect(defaultViewFor('manager'), NavKey.dashboard);
    expect(defaultViewFor('head-chef'), NavKey.kitchen);
    expect(defaultViewFor('assistant-chef'), NavKey.kitchen);
    expect(defaultViewFor('barista'), NavKey.barista);
    expect(defaultViewFor('head-waiter'), NavKey.tables);
    expect(defaultViewFor('cashier'), NavKey.cashdrawer);
    expect(defaultViewFor('delivery-staff'), NavKey.delivery);
    expect(defaultViewFor('cleaner'), NavKey.waste);
    expect(defaultViewFor('accountant'), NavKey.reports);
  });

  test('backoffice grants match the web matrix', () {
    // The manager sees everything; the accountant reads money but writes
    // only expenses; the barista gets drink recipes, never purchases.
    final manager = kRolePermissions['manager']!;
    for (final key in [
      NavKey.menuMgmt, NavKey.inventory, NavKey.purchases, NavKey.recipes,
      NavKey.stockControl, NavKey.suppliers, NavKey.expenses, NavKey.pnl,
      NavKey.revenue, NavKey.analytics, NavKey.pipeline, NavKey.reservations,
      NavKey.alertsDash, NavKey.audit, NavKey.customers, NavKey.shifts,
    ]) {
      expect(manager.contains(key), isTrue, reason: 'manager misses ${key.name}');
    }
    final accountant = kRolePermissions['accountant']!;
    expect(accountant.contains(NavKey.expenses), isTrue);
    expect(accountant.contains(NavKey.orders), isTrue);
    expect(accountant.contains(NavKey.cashdrawer), isFalse);
    expect(accountant.contains(NavKey.inventory), isFalse);
    final barista = kRolePermissions['barista']!;
    expect(barista.contains(NavKey.recipes), isTrue);
    expect(barista.contains(NavKey.purchases), isFalse);
    // Cleaner has no SLA alerts on the web read list — the banner hides too.
    expect(kRolePermissions['cleaner']!.contains(NavKey.alertsDash), isFalse);
    // Head-chef menu grant is the 86 toggle; the screen gates the CRUD.
    expect(kRolePermissions['head-chef']!.contains(NavKey.menuMgmt), isTrue);
  });

  // ── Backoffice model math ────────────────────────────────────────────────

  test('Purchase.owing and Supplier.balance subtract paid from total', () {
    const p = Purchase(id: 'P1', total: 5000, paid: 3200);
    expect(p.owing, 1800);
    const s = Supplier(id: 'S1', total: 12000, paid: 12000);
    expect(s.balance, 0);
  });

  test('RecipeRow falls back to ingredient+packaging when totalCost absent',
      () {
    final r = RecipeRow.fromJson({
      'id': 'R1',
      'ingredientCost': 42.5,
      'packagingCost': 7.5,
      'price': 200,
    });
    expect(r.totalCost, 50);
    expect(r.grossMarginPct, closeTo(75, 0.01));
    // Absent price never divides by zero.
    final r2 = RecipeRow.fromJson({'id': 'R2', 'totalCost': 30});
    expect(r2.grossMarginPct, 0);
  });

  test('VarianceRow derives variance and percentage', () {
    final v = VarianceRow.fromJson({'id': 'V', 'expected': 10, 'actual': 8});
    expect(v.variance, -2);
    expect(v.variancePct, closeTo(-20, 0.01));
  });

  test('InventoryItem.isLow triggers at or below the reorder point', () {
    final low = InventoryItem.fromJson(
        {'id': 'I1', 'stock': 2, 'minLevel': 2});
    final ok = InventoryItem.fromJson(
        {'id': 'I2', 'stock': 3, 'minLevel': 2});
    final noMin = InventoryItem.fromJson({'id': 'I3', 'stock': 0});
    expect(low.isLow, isTrue);
    expect(ok.isLow, isFalse);
    expect(noMin.isLow, isFalse); // no reorder point, no alarm
  });

  test('Reservation parses tableNum and durationMin aliases', () {
    final r = Reservation.fromJson({
      'id': 'B1',
      'name': 'Sara',
      'table_number': '7',
      'duration_min': 120,
    });
    expect(r.tableNum, '7');
    expect(r.durationMin, 120);
  });

  test('InventoryItem parses minLevel from every server alias', () {
    expect(
        InventoryItem.fromJson({'id': 'A', 'minLevel': 5}).minLevel, 5);
    expect(
        InventoryItem.fromJson({'id': 'B', 'min_level': '4'}).minLevel, 4);
    expect(
        InventoryItem.fromJson({'id': 'C', 'reorderPoint': 3}).minLevel, 3);
  });

  test('the nine SLA rules are mirrored for the alerts dashboard', () {
    expect(kAlertRules.length, 9);
    expect(
      kAlertRules.map((r) => r['ruleId']).toSet(),
      containsAll(<String>['order-preparing-too-long', 'order-ready-now',
        'table-seated-too-long']),
    );
  });

  // ── CSV export shapes ────────────────────────────────────────────────────

  test('toCsv quotes commas, quotes and newlines (RFC-4180)', () {
    final csv = toCsv(['A', 'B'], [
      ['plain', 'with,comma'],
      ['with"quote', 'multi\nline'],
    ]);
    expect(csv.startsWith('A,B\nplain,"with,comma"\n'), isTrue);
    // The embedded newline stays inside the quoted cell — the record never
    // breaks across lines.
    expect(csv.contains('"with""quote","multi\nline"\n'), isTrue);
  });

  test('purchaseRows emit one row per item line', () {
    final p = Purchase.fromJson({
      'id': 'P1',
      'date': '2026-09-22',
      'supplierName': 'Sidamo Mills',
      'total': 900,
      'paid': 0,
      'paymentMethod': 'credit',
      'lines': [
        {'name': 'Beans', 'qty': 30, 'unit': 'kg', 'totalCost': 900},
      ],
    });
    final rows = purchaseRows([p]);
    expect(rows.length, 1);
    expect(rows[0][2], 'Beans');
    expect(rows[0][3], 30);
  });

  test('purchaseExportName is a business-day key', () {
    expect(purchaseExportName(DateTime(2026, 9, 2)),
        'purchases-2026-09-02.csv');
  });
}
