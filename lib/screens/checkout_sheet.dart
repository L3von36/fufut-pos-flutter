import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/cart.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'cart_sheet.dart' show DecimalTextInputFormatter, OrderContextEditor;

/// Checkout — the web POS's three steps as stacked sheets.
///
///  * [ReviewSheet]  — "Review Order": type/table/customer editors, line
///    rows with steppers, notes, then *Continue to Payment*.
///  * [PaymentSheet] — "Payment": 3-col method grid (Cash / Card / Mobile /
///    Telebirr / CBE Birr / Bank), quick-tender grid + Exact button, green
///    *Change Due* / gold *Still Need* panel. Also used standalone with
///    `fixedTotal` when settling an open tab from Orders.
///  * [SuccessSheet] — green check circle, "Order Confirmed!", mono id.
class ReviewSheet extends StatefulWidget {
  const ReviewSheet({super.key});

  @override
  State<ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<ReviewSheet> {
  List<CafeTable> _tables = [];
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _loadTables();
  }

  Future<void> _loadTables() async {
    final app = context.read<AppState>();
    try {
      final t = await app.api.tables();
      if (!mounted) return;
      setState(() => _tables = t);
    } on ApiError {
      // Degrade to free-text — ordering must never block on the floor plan.
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartState>();
    final pal = Pal.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            Row(
              children: [
                Expanded(
                  child: Text('Review Order',
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: pal.heading)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: pal.primary,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text('${cart.itemCount}',
                      style: const TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  OrderContextEditor(cart: cart, tables: _tables),
                  const SizedBox(height: 10),
                  ...cart.items.map((l) => _ReviewLine(line: l)),
                  const SizedBox(height: 8),
                  TextField(
                    onChanged: cart.setNotes,
                    decoration: const InputDecoration(
                      hintText: 'Order notes (e.g. no onions on everything)...',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Total',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: pal.heading)),
                Text(money(cart.grandTotal()),
                    style: T.priceBig.copyWith(color: pal.heading)),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 42,
              child: FilledButton.icon(
                onPressed: cart.isEmpty || _sending ? null : _pay,
                icon: _sending
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.arrow_forward, size: 15),
                label: Text(_sending ? 'Sending...' : 'Continue to Payment',
                    style: const TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pay() async {
    final cart = context.read<CartState>();
    final line = await showModalBottomSheet<PaymentLine>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Pal.of(context).surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      builder: (_) => ChangeNotifierProvider.value(
        value: cart,
        child: const PaymentSheet(),
      ),
    );
    if (line == null || !mounted) return;

    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final overlay = Pal.of(context).overlay;
    final paid = cart.grandTotal();
    setState(() => _sending = true);
    try {
      await _claimTableIfDineIn(messenger);
      final id = await app.api.chargeNow(
        itemsSummary: cart.itemsSummary,
        lines: cart.serializedLines,
        subtotal: cart.subtotal,
        total: cart.grandTotal(),
        orderType: cart.orderType,
        payment: line,
        paymentLabel: line.method,
        tableNum: cart.tableNum,
        customer: cart.customerName,
        customerPhone: cart.customerPhone,
        notes: cart.notes,
      );
      cart.clear();
      // Close the review sheet, then raise the success state above the app.
      navigator.pop();
      navigator.push(PageRouteBuilder(
        opaque: false,
        barrierDismissible: true,
        barrierColor: overlay,
        pageBuilder: (_, __, ___) =>
            SuccessSheet(orderId: id, total: paid),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ));
    } on ApiError catch (e) {
      if (e.isAuthError) await app.sessionExpired();
      showErrorOn(messenger, e);
    } catch (e) {
      showErrorOn(messenger, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Dine-in: claim the table first, same rule as the cart panel.
  Future<void> _claimTableIfDineIn(ScaffoldMessengerState messenger) async {
    final cart = context.read<CartState>();
    final app = context.read<AppState>();
    if (cart.orderType != 'dine-in' || cart.tableNum.isEmpty) return;
    CafeTable? match;
    try {
      final tables = _tables.isEmpty ? await app.api.tables() : _tables;
      for (final t in tables) {
        if (t.number == cart.tableNum) {
          match = t;
          break;
        }
      }
      if (match == null) {
        throw ApiError('Table ${cart.tableNum} does not exist');
      }
      if (match.status != 'available') {
        throw ApiError('Table ${cart.tableNum} is not available');
      }
      await app.api.claimTable(match);
    } on ApiError catch (e) {
      showErrorOn(messenger, e);
      rethrow;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Review line — bordered row with steppers, like the web step 1.
// ─────────────────────────────────────────────────────────────────────────────

class _ReviewLine extends StatelessWidget {
  final CartLine line;
  const _ReviewLine({required this.line});

  @override
  Widget build(BuildContext context) {
    final cart = context.read<CartState>();
    final pal = Pal.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: pal.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.name,
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: pal.heading)),
                Text('${money(line.unitPrice)} each',
                    style:
                        T.mono.copyWith(fontSize: 10.5, color: pal.muted)),
              ],
            ),
          ),
          _MiniStepper(
            icon: Icons.remove,
            onTap: () => cart.decrementQty(line),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Text('${line.qty}',
                style: T.price.copyWith(fontSize: 13)),
          ),
          _MiniStepper(
            icon: Icons.add,
            onTap: () => cart.incrementQty(line),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 66,
            child: Text(money(line.lineTotal),
                textAlign: TextAlign.end,
                style: T.mono.copyWith(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: pal.heading)),
          ),
          InkWell(
            onTap: () {
              cart.removeLine(line);
              showUndoOn(
                ScaffoldMessenger.of(context),
                '${line.name} removed',
                () => context.read<CartState>().addItem(
                      MenuItem(
                          id: line.menuItemId ?? '',
                          name: line.name,
                          category: '',
                          price: line.basePrice),
                      selected: line.selectedModifiers,
                      qty: line.qty,
                      course: line.course,
                    ),
              );
            },
            customBorder: const CircleBorder(),
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: Icon(Icons.close, size: 14, color: pal.danger),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStepper extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _MiniStepper({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Ink(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: pal.borderStrong, width: 1),
          ),
          child: Icon(icon, size: 14, color: pal.body),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Payment — method grid, quick tender, change panel.
// ─────────────────────────────────────────────────────────────────────────────

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
    ('mobile', 'Mobile Money', Icons.smartphone),
    ('telebirr', 'Telebirr', Icons.phone_android),
    ('cbe', 'CBE Birr', Icons.grid_view_outlined),
    ('bank', 'Bank Transfer', Icons.account_balance_outlined),
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

  double get _change =>
      _tenderedValue > _total ? _tenderedValue - _total : 0;

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            Row(
              children: [
                Expanded(
                  child: Text('Payment',
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: pal.heading)),
                ),
                Text(money(_total),
                    style: T.price.copyWith(
                        fontSize: 14, color: pal.primary)),
              ],
            ),
            const SizedBox(height: 10),
            // 3-col method card grid.
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              childAspectRatio: 1.55,
              children: [
                for (final (value, label, icon) in _methods)
                  _MethodCard(
                    icon: icon,
                    label: label,
                    active: _method == value,
                    onTap: () => setState(() => _method = value),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (_method == 'cash') ..._cashPanel(pal) else ...[
              Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: pal.sunken.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  children: [
                    Icon(_methods
                        .firstWhere((m) => m.$1 == _method)
                        .$3,
                        size: 24,
                        color: pal.primary),
                    const SizedBox(height: 6),
                    Text(
                      'Collect the ${_methods.firstWhere((m) => m.$1 == _method).$2.toLowerCase()} payment, '
                      'then process it.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 11.5,
                          color: pal.muted),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              height: 42,
              child: FilledButton(
                onPressed: _canPay ? () => _confirm(context) : null,
                style: FilledButton.styleFrom(
                    backgroundColor: pal.primary,
                    disabledBackgroundColor: pal.primary.withValues(alpha: 0.5)),
                child: Text('Process Payment — ${money(_total)}',
                    style: const TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _cashPanel(Pal pal) {
    final covered = _tenderedValue + 0.005 >= _total && _tenderedValue > 0;
    return [
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: pal.sunken.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Amount Due',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: pal.body)),
            Text(money(_total),
                style: T.price.copyWith(fontSize: 15)),
          ],
        ),
      ),
      const SizedBox(height: 8),
      // Quick tender: 4-col grid, mono labels.
      GridView.count(
        crossAxisCount: 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 5,
        crossAxisSpacing: 5,
        childAspectRatio: 2.1,
        children: [
          for (final quick in _quickAmounts())
            OutlinedButton(
              onPressed: () {
                _tender.text = quick.toStringAsFixed(0);
                setState(() {});
              },
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: pal.borderStrong),
                foregroundColor: pal.heading,
                padding: EdgeInsets.zero,
              ),
              child: Text(moneyGroup(quick).replaceFirst('ETB ', ''),
                  style: T.mono.copyWith(
                      fontSize: 12, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
      const SizedBox(height: 5),
      OutlinedButton(
        onPressed: () {
          _tender.text = _total.toStringAsFixed(0);
          setState(() {});
        },
        style: OutlinedButton.styleFrom(
          backgroundColor: pal.tintBg,
          side: BorderSide(color: pal.tintBorder),
          foregroundColor: pal.primary,
          minimumSize: const Size.fromHeight(36),
        ),
        child: Text('Exact (${money(_total)})',
            style: const TextStyle(
                fontFamily: kFontBody,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
      ),
      const SizedBox(height: 6),
      TextField(
        controller: _tender,
        keyboardType: TextInputType.number,
        autofocus: false,
        inputFormatters: [DecimalTextInputFormatter()],
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          labelText: 'Custom amount (ETB)',
        ),
      ),
      const SizedBox(height: 8),
      if (covered)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: pal.successBg,
            border: Border.all(color: pal.successBorder),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('CHANGE DUE',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                      color: pal.muted)),
              Text(money(_change),
                  style: T.price.copyWith(
                      fontSize: 19, color: pal.success)),
            ],
          ),
        )
      else if (_tenderedValue > 0)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: pal.warningBg,
            border: Border.all(color: pal.warningBorder),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('STILL NEED',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                      color: pal.muted)),
              Text(money(_total - _tenderedValue),
                  style: T.price.copyWith(
                      fontSize: 19, color: pal.warning)),
            ],
          ),
        ),
    ];
  }

  /// Quick tender buttons: the bill itself plus common note sizes.
  List<double> _quickAmounts() {
    final t = _total;
    final set = <double>{t.ceilToDouble(), 50, 100, 200, 500};
    final list = set.where((c) => c >= t).toList()..sort();
    return list.take(4).toList();
  }

  void _confirm(BuildContext context) {
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

/// One payment-method tile — 2px border, tint + ring + check when active.
class _MethodCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _MethodCard({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 5),
        decoration: BoxDecoration(
          color: active ? pal.tintBg : pal.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? pal.primary : pal.border,
            width: active ? 1.5 : 1,
          ),
          boxShadow: active
              ? [
                  BoxShadow(
                      color: pal.primary.withValues(alpha: 0.12),
                      blurRadius: 0,
                      spreadRadius: 2),
                ]
              : null,
        ),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon,
                      size: 18,
                      color: active ? pal.primary : pal.body),
                  const SizedBox(height: 5),
                  Text(label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: active ? pal.primary : pal.body)),
                ],
              ),
            ),
            if (active)
              Positioned(
                top: 3,
                right: 3,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle, color: pal.primary),
                  child: const Icon(Icons.check,
                      size: 10, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Success — 80px green circle, confirmed title, mono order id.
// ─────────────────────────────────────────────────────────────────────────────

class SuccessSheet extends StatelessWidget {
  final String orderId;
  final double total;
  const SuccessSheet({super.key, required this.orderId, required this.total});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: pal.surface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: pal.successBg,
                  border: Border.all(color: pal.success, width: 2.5),
                ),
                child:
                    Icon(Icons.check, size: 32, color: pal.success),
              ),
              const SizedBox(height: 12),
              Text('Order Confirmed!',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: pal.heading)),
              if (orderId.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text('Order ${shortId(orderId)}',
                    style: T.mono.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: pal.primary)),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: 260,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('New Order'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
