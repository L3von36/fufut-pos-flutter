import 'package:flutter_test/flutter_test.dart';

import 'package:fufut_pos/models/models.dart';
import 'package:fufut_pos/state/floor_plan.dart';

/// Unit tests for the floor-plan helpers — the ports of the web POS's
/// tableUrgency.js / openChecks.js / sections.js and the small utilities in
/// TablesView.vue. Every rule here is display-side; the tests pin the
/// web's exact wording and bucket boundaries so the native floor plan tells
/// the same story the web does.
void main() {
  DateTime utc(String iso) => DateTime.parse(iso).toUtc();

  group('occupancyUrgency (web tableUrgency.js)', () {
    test('no seated_at → none', () {
      const t = CafeTable(id: 'T1', number: '1', status: 'occupied');
      expect(occupancyUrgency(t), 'none');
    });

    test('unparseable seated_at → none', () {
      const t = CafeTable(
          id: 'T1', number: '1', status: 'occupied', seatedAt: 'not-a-date');
      expect(occupancyUrgency(t), 'none');
    });

    test('future seated_at → none', () {
      final now = utc('2026-09-22T12:00:00Z');
      const t = CafeTable(
          id: 'T1',
          number: '1',
          status: 'occupied',
          seatedAt: '2026-09-22T12:30:00Z');
      expect(occupancyUrgency(t, now: now), 'none');
    });

    test('buckets: fresh <45, warm <90, late <4h, overdue ≥4h', () {
      final now = utc('2026-09-22T12:00:00Z');
      CafeTable seated(String iso) => CafeTable(
          id: 'T1', number: '1', status: 'occupied', seatedAt: iso);
      expect(occupancyUrgency(seated('2026-09-22T11:30:00Z'), now: now),
          'fresh'); // 30 min
      expect(occupancyUrgency(seated('2026-09-22T10:45:00Z'), now: now),
          'warm'); // 75 min
      expect(occupancyUrgency(seated('2026-09-22T10:00:00Z'), now: now),
          'late'); // 120 min
      expect(occupancyUrgency(seated('2026-09-22T08:00:00Z'), now: now),
          'overdue'); // 240 min — exactly the 4h maximum
      expect(occupancyUrgency(seated('2026-09-22T07:59:00Z'), now: now),
          'overdue'); // 241 min
    });
  });

  group('occupancyTimer (web occupancyTimer)', () {
    test('formats h/m and "just now"', () {
      final now = utc('2026-09-22T12:00:00Z');
      expect(occupancyTimer('2026-09-22T10:05:00Z', now: now), '1h 55m');
      expect(occupancyTimer('2026-09-22T11:30:00Z', now: now), '30m');
      expect(occupancyTimer('2026-09-22T11:59:30Z', now: now), 'just now');
      expect(occupancyTimer('', now: now), '');
      expect(occupancyTimer(null, now: now), '');
    });
  });

  group('isResumableCheck / latestResumableCheck (web openChecks.js)', () {
    FufutOrder order(String id,
        {String status = 'new',
        String? paymentStatus,
        String tableNum = 'T2',
        String? created}) {
      return FufutOrder(
        id: id,
        status: status,
        tableNum: tableNum,
        paymentStatus: paymentStatus ?? 'unpaid',
        created: created,
        total: 10,
      );
    }

    test('a check is open until paid; served-but-unpaid counts', () {
      expect(isResumableCheck(order('O1')), isTrue);
      expect(isResumableCheck(order('O2', status: 'served')), isTrue,
          reason: 'food served is NOT the check closed — the web fix');
      expect(isResumableCheck(order('O3', status: 'fulfilled')), isTrue,
          reason: 'fulfilled-but-unpaid stays resumable');
      expect(
          isResumableCheck(order('O4', status: 'fulfilled', paymentStatus: 'paid')),
          isFalse);
      expect(isResumableCheck(order('O5', paymentStatus: 'paid')), isFalse);
      expect(isResumableCheck(order('O6', status: 'cancelled')), isFalse);
      expect(isResumableCheck(order('O7', status: 'completed')), isFalse);
      expect(isResumableCheck(null), isFalse);
    });

    test('newest resumable check wins — by created, not array position', () {
      final orders = [
        order('OLD', created: '2026-09-22T09:00:00Z'),
        order('NEW', created: '2026-09-22T11:00:00Z'),
        order('PAID', status: 'ready', paymentStatus: 'paid',
            created: '2026-09-22T12:00:00Z'),
      ];
      final best = latestResumableCheck(orders, 'T2');
      expect(best?.id, 'NEW',
          reason: 'GET /orders is newest-first; "last element" picked the '
              'oldest — the web fixed this by scoring created');
    });

    test('table numbers drift-tolerant: T2 / 2 / T-2 match', () {
      final orders = [order('O1', tableNum: '2')];
      expect(latestResumableCheck(orders, 'T2')?.id, 'O1');
      expect(latestResumableCheck(orders, 'T-2')?.id, 'O1');
      expect(latestResumableCheck(orders, 'T3'), isNull);
    });

    test('empty list → null', () {
      expect(latestResumableCheck(const [], 'T2'), isNull);
    });
  });

  group('mergeSections (web sections.js)', () {
    test('server order wins; rows-only zones appended case-insensitively',
        () {
      final rows = [
        const CafeTable(id: 'T1', number: '1', status: 'available', section: 'VIP room'),
        const CafeTable(id: 'T2', number: '2', status: 'available', section: 'Patio'),
        const CafeTable(id: 'T3', number: '3', status: 'available', section: 'Terrace'),
      ];
      final merged = mergeSections(
          ['Patio', 'Main Hall', 'Window', 'VIP Room', 'Bar'], rows);
      expect(merged, [
        'Patio',
        'Main Hall',
        'Window',
        'VIP Room',
        'Bar',
        'Terrace',
      ], reason: 'VIP room dedupes against VIP Room; Terrace is appended');
    });

    test('null/garbage server list changes nothing usable → rows only', () {
      final rows = [
        const CafeTable(id: 'T1', number: '1', status: 'available', section: 'Bar'),
      ];
      expect(mergeSections(null, rows), ['Bar']);
      expect(mergeSections(['  ', ''], rows), ['Bar']);
    });

    test('empty rows keep the server list', () {
      expect(mergeSections(['Patio'], []), ['Patio']);
    });

    test('blank sections on rows are skipped', () {
      final rows = [
        const CafeTable(id: 'T1', number: '1', status: 'available', section: '  '),
      ];
      expect(mergeSections(['Patio'], rows), ['Patio']);
    });
  });

  group('server badge (web serverColor / serverInitials)', () {
    test('initials take the first two words', () {
      expect(serverInitials('Yonas Girmay'), 'YG');
      expect(serverInitials('madison'), 'M');
      expect(serverInitials('  '), '');
      expect(serverInitials(null), '');
    });

    test('hue is stable across calls and within 0..359', () {
      final h = serverHue('Yonas Girmay');
      expect(h, serverHue('Yonas Girmay'));
      expect(h, inInclusiveRange(0, 359));
      expect(serverHue('Sara'), isNot(serverHue('Yonas Girmay')));
    });
  });

  group('holdWindowLabel (web holdWindowLabel)', () {
    test('upcoming booking reads "from HH:MM"', () {
      final label = holdWindowLabel('2026-09-22T18:00:00Z',
          '2026-09-22T20:00:00Z', now: utc('2026-09-22T12:00:00Z'));
      expect(label, 'from 18:00');
    });

    test('started booking reads "until HH:MM"', () {
      final label = holdWindowLabel('2026-09-22T10:00:00Z',
          '2026-09-22T20:00:00Z', now: utc('2026-09-22T12:00:00Z'));
      expect(label, 'until 20:00');
    });

    test('unparseable window → empty', () {
      expect(holdWindowLabel('x', 'y'), '');
      expect(holdWindowLabel(null, null), '');
    });
  });

  group('wording helpers', () {
    test('paymentLabel matches the web map', () {
      expect(paymentLabel('paid'), 'Paid');
      expect(paymentLabel('partial'), 'Partly Paid');
      expect(paymentLabel('unpaid'), 'Unpaid');
      expect(paymentLabel('odd'), 'odd');
      expect(paymentLabel(null), '');
    });

    test('tableLabel turns T4 into Table 4', () {
      expect(tableLabel('T4'), 'Table 4');
      expect(tableLabel('12'), 'Table 12');
      expect(tableLabel('T2'), 'Table 2');
      expect(tableLabel('weird'), 'weird');
      expect(tableLabel(''), 'No table');
      expect(tableLabel(null), 'No table');
    });

    test('formatETB groups thousands and trails ETB', () {
      expect(formatETB(1000), '1,000 ETB');
      expect(formatETB(120), '120 ETB');
      expect(formatETB(0), '0 ETB');
      expect(formatETB(null), '0 ETB');
      expect(formatETB(1234567), '1,234,567 ETB');
    });

    test('summariseItems formats the pending line', () {
      const lines = [
        OrderItemLine(
            menuItemId: 'M1', name: 'Latte', basePrice: 65, qty: 2, lineTotal: 130),
        OrderItemLine(
            menuItemId: 'M2', name: 'Cake', basePrice: 40, qty: 1, lineTotal: 40),
      ];
      expect(summariseItems(lines), '2x Latte, 1x Cake');
      expect(summariseItems(const []), '');
    });

    test('waitingFor reads naive stamps as UTC (the web appends Z)', () {
      final now = utc('2026-09-22T12:00:00Z');
      expect(waitingFor('2026-09-22T11:30:00', now: now), '30 min');
      expect(waitingFor('2026-09-22T12:00:20', now: now), 'just now');
      expect(waitingFor('2026-09-22T12:01:00Z', now: now), 'just now',
          reason: 'future stamp (clock skew) reads just now, as on the web');
      expect(waitingFor('', now: now), '');
      expect(waitingFor('garbage', now: now), '');
    });
  });

  group('CafeTable parsing (the live row shape)', () {
    test('parses every field the web floor plan renders', () {
      final t = CafeTable.fromJson(const {
        'id': 'T2',
        'number': 2,
        'capacity': 2,
        'section': 'Window',
        'status': 'occupied',
        'name': 'Table 2',
        'shape': 'square',
        'server': 'Yonas Girmay',
        'guests': 2,
        'seated_at': '2026-09-22T09:06:08.828814Z',
        'notes': 'Window seat',
        'bill_requested_at': '2026-09-22T10:00:00Z',
        'bill_requested_by': 'Yonas',
        'payment': 'partial',
        'reservedHold': {
          'id': 'R1',
          'name': 'Sara',
          'startAt': '2026-09-22T18:00:00Z',
          'endAt': '2026-09-22T20:00:00Z',
          'guests': 4,
          'blocksNow': true,
        },
      });
      expect(t.number, '2');
      expect(t.seats, 2);
      expect(t.guestsCount, 2);
      expect(t.name, 'Table 2');
      expect(t.shape, 'square');
      expect(t.server, 'Yonas Girmay');
      expect(t.seatedAt, '2026-09-22T09:06:08.828814Z');
      expect(t.notes, 'Window seat');
      expect(t.billRequested, isTrue);
      expect(t.billRequestedBy, 'Yonas');
      expect(t.payment, 'partial');
      expect(t.reservedHold?.id, 'R1');
      expect(t.reservedHold?.name, 'Sara');
      expect(t.reservedHold?.guests, 4);
      expect(t.reservedHold?.blocksNow, isTrue);
      expect(t.sizeLabel, 'Small');
    });

    test('copyWith patches single fields for local edits', () {
      const t = CafeTable(id: 'T1', number: '1', status: 'occupied');
      final t2 = t.copyWith(billRequestedAt: '2026-09-22T10:00:00Z');
      expect(t2.billRequested, isTrue);
      expect(t.billRequested, isFalse);
      expect(t2.id, 'T1');
      expect(t2.status, 'occupied');
    });

    test('sizeLabel buckets: ≤4 Small, ≤6 Medium, else Large', () {
      int cap(int n) => n; // capacity arrives as seats via fromJson
      expect(
          CafeTable.fromJson({'id': 'T1', 'number': 1, 'capacity': cap(4)})
              .sizeLabel,
          'Small');
      expect(
          CafeTable.fromJson({'id': 'T1', 'number': 1, 'capacity': cap(6)})
              .sizeLabel,
          'Medium');
      expect(
          CafeTable.fromJson({'id': 'T1', 'number': 1, 'capacity': cap(8)})
              .sizeLabel,
          'Large');
    });
  });

  group('isCurrentSeatingOrder — active orders are the NEW customers only', () {
    FufutOrder check(String id,
        {String status = 'new',
        String? clearedAt,
        required String created}) {
      return FufutOrder(
        id: id,
        status: status,
        tableNum: 'T2',
        paymentStatus: 'unpaid',
        created: created,
        clearedAt: clearedAt,
        total: 10,
      );
    }

    // Timezone-robust fixtures: `created` is a naive local stamp (the
    // server's shape), seated_at a UTC ISO (the claiming device's shape) —
    // both built from the local calendar so the test never pins UTC hours.
    String seatedIso(DateTime local) => local.toUtc().toIso8601String();
    String naiveLocal(DateTime local) =>
        '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}';

    test('a freed party\u2019s leftover check is history, not active', () {
      final seated = DateTime.now(); // party sat now
      const t = CafeTable(id: 'T2', number: '2', status: 'occupied');
      final tSeated = CafeTable(
          id: 'T2',
          number: '2',
          status: 'occupied',
          seatedAt: seatedIso(seated));
      final old = check('O-old', clearedAt: '2026-09-25T12:16:33.000Z',
          created: naiveLocal(seated.subtract(const Duration(hours: 2))));
      // cleared_at alone decides — regardless of the seating clock.
      expect(isCurrentSeatingOrder(old, t), isFalse);
      expect(isCurrentSeatingOrder(old, tSeated), isFalse);
    });

    test('the new customers\u2019 orders ride the active list', () {
      final seated = DateTime.now().subtract(const Duration(minutes: 30));
      final t = CafeTable(
          id: 'T2',
          number: '2',
          status: 'occupied',
          seatedAt: seatedIso(seated));
      final fresh = check('O-new',
          created: naiveLocal(seated.add(const Duration(minutes: 5))));
      expect(isCurrentSeatingOrder(fresh, t), isTrue);
    });

    test('an order created before the current party sat is a previous '
        'party\u2019s — even with no clear stamp', () {
      final seated = DateTime.now().subtract(const Duration(minutes: 10));
      final t = CafeTable(
          id: 'T2',
          number: '2',
          status: 'occupied',
          seatedAt: seatedIso(seated));
      final stale = check('O-stale',
          status: 'served',
          created: naiveLocal(seated.subtract(const Duration(hours: 3))));
      expect(isCurrentSeatingOrder(stale, t), isFalse,
          reason: 'quick-status turns bypass /free; the seating clock is '
              'the fallback');
    });

    test('a table that never stamped seated_at leans on cleared_at alone',
        () {
      const t = CafeTable(id: 'T2', number: '2', status: 'occupied');
      final fresh = check('O-fresh', created: naiveLocal(DateTime.now()));
      expect(isCurrentSeatingOrder(fresh, t), isTrue);
      final freed = check('O-freed',
          clearedAt: '2026-09-25T12:16:33.000Z',
          created: naiveLocal(DateTime.now()));
      expect(isCurrentSeatingOrder(freed, t), isFalse);
    });
  });
}
