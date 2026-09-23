import 'package:flutter_test/flutter_test.dart';

import 'package:fufut_pos/models/models.dart';
import 'package:fufut_pos/state/roles.dart';
import 'package:fufut_pos/utils/csv.dart';

/// Locks down the pure logic behind the full-parity release: the web grants
/// matrix, the backoffice model math, and the CSV export shapes.
void main() {
  // ── The grants matrix (web ROLE_PERMISSIONS verbatim) ────────────────────

  test('the HR self-service trio rides for the manager alone', () {
    // Least-privilege pass: an employed team member never sees an HR tab.
    // Clocking in and out still works for every account — the server's
    // self-service routes never consulted the nav — but the screens stay
    // off the staff drawer.
    final managerNav = navForRole('manager').map((e) => e.key).toSet();
    for (final key in kHrNavKeys) {
      expect(managerNav.contains(key), isTrue, reason: 'manager must carry ${key.name}');
    }
    for (final role in kRolePermissions.keys.where((r) => r != 'manager')) {
      final keys = navForRole(role).map((e) => e.key).toSet();
      for (final key in kHrNavKeys) {
        expect(keys.contains(key), isFalse,
            reason: '$role must NOT carry HR tab ${key.name}');
      }
      expect(keys.contains(NavKey.shifts), isFalse,
          reason: '$role must NOT carry the Shifts roster');
    }
    // Settings stays last for everyone.
    for (final role in kRolePermissions.keys) {
      expect(navForRole(role).last.key, NavKey.settings, reason: '$role: Settings last');
    }
  });

  test('least-privilege: staff roles carry only their job screens', () {
    // The owner's call — procurement, stock intelligence, business reporting
    // and the colleague/HR screens are backoffice reading, not line work.
    final chef = kRolePermissions['head-chef']!;
    for (final key in [NavKey.suppliers, NavKey.purchases, NavKey.stockControl, NavKey.reports, NavKey.expenses, NavKey.cashdrawer, NavKey.shifts]) {
      expect(chef.contains(key), isFalse, reason: 'head-chef must not see ${key.name}');
    }
    // Pipeline left the kitchen's nav (owner's call, 2026-09): the board IS
    // the chef's pipeline — the kanban duplicated it ticket-for-ticket.
    for (final key in [NavKey.kitchen, NavKey.orders, NavKey.tables, NavKey.inventory, NavKey.recipes, NavKey.waste, NavKey.menuMgmt]) {
      expect(chef.contains(key), isTrue, reason: 'head-chef lost ${key.name}');
    }
    expect(chef.contains(NavKey.pipeline), isFalse,
        reason: 'pipeline is the manager overview; the chef works the board');
    final cashier = kRolePermissions['cashier']!;
    for (final key in [NavKey.revenue, NavKey.analytics, NavKey.reports, NavKey.expenses, NavKey.pnl]) {
      expect(cashier.contains(key), isFalse, reason: 'cashier must not see ${key.name}');
    }
    // Their own numbers stay: the dashboard and the drawer.
    expect(cashier.contains(NavKey.cashdrawer), isTrue);
    expect(cashier.contains(NavKey.dashboard), isTrue);
    // The assistant cook never saw procurement either.
    final assistant = kRolePermissions['assistant-chef']!;
    expect(assistant.contains(NavKey.suppliers), isFalse);
    expect(assistant.contains(NavKey.purchases), isFalse);
  });

  test('the floor plan belongs to the waiter and the kitchen — not the till', () {
    // Owner's call, 2026-09: the cashier walks no floor (their table work is
    // the Dashboard's Bill Requests card and settling from Open Checks), the
    // kitchen sees the room it cooks for, and the floor keeps its home tab.
    expect(kRolePermissions['cashier']!.contains(NavKey.tables), isFalse,
        reason: 'cashier must not carry the Tables tab');
    expect(kRolePermissions['head-chef']!.contains(NavKey.tables), isTrue,
        reason: 'head-chef needs the floor: bill requests + table turns');
    expect(kRolePermissions['assistant-chef']!.contains(NavKey.tables), isTrue);
    expect(kRolePermissions['head-waiter']!.contains(NavKey.tables), isTrue);
    // The kitchen's floor view is read-shaped: still no money/roster screens.
    expect(kRolePermissions['head-chef']!.contains(NavKey.cashdrawer), isFalse);
  });

  test('action grants: floor orders vs table turns vs party edits', () {
    // Opening a table's ticket is the waiter's job (manager rides along).
    expect(canTakeTableOrders('head-waiter'), isTrue);
    expect(canTakeTableOrders('manager'), isTrue);
    for (final role in ['cashier', 'head-chef', 'assistant-chef', 'barista', 'cleaner', 'delivery-staff', 'accountant']) {
      expect(canTakeTableOrders(role), isFalse,
          reason: '$role must not open a table ticket');
    }
    // Turning a table after the party leaves: floor + kitchen, never the till
    // or the supporting roles.
    for (final role in ['manager', 'head-waiter', 'head-chef', 'assistant-chef']) {
      expect(canFreeTable(role), isTrue, reason: '$role may free a table');
    }
    for (final role in ['cashier', 'barista', 'cleaner', 'delivery-staff']) {
      expect(canFreeTable(role), isFalse, reason: '$role must not free tables');
    }
    // Party edits (status chips, guests, notes): floor leads only.
    expect(canEditTable('manager'), isTrue);
    expect(canEditTable('head-waiter'), isTrue);
    expect(canEditTable('head-chef'), isFalse,
        reason: 'the kitchen floor view is read-shaped');
    expect(canEditTable('cashier'), isFalse);
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
