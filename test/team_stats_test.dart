import 'package:flutter_test/flutter_test.dart';

import 'package:fufut_pos/models/models.dart';
import 'package:fufut_pos/services/team_stats.dart';

/// The Team screen's arithmetic — the one place that decides what "how good
/// is each of us doing" means. Fixtures build rows directly; the day window
/// rides the naive local `created` stamps the server emits.
void main() {
  final day = '2026-09-25';

  FufutOrder order({
    String id = 'Ox',
    String? by = 'Amanuel',
    String status = 'served',
    String type = 'dine-in',
    String? tableNum,
    double total = 100,
    double tip = 0,
    String created = '2026-09-25 10:00:00',
    String? preparingAt,
    String? readyAt,
    String? pickedUpAt,
    String? servedAt,
    String? voidedAt,
    String itemsRaw = '2x Dish',
  }) {
    return FufutOrder(
      id: id,
      status: status,
      type: type,
      tableNum: tableNum,
      total: total,
      tip: tip,
      created: created,
      preparingAt: preparingAt,
      readyAt: readyAt,
      pickedUpAt: pickedUpAt,
      servedAt: servedAt,
      voidedAt: voidedAt,
      itemsRaw: itemsRaw,
      createdByName: by,
    );
  }

  AuditEntry statusRow({
    required String orderId,
    required String actorName,
    required String actorRole,
    required String lineStatus,
    String at = '2026-09-25T07:05:00.000Z',
    Map<String, dynamic>? after,
  }) {
    return AuditEntry(
      id: 'AL${actorName.hashCode.abs()}$lineStatus',
      at: at,
      entity: 'orders',
      action: 'status',
      entityId: orderId,
      actorName: actorName,
      actorRole: actorRole,
      after: after ?? {'itemId': 'I1', 'lineStatus': lineStatus},
    );
  }

  group('floor attribution — who took what, brought what', () {
    test('orders, sales (tips excluded) and tips land on the taker', () {
      final stats = computeTeamDay(
        dayKey: day,
        orders: [
          order(id: 'O1', by: 'Amanuel', total: 200, tip: 20),
          order(id: 'O2', by: 'Amanuel', total: 100),
          order(id: 'O3', by: 'Hanna', total: 300),
        ],
      );

      expect(stats.ordersCount, 3);
      // (200-20) + 100 + 300 = 580 — revenue is tips-excluded.
      expect(stats.revenue, closeTo(580, 0.01));
      expect(stats.floor.first.name, 'Hanna'); // 300 sales tops Amanuel's 280
      final amanu = stats.floor.firstWhere((p) => p.name == 'Amanuel');
      expect(amanu.orders, 2);
      expect(amanu.sales, closeTo(280, 0.01));
      expect(amanu.tips, closeTo(20, 0.01));
    });

    test('guests: a table party counts once, takeaways one each', () {
      final stats = computeTeamDay(
        dayKey: day,
        orders: [
          order(id: 'O1', by: 'Amanuel', tableNum: 'T3'),
          order(id: 'O2', by: 'Amanuel', tableNum: 'T3'), // same party, again
          order(id: 'O3', by: 'Amanuel', type: 'takeaway'),
          order(id: 'O4', by: 'Hanna', type: 'delivery'),
        ],
        tablesByNumber: {
          'T3': const CafeTable(id: 'T3', number: 'T3', status: 'occupied', guests: '4'),
        },
      );

      final amanu = stats.floor.firstWhere((p) => p.name == 'Amanuel');
      expect(amanu.guests, 5); // party of 4 once + 1 takeaway
      expect(stats.floor.firstWhere((p) => p.name == 'Hanna').guests, 1);
      expect(stats.guests, 6);
    });

    test('voided tickets leave the money and the counts alone', () {
      final stats = computeTeamDay(
        dayKey: day,
        orders: [
          order(id: 'O1', total: 500),
          order(id: 'O2', total: 500, voidedAt: '2026-09-25T09:00:00Z',
              status: 'voided'),
        ],
      );

      expect(stats.ordersCount, 1);
      expect(stats.revenue, closeTo(500, 0.01));
      expect(stats.floor.single.orders, 1);
    });

    test('the take→serve pace averages only completed serves', () {
      // The served stamp is built from the created one so the thirty-minute
      // leg survives any test machine's timezone: naive local +30min,
      // emitted as the UTC ISO the server writes.
      final servedAt = DateTime.parse('2026-09-25T10:00:00')
          .add(const Duration(minutes: 30))
          .toUtc()
          .toIso8601String();
      final stats = computeTeamDay(
        dayKey: day,
        orders: [
          order(id: 'O1', created: '2026-09-25 10:00:00', servedAt: servedAt),
          order(id: 'O2', created: '2026-09-25 11:00:00'), // still live
        ],
      );

      expect(stats.floor.single.avgServeMin, closeTo(30, 0.5));
      expect(stats.avgServeMin, closeTo(30, 0.5));
    });
  });

  group('stations — the clock and the people', () {
    test('the kitchen/bar split rides the menu categories', () {
      final stats = computeTeamDay(
        dayKey: day,
        orders: [
          order(id: 'O1', itemsRaw: '1x Latte, 2x Dish',
              preparingAt: '2026-09-25 10:05:00',
              readyAt: '2026-09-25 10:20:00',
              pickedUpAt: '2026-09-25 10:25:00'),
        ],
        catByName: const {'latte': 'Drinks', 'dish': 'Food'},
      );

      expect(stats.kitchen.tickets, 1);
      expect(stats.kitchen.items, 2);
      expect(stats.bar.tickets, 1);
      expect(stats.bar.items, 1);
      // Make: preparing 10:05 → ready 10:20. New: created 10:00 → 10:05.
      expect(stats.kitchen.avgNewMin, closeTo(5, 0.5));
      expect(stats.kitchen.avgMakeMin, closeTo(15, 0.5));
      expect(stats.kitchen.avgPassMin, closeTo(5, 0.5));
      expect(stats.bar.avgMakeMin, closeTo(15, 0.5));
    });

    test('stage rows attribute the taps to the account that made them', () {
      final stats = computeTeamDay(
        dayKey: day,
        orders: [
          order(id: 'O1',
              preparingAt: '2026-09-25 10:05:00',
              readyAt: '2026-09-25 10:20:00'),
          order(id: 'O2',
              preparingAt: '2026-09-25 11:00:00',
              readyAt: '2026-09-25 11:10:00'),
        ],
        statusRows: [
          statusRow(orderId: 'O1', actorName: 'Selam', actorRole: 'head-chef',
              lineStatus: 'preparing'),
          statusRow(orderId: 'O1', actorName: 'Selam', actorRole: 'head-chef',
              lineStatus: 'ready'),
          statusRow(orderId: 'O2', actorName: 'Dani', actorRole: 'head-chef',
              lineStatus: 'ready'),
          // The barista's rows belong to the bar, never the kitchen.
          statusRow(orderId: 'O1', actorName: 'Bekele', actorRole: 'barista',
              lineStatus: 'ready'),
          // Non-stage rows do not count.
          statusRow(orderId: 'O1', actorName: 'Selam', actorRole: 'head-chef',
              lineStatus: 'fulfilled'),
        ],
      );

      expect(stats.kitchen.people.length, 2);
      final selam = stats.kitchen.people['Selam']!;
      expect(selam.bumped, 1);
      expect(selam.readied, 1);
      expect(selam.avgMakeMin, closeTo(15, 0.5)); // O1: 10:05 → 10:20
      final dani = stats.kitchen.people['Dani']!;
      expect(dani.readied, 1);
      expect(dani.avgMakeMin, closeTo(10, 0.5)); // O2: 11:00 → 11:10
      expect(stats.bar.people.keys, contains('Bekele'));
      expect(stats.kitchen.people.containsKey('Bekele'), isFalse);
    });
  });

  group('the till — who took the money', () {
    test('payments group by collector and split by method', () {
      final stats = computeTeamDay(
        dayKey: day,
        orders: [order(id: 'O1')],
        payments: [
          FufutPayment(id: 'P1', orderId: 'O1', method: 'cash', amount: 120,
              status: 'verified', collectedByName: 'Bethel',
              createdAt: '2026-09-25T07:00:00.000Z'),
          FufutPayment(id: 'P2', orderId: 'O1', method: 'telebirr', amount: 80,
              status: 'verified', collectedByName: 'Bethel',
              createdAt: '2026-09-25T07:10:00.000Z'),
          FufutPayment(id: 'P3', orderId: 'O1', method: 'cbe', amount: 60,
              status: 'recorded', collectedByName: 'Nati',
              createdAt: '2026-09-25T08:00:00.000Z'),
          // Refunds are not takings; another day is not this day.
          FufutPayment(id: 'P4', orderId: 'O1', method: 'cash', amount: -50,
              status: 'verified', collectedByName: 'Bethel',
              createdAt: '2026-09-25T08:30:00.000Z'),
          FufutPayment(id: 'P5', orderId: 'O1', method: 'cash', amount: 999,
              status: 'verified', collectedByName: 'Bethel',
              createdAt: '2026-09-24T08:30:00.000Z'),
        ],
      );

      expect(stats.till.first.name, 'Bethel');
      expect(stats.till.first.payments, 2);
      expect(stats.till.first.collected, closeTo(200, 0.01));
      expect(stats.till.first.transfersVerified, 1); // the telebirr row
      expect(stats.moneyByMethod['cash'], closeTo(120, 0.01));
      expect(stats.moneyByMethod['telebirr'], closeTo(80, 0.01));
      expect(stats.moneyByMethod['cbe'], closeTo(60, 0.01));
      expect(stats.transfersPending, 1); // Nati's CBE row awaits the till
    });
  });

  group('stamps — the two shapes the API emits', () {
    test('a naive local stamp keeps its day and clock', () {
      final d = teamParseStamp('2026-09-25 10:30:00')!;
      expect(d.hour, 10);
      expect(d.minute, 30);
      expect(teamDayKey('2026-09-25 10:30:00'), '2026-09-25');
    });

    test('an empty or broken stamp reads as never', () {
      expect(teamParseStamp(''), isNull);
      expect(teamParseStamp(null), isNull);
      expect(teamParseStamp('not-a-date'), isNull);
    });
  });
}
