import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/cart.dart';
import '../theme.dart';

/// Payment method + cash tender, returning a [PaymentLine] when confirmed.
///
/// Used in two modes:
///  * **Cart-driven** (Charge from the register): the total comes from the
///    cart and the chosen method is remembered as the till's default.
///  * **Fixed-total** (Settle an open tab): the bill is already on the
///    server, so the total is passed in and nothing is written back to the
///    cart — there is no cart in that flow.
///
/// Mirrors the web POS quick-tender logic: cash must cover the bill before
/// Pay unlocks, and change is computed for the waiter to count out. Methods
/// beyond cash/card are the Ethiopian transfer rails the books already
/// reconcile on (telebirr, CBE, bank).
class PaymentSheet extends StatefulWidget {
  /// When non-null, the sheet charges exactly this amount and does not
  /// touch the cart state.
  final double? fixedTotal;

  const PaymentSheet({super.key, this.fixedTotal});

  @override
  State<PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<PaymentSheet> {
  static const _methods = [
    ('cash', 'Cash', Icons.payments_outlined),
    ('card', 'Card', Icons.credit_card),
    ('mobile', 'Mobile', Icons.smartphone),
    ('telebirr', 'Telebirr', Icons.account_balance_wallet_outlined),
    ('cbe', 'CBE Birr', Icons.account_balance_outlined),
    ('bank', 'Bank', Icons.savings_outlined),
  ];

  final _tender = TextEditingController();
  String _method = 'cash';

  @override
  void initState() {
    super.initState();
    if (widget.fixedTotal == null) {
      final cart = context.read<CartState>();
      _method = cart.paymentMethod;
      _tender.text =
          cart.tendered > 0 ? cart.tendered.toStringAsFixed(0) : '';
    }
  }

  double get _total =>
      widget.fixedTotal ?? context.read<CartState>().grandTotal();

  double get _tenderedValue => double.tryParse(_tender.text) ?? 0;

  bool get _canPay {
    if (_method == 'cash') return _tenderedValue + 0.005 >= _total;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Charge ${money(_total)}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final (value, label, icon) in _methods)
                  ChoiceChip(
                    avatar: Icon(icon, size: 16),
                    label: Text(label),
                    selected: _method == value,
                    onSelected: (_) => setState(() => _method = value),
                  ),
              ],
            ),
            if (_method == 'cash') ...[
              const SizedBox(height: 16),
              TextField(
                controller: _tender,
                keyboardType: TextInputType.number,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Cash tendered (ETB)',
                  prefixIcon: Icon(Icons.payments),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final quick in _quickAmounts())
                    OutlinedButton(
                      onPressed: () {
                        _tender.text = quick.toStringAsFixed(0);
                        setState(() {});
                      },
                      child: Text(quick.toStringAsFixed(0)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Change due',
                      style: TextStyle(color: Colors.white54)),
                  Text(
                    money(_tenderedValue > _total
                        ? _tenderedValue - _total
                        : 0),
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF7FD1CE)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _canPay ? _confirm : null,
              icon: const Icon(Icons.check),
              label: Text('Charge ${money(_total)}'),
            ),
          ],
        ),
      ),
    );
  }

  /// Quick tender buttons: the bill itself plus common note sizes.
  List<double> _quickAmounts() {
    final t = _total;
    final set = <double>{t.ceilToDouble(), 50, 100, 200, 500};
    final list = set.where((c) => c >= t).toList()..sort();
    return list;
  }

  void _confirm() {
    final line = PaymentLine(
      method: _method,
      amount: _total,
      tendered: _method == 'cash' ? _tenderedValue : null,
      change: _method == 'cash'
          ? (_tenderedValue > _total ? _tenderedValue - _total : 0)
          : null,
    );
    if (widget.fixedTotal == null && context.mounted) {
      final cart = context.read<CartState>();
      cart.setPaymentMethod(_method);
      if (_method == 'cash') cart.setTendered(_tenderedValue);
    }
    Navigator.of(context).pop(line);
  }
}
