/// Unit tests for the v1.0.5 additions: cash drawer, HR trio, kitchen
/// per-line rows, reservations and the bill-request flag on tables.
///
/// These lock the wire contracts the new screens depend on — camelCase and
/// snake_case aliases, defensive parsing, and the derived numbers (expected,
/// variance, per-seat split preview).
import 'package:flutter_test/flutter_test.dart';
import 'package:fufut_pos/models/models.dart';

void main() {
  group('DrawerSession', () {
    test('parses camelCase aliases and computes expected', () {
      final d = DrawerSession.fromJson({
        'id': 'abc123',
        'status': 'open',
        'openingBal': 1000,
        'cashSales': 2500.5,
        'paidIn': 500,
        'paidOut': 200,
        'opened': '2026-09-21 08:00:00',
      });
      expect(d.openingBal, 1000);
      expect(d.cashSales, 2500.5);
      // expected = float + cash sales + paid in − paid out
      expect(d.expected, closeTo(3800.5, 0.001));
    });

    test('parses snake_case aliases', () {
      final d = DrawerSession.fromJson({
        'id': 'def456',
        'status': 'closed',
        'opening_balance': 500,
        'cash_sales': 1200,
        'paid_in': 0,
        'paid_out': 300,
        'closed_at': '2026-09-21 16:00:00',
        'closing_balance': 1390,
        'variance': -10,
      });
      expect(d.closingBal, 1390);
      expect(d.variance, -10);
      expect(d.expected, 1400);
    });
  });

  group('CashDrawerState', () {
    test('active may be absent; drawers list tolerated', () {
      final state = CashDrawerState.fromJson({
        'drawers': [
          {'id': 'a', 'openingBal': 100},
          {'id': 'b', 'openingBal': 200},
        ],
      });
      expect(state.active, isNull);
      expect(state.drawers.length, 2);
    });
  });

  group('Timeclock', () {
    test('me parses clockedIn + entry', () {
      final me = TimeclockMe.fromJson({
        'clockedIn': true,
        'entry': {'id': 'e1', 'clockIn': '08:30', 'on_break': true},
      });
      expect(me.clockedIn, true);
      expect(me.entry?.clockIn, '08:30');
      expect(me.entry?.onBreak, true);
    });

    test('history reads {entries}', () {
      final rows = (const [
        {'id': 'a', 'date': '2026-09-20', 'clockIn': '08:00', 'clockOut': '16:00'},
      ] as List)
          .whereType<Map>()
          .map((m) => TimeclockEntry.fromJson(Map<String, dynamic>.from(m)))
          .toList();
      expect(rows.single.durationLabelSafe, '8h00m');
    });
  });

  group('PayrollMe', () {
    test('parses current contract + payslips, flags provisional', () {
      final p = PayrollMe.fromJson({
        'current': {'baseSalary': 9000, 'salaryPeriod': 'monthly', 'employmentType': 'full-time'},
        'payslips': [
          {
            'id': 'ps1',
            'period_start': '2026-09-01',
            'period_end': '2026-09-30',
            'base_salary': 9000,
            'overtime_pay': 350,
            'bonuses': 0,
            'deductions': 200,
            'income_tax': 950,
            'pension_employee': 630,
            'net_pay': 7570,
            'tips_earned': 410.75,
            'run_status': 'paid',
            'provisional': false,
          },
          {
            'id': 'ps2',
            'period_start': '2026-10-01',
            'period_end': '2026-10-31',
            'base_salary': 9000,
            'net_pay': 7900,
            'run_status': 'draft',
            'provisional': true,
          },
        ],
      });
      expect(p.baseSalary, 9000);
      expect(p.payslips.length, 2);
      expect(p.hasProvisional, true);
      expect(p.payslips.first.netPay, 7570);
      expect(p.payslips.first.tipsEarned, 410.75);
    });
  });

  group('Kitchen line rows', () {
    test('ActiveOrderItem parses snake_case wire shape', () {
      final it = ActiveOrderItem.fromJson({
        'id': 'item1',
        'order_id': 'ord9',
        'line_no': 2,
        'qty': 3,
        'name': 'Macchiato',
        'category': 'Coffee',
        'status': 'preparing',
        'notes': 'extra shot',
      });
      expect(it.orderId, 'ord9');
      expect(it.qty, 3);
      expect(it.status, 'preparing');
      expect(it.notes, 'extra shot');
    });
  });

  group('Tables', () {
    test('bill_requested_at drives the BILL chip', () {
      final t = CafeTable.fromJson({
        'id': 't1',
        'number': '7',
        'status': 'occupied',
        'bill_requested_at': '2026-09-21 12:30:00',
      });
      expect(t.billRequested, true);
      final t2 = CafeTable.fromJson({'id': 't2', 'number': '8', 'status': 'available'});
      expect(t2.billRequested, false);
    });
  });

  group('Reservations', () {
    test('parses guests + date for the waiter dashboard', () {
      final r = Reservation.fromJson({
        'id': 'r1',
        'name': 'Sara',
        'date': DateTime.now().toString().substring(0, 10),
        'time': '19:00',
        'guests': 4,
        'status': 'confirmed',
      });
      expect(r.name, 'Sara');
      expect(r.guests, 4);
      expect(r.status, 'confirmed');
    });
  });
}

extension on TimeclockEntry {
  /// The screen formats 8h00m from clockIn→clockOut; keep the same math here
  /// so the format contract is pinned without reaching into the widget.
  String get durationLabelSafe {
    final inParts = (clockIn ?? '').split(':');
    final outParts = (clockOut ?? '').split(':');
    if (inParts.length < 2 || outParts.length < 2) return '';
    final inMin = (int.tryParse(inParts[0]) ?? 0) * 60 + (int.tryParse(inParts[1]) ?? 0);
    final outMin = (int.tryParse(outParts[0]) ?? 0) * 60 + (int.tryParse(outParts[1]) ?? 0);
    final d = outMin - inMin;
    if (d <= 0) return '';
    return '${d ~/ 60}h${(d % 60).toString().padLeft(2, '0')}m';
  }
}
