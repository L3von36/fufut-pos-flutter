import 'package:flutter_test/flutter_test.dart';

import 'package:fufut_pos/models/models.dart';

void main() {
  group('FufutPayment parsing', () {
    test('parses a recorded transfer awaiting the till', () {
      final p = FufutPayment.fromJson({
        'id': 'PM123',
        'order_id': 'ORD9',
        'method': 'telebirr',
        'amount': '320.5',
        'reference': 'TB-9931-KK',
        'status': 'recorded',
        'collected_by_name': 'Yonas',
      });
      expect(p.id, 'PM123');
      expect(p.orderId, 'ORD9');
      expect(p.method, 'telebirr');
      expect(p.amount, 320.5);
      expect(p.reference, 'TB-9931-KK');
      expect(p.needsVerification, isTrue,
          reason: "status 'recorded' = the guest says they sent it");
    });

    test('a verified cash payment never needs verification', () {
      final p = FufutPayment.fromJson({
        'id': 'PM124',
        'order_id': 'ORD9',
        'method': 'cash',
        'amount': 100,
        'status': 'verified',
      });
      expect(p.needsVerification, isFalse);
    });

    test('listFrom survives a bad row and a non-list payload', () {
      final rows = FufutPayment.listFrom([
        {'id': 'PM1', 'order_id': 'O1', 'method': 'cash', 'amount': 10},
        'garbage',
        {'id': 'PM2', 'order_id': 'O2', 'method': 'bank', 'amount': '55'},
      ]);
      expect(rows.map((p) => p.id), ['PM1', 'PM2']);
      expect(FufutPayment.listFrom({'unexpected': 'shape'}), isEmpty);
    });
  });

  group('PaymentChannel parsing', () {
    test('carries the account the floor tells the guest to send to', () {
      final c = PaymentChannel.fromJson({
        'method': 'telebirr',
        'label': 'Telebirr',
        'account': '+251 900 000 000',
        'holder': 'Fufut Coffee',
      });
      expect(c.account, '+251 900 000 000');
      expect(c.holder, 'Fufut Coffee');
    });
  });

  group('Order bill-leg parsing (migration 028 columns)', () {
    test('FufutOrder reads the order-level bill stamps', () {
      final o = FufutOrder.fromJson({
        'id': 'ORD1',
        'status': 'served',
        'created': '2026-09-25 08:00:00',
        'paid_at': '2026-09-25T09:10:00.000Z',
        'bill_requested_at': '2026-09-25T08:55:00.000Z',
        'bill_method': 'telebirr',
        'cleared_at': '2026-09-25T09:40:00.000Z',
      });
      expect(o.paidAt, '2026-09-25T09:10:00.000Z');
      expect(o.billRequestedAt, '2026-09-25T08:55:00.000Z');
      expect(o.billMethod, 'telebirr');
      expect(o.clearedAt, '2026-09-25T09:40:00.000Z');
    });

    test('CafeTable reads bill_method for the floor chip', () {
      final t = CafeTable.fromJson({
        'id': 'T-2',
        'number': 2,
        'status': 'occupied',
        'bill_requested_at': '2026-09-25T08:55:00.000Z',
        'bill_method': 'cash',
      });
      expect(t.billRequested, isTrue);
      expect(t.billMethod, 'cash');
      expect(t.copyWith(billMethod: '').billMethod, '');
    });
  });
}
