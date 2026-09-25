import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fufut_pos/models/models.dart';
import 'package:fufut_pos/services/order_journal.dart';

void main() {
  group('OrderJournal', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      OrderJournal.instance.debugReset();
    });

    test('records and reads stages chronologically', () async {
      final journal = OrderJournal.instance;
      final base = DateTime.now();
      await journal.record('O1', OrderStage.created, at: base);
      await journal.record('O1', OrderStage.preparing,
          at: base.add(const Duration(minutes: 4)));
      await journal.record('O1', OrderStage.ready,
          at: base.add(const Duration(minutes: 9)));
      final events = await journal.eventsFor('O1');
      expect(events.map((e) => e.stage),
          [OrderStage.created, OrderStage.preparing, OrderStage.ready]);
      expect(journal.latestStageAtSync('O1', OrderStage.preparing),
          base.add(const Duration(minutes: 4)));
      expect(journal.hasStageSync('O1', OrderStage.ready), isTrue);
      expect(journal.hasStageSync('O1', OrderStage.served), isFalse);
    });

    test('same stage within 2s collapses (double-tap / SSE echo)', () async {
      final journal = OrderJournal.instance;
      await journal.record('O1', OrderStage.preparing);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await journal.record('O1', OrderStage.preparing);
      expect((await journal.eventsFor('O1')).length, 1);
    });

    test('statusDiffs maps status moves to stages', () {
      final before = [
        const FufutOrder(id: 'A', status: 'new'),
        const FufutOrder(id: 'B', status: 'ready'),
      ];
      final after = [
        const FufutOrder(id: 'A', status: 'preparing'),
        const FufutOrder(id: 'B', status: 'ready'),
        const FufutOrder(id: 'C', status: 'new'),
      ];
      final diffs = OrderJournal.statusDiffs(before, after);
      final map = {for (final (o, s) in diffs) o.id: s};
      expect(map['A'], OrderStage.preparing);
      expect(map.containsKey('B'), isFalse); // unchanged
      expect(map['C'], OrderStage.created);
    });

    test(
        'empty before-list reads as baseline for every order — '
        'callers must guard it', () {
      // statusDiffs itself cannot tell a first load from a flood; the feed's
      // baseline flag and hasStageSync guard are the floodgate. This pins
      // the contract so a caller that drops the guard sees it here.
      final diffs = OrderJournal.statusDiffs(
          const <FufutOrder>[], [const FufutOrder(id: 'A', status: 'new')]);
      expect(diffs.single.$1.id, 'A');
      expect(diffs.single.$2, OrderStage.created);
    });

    test('payState → stage mapping covers the floor flow', () {
      // ready→fulfilled is pickup, fulfilled→served is the floor's serve.
      final before = [const FufutOrder(id: 'A', status: 'ready')];
      final diffs = OrderJournal.statusDiffs(
          before, [const FufutOrder(id: 'A', status: 'fulfilled')]);
      expect(diffs.single.$2, OrderStage.pickedUp);
      final served = OrderJournal.statusDiffs(
          [const FufutOrder(id: 'A', status: 'fulfilled')],
          [const FufutOrder(id: 'A', status: 'served')]);
      expect(served.single.$2, OrderStage.served);
    });
  });

  group('FufutOrder pay states', () {
    test('partial renders its own chip but counts as money down', () {
      // The v1.3.1 isPaid contract: any real payment label means money moved
      // (a partial is a deposit, not a fresh unpaid ticket — the KPI and
      // settle gate rely on that). The Order Log chip still distinguishes
      // PARTLY PAID from PAID through payState.
      final o = const FufutOrder(id: 'A', status: 'served', payment: 'partial');
      expect(o.isPaid, isTrue);
      expect(o.payState, 'partial');
      expect(o.isResumableCheck, isFalse);
    });

    test('payment_status paid wins; unpaid served checks stay open', () {
      expect(
          const FufutOrder(id: 'A', status: 'served', paymentStatus: 'paid')
              .isPaid,
          isTrue);
      final served =
          const FufutOrder(id: 'B', status: 'served', payment: 'unpaid');
      expect(served.isPaid, isFalse);
      expect(served.payState, 'unpaid');
      expect(served.isResumableCheck, isTrue);
      expect(const FufutOrder(id: 'C', status: 'cancelled').isResumableCheck,
          isFalse);
      expect(const FufutOrder(id: 'D', status: 'completed').isResumableCheck,
          isFalse);
    });

    test('payment_status partial reads as the partial chip', () {
      final o =
          const FufutOrder(id: 'E', status: 'served', paymentStatus: 'partial');
      expect(o.payState, 'partial');
    });
  });

  group('CafeTable party size', () {
    test('guests value wins, capacity is the fallback', () {
      final t = const CafeTable(
        id: 'T1',
        number: '5',
        status: 'occupied',
        seats: 4,
        guests: '3',
      );
      expect(t.partySize, 3);
      final empty = const CafeTable(
        id: 'T2',
        number: '6',
        status: 'available',
        seats: 4,
        guests: '0',
      );
      expect(empty.partySize, 4);
    });
  });
}
