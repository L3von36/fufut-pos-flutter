/// Role-scoping rules — the Flutter mirror of the web POS `orderScope.js`
/// contract plus the action grants (`canCheckout`, `canAdvancePrep`).
///
/// These tests pin the rules the user asked for: every role sees and does
/// only what its grant covers — the waiter cannot cook, the barista cannot
/// read food tickets, the floor cannot settle bills.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:fufut_pos/models/models.dart';
import 'package:fufut_pos/state/order_scope.dart';
import 'package:fufut_pos/state/roles.dart';

FufutOrder _order({
  String id = 'o1',
  String status = 'new',
  String? tableNum,
  String? createdById,
  List<OrderItemLine> items = const [],
  String itemsRaw = '',
}) {
  return FufutOrder(
    id: id,
    status: status,
    type: 'dine-in',
    tableNum: tableNum,
    createdById: createdById,
    items: items,
    itemsRaw: itemsRaw,
  );
}

OrderItemLine _line(String name, {int qty = 1}) => OrderItemLine(
      menuItemId: null,
      name: name,
      basePrice: 10,
      qty: qty,
      lineTotal: 10.0 * qty,
    );

void main() {
  group('orderVisibleToRole — station roles', () {
    test('barista sees a drink ticket, not a food ticket', () {
      final latte = _order(items: [_line('Latte'), _line('Espresso')]);
      final gebeta = _order(items: [_line('Fut breakfast Gebeta')]);
      expect(orderVisibleToRole(latte, 'barista'), isTrue);
      expect(orderVisibleToRole(gebeta, 'barista'), isFalse);
    });

    test('chefs see a food ticket, not a drink-only ticket', () {
      final gebeta = _order(items: [_line('Fut breakfast Gebeta')]);
      final soda = _order(items: [_line('Cola soda')]);
      expect(orderVisibleToRole(gebeta, 'head-chef'), isTrue);
      expect(orderVisibleToRole(gebeta, 'assistant-chef'), isTrue);
      expect(orderVisibleToRole(soda, 'head-chef'), isFalse);
    });

    test('mixed ticket visible to both stations, lines scoped per station', () {
      final mixed = _order(
          items: [_line('Latte'), _line('Fut breakfast Gebeta')]);
      expect(orderVisibleToRole(mixed, 'barista'), isTrue);
      expect(orderVisibleToRole(mixed, 'head-chef'), isTrue);

      final barLines = orderLinesForRole(mixed, 'barista')!;
      expect(barLines.map((l) => l.name), ['Latte']);
      final foodLines = orderLinesForRole(mixed, 'assistant-chef')!;
      expect(foodLines.map((l) => l.name), ['Fut breakfast Gebeta']);
      // Unscoped roles read the whole ticket.
      expect(orderLinesForRole(mixed, 'head-waiter'), isNull);
      expect(orderLinesForRole(mixed, 'manager'), isNull);
    });

    test('legacy flat summary classifies like structured lines', () {
      final legacy = _order(
          itemsRaw:
              '2x Latte [oat-milk, vanilla] (extra hot), 1x Fut breakfast Gebeta');
      final barLines = orderLinesForRole(legacy, 'barista')!;
      expect(barLines, hasLength(1));
      expect(barLines.first.name, 'Latte');
      expect(barLines.first.qty, 2);
      expect(
          orderVisibleToRole(
              _order(itemsRaw: '1x Espresso'), 'head-chef'),
          isFalse);
    });

    test('a dish name containing a comma survives the flat parser', () {
      final tricky = _order(itemsRaw: '1x Espresso, Tonic');
      // One line — the comma split only lands where the next "<qty>x" marker
      // starts, so the name stays "Espresso, Tonic". Its first word reads as
      // a drink, so the stations route it like a drink ticket (same verdict
      // the web's parser reaches on this exact string).
      final barLines = orderLinesForRole(tricky, 'barista');
      expect(barLines, hasLength(1));
      expect(barLines!.first.name, 'Espresso, Tonic');
      expect(orderVisibleToRole(tricky, 'barista'), isTrue);
      expect(orderVisibleToRole(tricky, 'head-chef'), isFalse);
    });

    test('unclassifiable tickets fail open — nobody loses work to a parse', () {
      final mystery = _order(itemsRaw: 'free text from a QR guest');
      expect(orderVisibleToRole(mystery, 'barista'), isTrue);
      expect(orderVisibleToRole(mystery, 'head-chef'), isTrue);
    });
  });

  group('orderVisibleToRole — the floor', () {
    test('head-waiter sees his own tickets wherever they land', () {
      final mine = _order(createdById: '42', tableNum: '9');
      final theirs = _order(createdById: '7', tableNum: '12');
      final ctx = {'42': 'me'};
      expect(
        orderVisibleToRole(mine, 'head-waiter',
            myId: '42', myTables: {'3', '9'}),
        isTrue,
      );
      expect(ctx, isNotEmpty); // keep the map honest — my ticket by id
      expect(
        orderVisibleToRole(theirs, 'head-waiter',
            myId: '42', myTables: {'3', '9'}),
        isFalse,
      );
    });

    test('a ticket on an assigned table is his even when a colleague fired it',
        () {
      final table3 = _order(createdById: '7', tableNum: '3');
      expect(
        orderVisibleToRole(table3, 'head-waiter',
            myId: '42', myTables: {'3'}),
        isTrue,
      );
    });

    test('takeaways with no table stay with whoever took them', () {
      final takeaway = _order(createdById: '7', tableNum: null);
      expect(
        orderVisibleToRole(takeaway, 'head-waiter',
            myId: '42', myTables: {'3'}),
        isFalse,
      );
    });

    test('manager, cashier and accountant read the whole room', () {
      final any = _order(createdById: '7', tableNum: '99');
      for (final role in ['manager', 'cashier', 'accountant', 'cleaner']) {
        expect(orderVisibleToRole(any, role), isTrue, reason: role);
      }
    });
  });

  group('assignedTableNumbers — the multi-waiter isolation rule', () {
    // The floor rides whole to every role (verified live 2026-09-25: a
    // head-waiter GET /api/tables returns every section with the assigned
    // server on each row) — narrowing is the client's job, per-row matching
    // on server_id first, display name second.
    const floor = [
      CafeTable(id: 't1', number: '1', status: 'available', server: 'Yonas Girmay', serverId: 'S6'),
      CafeTable(id: 't2', number: '2', status: 'occupied', server: 'Yonas Girmay', serverId: 'S6'),
      CafeTable(id: 't3', number: '3', status: 'available', server: 'Amanuel Fekadu', serverId: 'S9'),
      CafeTable(id: 't4', number: '4', status: 'available', server: 'Amanuel Fekadu', serverId: 'S9'),
    ];

    test('a waiter gets only the tables assigned to them', () {
      expect(
        assignedTableNumbers(floor, myId: 'S6', myName: 'Yonas Girmay'),
        {'1', '2'},
      );
      expect(
        assignedTableNumbers(floor, myId: 'S9', myName: 'Amanuel Fekadu'),
        {'3', '4'},
      );
    });

    test('id match wins even when the display name drifted', () {
      // Yonas got married; the floor still names the OLD name but the id
      // column is updated first.
      const renamed = [
        CafeTable(id: 't1', number: '1', status: 'available',
            server: 'Yonas Girmay', serverId: 'S6'),
        CafeTable(id: 't2', number: '2', status: 'available',
            server: 'Amanuel Fekadu', serverId: 'S9'),
      ];
      expect(assignedTableNumbers(renamed, myId: 'S6', myName: 'New Name'),
          {'1'});
    });

    test('name match covers floors that carry no ids (legacy rows)', () {
      const legacy = [
        CafeTable(id: 't1', number: '1', status: 'available',
            server: 'Yonas Girmay'),
        CafeTable(id: 't2', number: '2', status: 'available',
            server: 'Amanuel Fekadu'),
      ];
      expect(assignedTableNumbers(legacy, myId: 'S6', myName: 'Yonas Girmay'),
          {'1'});
    });

    test('a floor nobody is assigned stays shared — nobody gets blinded', () {
      const shared = [
        CafeTable(id: 't1', number: '1', status: 'available'),
        CafeTable(id: 't2', number: '2', status: 'available'),
      ];
      expect(assignedTableNumbers(shared, myId: 'S6', myName: 'Yonas Girmay'),
          {'1', '2'});
    });

    test('the end-to-end slice: two waiters, one room, no overlap', () {
      final o1 = _order(createdById: 'S6', tableNum: '1');
      final o2 = _order(createdById: 'S9', tableNum: '3');
      final o3 = _order(createdById: 'S9', tableNum: '2'); // on Yonas' table
      final yonas = assignedTableNumbers(floor, myId: 'S6', myName: 'Yonas Girmay');
      final amanuel =
          assignedTableNumbers(floor, myId: 'S9', myName: 'Amanuel Fekadu');

      // Yonas: his own ticket, plus the colleague's ticket ON HIS table.
      expect(orderVisibleToRole(o1, 'head-waiter', myId: 'S6', myTables: yonas),
          isTrue);
      expect(orderVisibleToRole(o3, 'head-waiter', myId: 'S6', myTables: yonas),
          isTrue);
      // Amanuel's ticket on Amanuel's table stays Amanuel's.
      expect(orderVisibleToRole(o2, 'head-waiter', myId: 'S6', myTables: yonas),
          isFalse);
      expect(
          orderVisibleToRole(o2, 'head-waiter', myId: 'S9', myTables: amanuel),
          isTrue);
      // And the reverse leg: Yonas' ticket is invisible to Amanuel.
      expect(
          orderVisibleToRole(o1, 'head-waiter', myId: 'S9', myTables: amanuel),
          isFalse);
    });
  });

  group('action grants', () {
    test('checkout: manager + cashier only — the floor never settles', () {
      expect(canCheckout('manager'), isTrue);
      expect(canCheckout('cashier'), isTrue);
      expect(canCheckout('head-waiter'), isFalse);
      expect(canCheckout('head-chef'), isFalse);
      expect(canCheckout('barista'), isFalse);
      expect(canCheckout('accountant'), isFalse);
      expect(canCheckout(null), isFalse);
    });

    test('prep advancing: chef work, chef roles only', () {
      expect(canAdvancePrep('head-chef'), isTrue);
      expect(canAdvancePrep('assistant-chef'), isTrue);
      expect(canAdvancePrep('head-waiter'), isFalse);
      expect(canAdvancePrep('manager'), isFalse);
      expect(canAdvancePrep('cashier'), isFalse);
      expect(canAdvancePrep(null), isFalse);
    });
  });

  group('empty-state hints', () {
    test('each role gets its own explanation', () {
      expect(emptyOrdersHint('barista'), contains('Drink tickets'));
      expect(emptyOrdersHint('assistant-chef'), contains('Food tickets'));
      expect(emptyOrdersHint('head-waiter'), contains('assigned tables'));
      expect(emptyOrdersHint('manager'), contains('No orders match'));
    });
  });

  group('the JSON-array summary the server stores since per-line tracking', () {
    // The /api/orders rows and SSE snapshots carry NO orderItems — the lines
    // must come from the summary string. Since the tracking migration the
    // server stores it as a JSON array, and a summary the boards could not
    // parse hid every newly-fired ticket from every board (found live on the
    // local box, 2026-09-24).
    const jsonMixed =
        '[{"id":"MI-1","name":"Latte","qty":1,"price":60},{"id":"MI-2","name":"Firfir","qty":2,"price":140}]';

    test('structuredLinesFromRaw parses the array into full lines', () {
      final lines = structuredLinesFromRaw(jsonMixed);
      expect(lines, isNotNull);
      expect(lines!.length, 2);
      expect(lines[0].name, 'Latte');
      expect(lines[0].qty, 1);
      expect(lines[1].name, 'Firfir');
      expect(lines[1].qty, 2);
    });

    test('boardLines renders the ticket from the JSON summary', () {
      final lines = boardLines(_order(itemsRaw: jsonMixed));
      expect(lines.length, 2);
      expect(lines.map((l) => l.name), containsAll(['Latte', 'Firfir']));
    });

    test('scopedLines routes a JSON-summary mixed ticket per station', () {
      final kitchen = scopedLines(_order(itemsRaw: jsonMixed), 'kitchen');
      expect(kitchen!.map((l) => l.name), ['Firfir']);
      final bar = scopedLines(_order(itemsRaw: jsonMixed), 'bar');
      expect(bar!.map((l) => l.name), ['Latte']);
    });

    test('a JSON summary that is all the other station hides the ticket', () {
      const drinksOnly =
          '[{"name":"Latte","qty":1,"price":60},{"name":"Espresso","qty":1,"price":45}]';
      expect(scopedLines(_order(itemsRaw: drinksOnly), 'kitchen'), isEmpty);
    });

    test('a malformed JSON string fails OPEN, never silent', () {
      expect(
          scopedLines(_order(itemsRaw: '[{"name":"Latte"'), 'kitchen'), isNull);
    });

    test('the legacy flat summary still parses — old rows keep rendering', () {
      final lines = boardLines(_order(itemsRaw: '2x Latte, 1x Firfir'));
      expect(lines.length, 2);
      expect(lines[0].qty, 2);
    });
  });
}
