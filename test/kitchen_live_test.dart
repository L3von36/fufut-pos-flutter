/// KitchenLive diff-engine tests — the web KitchenView baseline rules.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fufut_pos/models/models.dart';
import 'package:fufut_pos/services/kitchen_live.dart';

FufutOrder order(String id, String status) => FufutOrder(
      id: id,
      status: status,
      created: '2026-09-21T12:00:00.000Z',
    );

void main() {
  group('KitchenLive.applyNewOrderSnapshot', () {
    test('first snapshot is the baseline — never announces', () {
      final live = KitchenLive();
      final newId = live.applyNewOrderSnapshot(
          [order('A', 'new'), order('B', 'preparing'), order('C', 'ready')]);
      expect(newId, isNull);
      expect(live.baselineSeen, isTrue);
    });

    test('genuinely-new ticket after baseline is announced', () {
      final live = KitchenLive();
      live.applyNewOrderSnapshot([order('A', 'new')]);
      final newId = live.applyNewOrderSnapshot([order('A', 'new'), order('B', 'new')]);
      expect(newId, 'B');
    });

    test('unchanged board announces nothing', () {
      final live = KitchenLive();
      live.applyNewOrderSnapshot([order('A', 'new')]);
      expect(live.applyNewOrderSnapshot([order('A', 'new')]), isNull);
    });

    test('ticket that left the board then returned is announced again', () {
      final live = KitchenLive();
      live.applyNewOrderSnapshot([order('A', 'new'), order('B', 'new')]);
      // B served and dropped off the live list…
      live.applyNewOrderSnapshot([order('A', 'new')]);
      // …a split/re-open puts the same id back — it is news to this board.
      expect(live.applyNewOrderSnapshot([order('A', 'new'), order('B', 'new')]),
          'B');
    });

    test('unseen ticket already in preparing still announces (web parity)',
        () {
      final live = KitchenLive();
      live.applyNewOrderSnapshot([order('A', 'new')]);
      final newId =
          live.applyNewOrderSnapshot([order('A', 'new'), order('B', 'preparing')]);
      expect(newId, 'B');
    });

    test('status flip of a known ticket is not a "new" announcement', () {
      final live = KitchenLive();
      live.applyNewOrderSnapshot([order('A', 'new')]);
      expect(live.applyNewOrderSnapshot([order('A', 'preparing')]), isNull);
    });

    test('reconnect re-snapshot of the same board announces nothing', () {
      // KitchenLive persists across reconnects: the server re-sends the
      // whole board on attach, and none of it is a transition.
      final live = KitchenLive();
      live.applyNewOrderSnapshot([order('A', 'new'), order('B', 'ready')]);
      live.applyNewOrderSnapshot(
          [order('A', 'new'), order('B', 'ready'), order('C', 'new')]);
      expect(live.applyNewOrderSnapshot(
          [order('A', 'new'), order('B', 'ready'), order('C', 'new')]), isNull);
    });

    test('reset re-baselines (logout / account switch)', () {
      final live = KitchenLive();
      live.applyNewOrderSnapshot([order('A', 'new')]);
      live.reset();
      expect(
          live.applyNewOrderSnapshot([order('A', 'new'), order('B', 'new')]),
          isNull);
    });
  });

  group('KitchenLive.newlyReadyIn', () {
    test('preparing → ready transition detected', () {
      final prev = [order('A', 'preparing'), order('B', 'new')];
      final fresh = [order('A', 'ready'), order('B', 'new')];
      expect(KitchenLive.newlyReadyIn(prev, fresh), 'A');
    });

    test('already-ready order staying ready is silent', () {
      final prev = [order('A', 'ready')];
      expect(KitchenLive.newlyReadyIn(prev, [order('A', 'ready')]), isNull);
    });

    test('nothing ready anywhere is silent', () {
      final prev = [order('A', 'new')];
      expect(KitchenLive.newlyReadyIn(prev, [order('A', 'preparing')]), isNull);
    });

    test('ready order that DROPPED off the board is not a transition', () {
      // Served orders leave the live list; their absence must not read as
      // "became ready".
      final prev = [order('A', 'preparing'), order('B', 'ready')];
      expect(KitchenLive.newlyReadyIn(prev, [order('A', 'ready')]), 'A');
      // (B vanished — served. A is the only fresh transition.)
    });

    test('first transition wins, web parity', () {
      final prev = [order('A', 'new'), order('B', 'preparing')];
      final fresh = [order('A', 'ready'), order('B', 'ready')];
      expect(KitchenLive.newlyReadyIn(prev, fresh), 'A');
    });
  });
}
