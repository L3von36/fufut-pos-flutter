import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fufut_pos/models/models.dart';
import 'package:fufut_pos/state/cart.dart';
import 'package:fufut_pos/theme.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  MenuItem item(String id, String name, double price) => MenuItem(
        id: id,
        name: name,
        category: 'HOT DRINKS',
        price: price,
      );

  group('CartState', () {
    test('adds items and computes subtotal', () {
      final cart = CartState();
      cart.addItem(item('MI1', 'Espresso', 150));
      cart.addItem(item('MI2', 'Flat White', 150));
      expect(cart.itemCount, 2);
      expect(cart.subtotal, 300);
    });

    test('same product merges into one line, different product does not',
        () {
      final cart = CartState();
      cart.addItem(item('MI1', 'Espresso', 150));
      cart.addItem(item('MI1', 'Espresso', 150));
      expect(cart.items.length, 1);
      expect(cart.items.first.qty, 2);

      // The web POS once served every item with a blank id and merged a 130
      // ETB macchiato into a 65 ETB coffee line. Name and price are part of
      // the line key, so a blank id can split lines but never merge bills.
      cart.addItem(item('', 'Macchiato', 130));
      expect(cart.items.length, 2);
      expect(cart.subtotal, 430);
    });

    test('modifiers split lines and add to the unit price', () {
      final cart = CartState();
      const extra = MenuModifier(name: 'Extra shot', priceDelta: 30);
      cart.addItem(item('MI1', 'Espresso', 150));
      cart.addItem(item('MI1', 'Espresso', 150), selected: const [extra]);
      expect(cart.items.length, 2);
      expect(cart.subtotal, 330);
    });

    test('decrement below one removes the line', () {
      final cart = CartState();
      cart.addItem(item('MI1', 'Espresso', 150));
      final line = cart.items.first;
      cart.decrementQty(line);
      expect(cart.isEmpty, true);
    });

    test('delivery fee only rides on delivery orders', () {
      final cart = CartState();
      cart.addItem(item('MI1', 'Espresso', 150));
      cart.setOrderType('delivery');
      cart.setDeliveryFee(60);
      expect(cart.grandTotal(), 210);
      cart.setOrderType('dine-in');
      expect(cart.grandTotal(), 150);
    });

    test('summary string matches the format the kitchen board parses', () {
      final cart = CartState();
      cart.addItem(item('MI1', 'Espresso', 150));
      cart.addItem(item('MI2', 'Kitfo', 350),
          selected: const [MenuModifier(name: 'Extra mitmita')]);
      expect(cart.itemsSummary, '1xEspresso, 1xKitfo [Extra mitmita]');
    });
  });

  group('money', () {
    // The web POS formats prices as `ETB ${n.toFixed(0)}` — whole birr,
    // no separators. Quick-tender buttons use toLocaleString (grouped).
    test('formats birr as whole numbers, no separators', () {
      expect(money(0), 'ETB 0');
      expect(money(150), 'ETB 150');
      expect(money(12345.5), 'ETB 12346');
      expect(money(1234567.89), 'ETB 1234568');
    });

    test('tender labels group thousands like toLocaleString', () {
      expect(moneyGroup(1000), 'ETB 1,000');
      expect(moneyGroup(704), 'ETB 704');
    });
  });

  group('FufutOrder', () {
    test('parses legacy rows: items as string, snake_case columns', () {
      final o = FufutOrder.fromJson({
        'id': 'Oabc123',
        'status': 'new',
        'type': 'dine-in',
        'table_id': '7',
        'total': '210.5',
        'payment': 'unpaid',
        'items': '2x Espresso, 1x Kitfo',
        'created': '2026-08-06 01:55:46',
      });
      expect(o.id, 'Oabc123');
      expect(o.tableNum, '7');
      expect(o.total, 210.5);
      expect(o.isPaid, false);
      expect(o.items, isEmpty);
      expect(o.itemsRaw, '2x Espresso, 1x Kitfo');
    });

    test('parses structured orderItems and payment status', () {
      final o = FufutOrder.fromJson({
        'id': 'Ox1',
        'status': 'ready',
        'total': 300,
        'payment': 'cash',
        'payment_status': 'paid',
        'items': [
          {
            'name': 'Espresso',
            'qty': 2,
            'basePrice': 150,
            'lineTotal': 300,
            'menuItemId': 'MI1',
            'modifiers': [
              {'name': 'Extra shot', 'priceDelta': 30}
            ],
          }
        ],
      });
      expect(o.isPaid, true);
      expect(o.items.length, 1);
      expect(o.items.first.qty, 2);
      expect(o.items.first.modifiers.first['name'], 'Extra shot');
    });
  });
}
