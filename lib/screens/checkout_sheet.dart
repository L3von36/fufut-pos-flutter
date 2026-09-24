import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/cart.dart';
import '../state/catalog_providers.dart';
import '../theme.dart';
import '../widgets/backoffice.dart';
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
class ReviewSheet extends ConsumerStatefulWidget {
  const ReviewSheet({super.key});

  @override
  ConsumerState<ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends ConsumerState<ReviewSheet> {
  bool _sending = false;

  /// The shared tables fetch — the review sheet used to keep its own copy
  /// (the eighth independent tables fetch in the app).
  List<CafeTable> get _tables =>
      ref.watch(tablesOnceProvider).value ?? const <CafeTable>[];

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartProvider);
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
    final cart = ref.read(cartProvider);
    final result = await showModalBottomSheet<PaymentResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Pal.of(context).surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      builder: (_) => const PaymentSheet(),
    );
    if (result == null || !mounted) return;
    final line = result.primary;

    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final overlay = Pal.of(context).overlay;
    final effTotal =
        (cart.grandTotal() + result.tip - result.discount)
            .clamp(0, double.infinity).toDouble();
    setState(() => _sending = true);
    try {
      await _claimTableIfDineIn(messenger);
      final id = await app.api.chargeNow(
        itemsSummary: cart.itemsSummary,
        lines: cart.serializedLines,
        subtotal: cart.subtotal,
        total: effTotal,
        orderType: cart.orderType,
        payment: line,
        paymentLabel: result.breakdown.map((p) => p.method).toSet().join('+'),
        tableNum: cart.tableNum,
        customer: cart.customerName,
        customerPhone: cart.customerPhone,
        notes: cart.notes,
        tip: result.tip,
        discount: result.discount,
        breakdown: result.breakdown,
        discountReason: _discountReasonOf(result),
      );
      cart.clear();
      // Close the review sheet, then raise the success state above the app.
      navigator.pop();
      navigator.push(PageRouteBuilder(
        opaque: false,
        barrierDismissible: true,
        barrierColor: overlay,
        pageBuilder: (_, __, ___) =>
            SuccessSheet(orderId: id, total: effTotal),
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

  static String? _discountReasonOf(PaymentResult result) =>
      result.discount > 0 ? 'discount applied at checkout' : null;

  /// Dine-in: claim the table first, same rule as the cart panel.
  Future<void> _claimTableIfDineIn(ScaffoldMessengerState messenger) async {
    final cart = ref.read(cartProvider);
    final app = ref.read(appStateProvider);
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

class _ReviewLine extends ConsumerWidget {
  final CartLine line;
  const _ReviewLine({required this.line});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.read(cartProvider);
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
                () => ref.read(cartProvider).addItem(
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

class PaymentSheet extends ConsumerStatefulWidget {
  /// When non-null, the sheet charges exactly this amount and does not
  /// touch the cart state (discount editing hides — the check's totals are
  /// already on the server; tip stays available, like the web settle flow).
  final double? fixedTotal;

  const PaymentSheet({super.key, this.fixedTotal});

  @override
  ConsumerState<PaymentSheet> createState() => _PaymentSheetState();
}

/// What the payment sheet hands back — one primary leg (or a full split set)
/// plus the tip and manager discount the caller bakes into the totals.
class PaymentResult {
  final PaymentLine primary;
  final List<PaymentLine> splits; // empty = single payment
  final double tip;
  final double discount;

  const PaymentResult({
    required this.primary,
    this.splits = const [],
    this.tip = 0,
    this.discount = 0,
  });

  List<PaymentLine> get breakdown =>
      splits.isNotEmpty ? splits : [primary];
}

class _PaymentSheetState extends ConsumerState<PaymentSheet> {
  static const _methods = [
    ('cash', 'Cash', Icons.payments_outlined),
    ('card', 'Card', Icons.credit_card),
    ('mobile', 'Mobile Money', Icons.smartphone),
    ('telebirr', 'Telebirr', Icons.phone_android),
    ('cbe', 'CBE Birr', Icons.grid_view_outlined),
    ('bank', 'Bank Transfer', Icons.account_balance_outlined),
  ];
  static const _digitalMethods = {'telebirr', 'cbe', 'bank', 'mobile'};

  final _tender = TextEditingController();
  final _reference = TextEditingController();
  final _tipCustom = TextEditingController();
  final _discountC = TextEditingController();
  final _discountReason = TextEditingController();
  String _method = 'cash';
  String _tipMode = 'none'; // none | p10 | p15 | fixed
  String _discountMode = 'none'; // none | p10 | p20 | fixed
  bool _splitting = false;
  final List<(String, TextEditingController)> _splitLegs = [];

  bool get _isManager =>
      ref.read(appStateProvider).roleKey == 'manager';

  @override
  void initState() {
    super.initState();
    if (widget.fixedTotal == null) {
      final cart = ref.read(cartProvider);
      _method = cart.paymentMethod;
      _tender.text =
          cart.tendered > 0 ? cart.tendered.toStringAsFixed(0) : '';
    }
  }

  @override
  void dispose() {
    _reference.dispose();
    _tipCustom.dispose();
    _discountC.dispose();
    _discountReason.dispose();
    for (final (_, c) in _splitLegs) {
      c.dispose();
    }
    super.dispose();
  }

  /// The base the tip/discount arithmetic works on: the bill itself.
  double get _base => widget.fixedTotal ?? ref.read(cartProvider).grandTotal();

  double get _tipValue {
    switch (_tipMode) {
      case 'p10':
        return _r2(_base * 0.10);
      case 'p15':
        return _r2(_base * 0.15);
      case 'fixed':
        return _r2(double.tryParse(_tipCustom.text) ?? 0);
      default:
        return 0;
    }
  }

  double get _discountValue {
    if (!_isManager) return 0;
    final v = double.tryParse(_discountC.text) ?? 0;
    switch (_discountMode) {
      case 'p10':
        return _r2(_base * 0.10);
      case 'p20':
        return _r2(_base * 0.20);
      case 'fixed':
        return _r2(v);
      default:
        return 0;
    }
  }

  double get _total => (_base + _tipValue - _discountValue)
      .clamp(0, double.infinity).toDouble();

  double get _tenderedValue => double.tryParse(_tender.text) ?? 0;

  double get _splitRemaining {
    final paid = _splitLegs
        .map((leg) => double.tryParse(leg.$2.text) ?? 0)
        .fold<double>(0, (s, v) => s + v);
    return _r2(_total - paid);
  }

  bool get _splitValid =>
      _splitLegs.isNotEmpty &&
      _splitLegs.every((leg) => (double.tryParse(leg.$2.text) ?? 0) > 0) &&
      _splitRemaining.abs() <= 0.005;

  bool get _canPay {
    if (_splitting) return _splitValid;
    if (_method == 'cash') return _tenderedValue + 0.005 >= _total;
    return true;
  }

  double get _change =>
      _tenderedValue > _total ? _tenderedValue - _total : 0;

  static double _r2(double v) => (v * 100).roundToDouble() / 100;

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
            const SizedBox(height: 8),
            _tipCard(pal),
            if (_isManager && widget.fixedTotal == null) ...[
              const SizedBox(height: 6),
              _discountCard(pal),
            ],
            const SizedBox(height: 8),
            if (_splitting) ...[
              _splitCard(pal),
            ] else ...[
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
                if (_digitalMethods.contains(_method)) _referencePanel(pal),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
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
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: InkWell(
                    onTap: () => setState(() {
                      _splitting = true;
                      if (_splitLegs.isEmpty) {
                        _splitLegs.add(('cash', TextEditingController()));
                        _splitLegs.add(('telebirr', TextEditingController()));
                      }
                    }),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: pal.sunken.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: pal.border),
                      ),
                      child: Row(children: [
                        Icon(Icons.call_split, size: 14, color: pal.muted),
                        const SizedBox(width: 6),
                        Text('Split the bill across methods',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 11.5, color: pal.body)),
                        const Spacer(),
                        Text('SPLIT',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: pal.primary)),
                      ]),
                    ),
                  ),
                ),
              ]),
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

  /// Tip card — none / 10% / 15% / fixed (the web CheckoutView tip presets).
  Widget _tipCard(Pal pal) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: pal.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.volunteer_activism_outlined,
                size: 13, color: pal.gold),
            const SizedBox(width: 5),
            Text('TIP — GOES TO STAFF, NOT THE HOUSE',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.7,
                    color: pal.muted)),
            const Spacer(),
            if (_tipValue > 0)
              Text('+${money(_tipValue)}',
                  style: T.mono.copyWith(
                      fontSize: 11, fontWeight: FontWeight.w700,
                      color: pal.gold)),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            for (final (mode, label) in [
              ('none', 'None'), ('p10', '10%'), ('p15', '15%'),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: InkWell(
                  onTap: () => setState(() => _tipMode = mode),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: _tipMode == mode ? pal.gold : pal.sunken,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(label,
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: _tipMode == mode
                                ? Colors.white : pal.body)),
                  ),
                ),
              ),
            SizedBox(
              width: 92,
              height: 26,
              child: TextField(
                controller: _tipCustom,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [DecimalTextInputFormatter()],
                onChanged: (_) => setState(() => _tipMode = 'fixed'),
                style: T.mono.copyWith(fontSize: 11, color: pal.heading),
                decoration: InputDecoration(
                    hintText: 'ETB fixed',
                    hintStyle: TextStyle(
                        fontFamily: kFontMono,
                        fontSize: 9.5, color: pal.faint),
                    isDense: true,
                    filled: true,
                    fillColor: pal.sunken,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 5)),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  /// Manager discount card — the web discount section is manager-only, and
  /// so is this one.
  Widget _discountCard(Pal pal) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: pal.dangerBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.percent, size: 13, color: pal.danger),
            const SizedBox(width: 5),
            Text('MANAGER DISCOUNT',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.7,
                    color: pal.muted)),
            const Spacer(),
            if (_discountValue > 0)
              Text('−${money(_discountValue)}',
                  style: T.mono.copyWith(
                      fontSize: 11, fontWeight: FontWeight.w700,
                      color: pal.danger)),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            for (final (mode, label) in [
              ('none', 'None'), ('p10', '10%'), ('p20', '20%'),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: InkWell(
                  onTap: () => setState(() => _discountMode = mode),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: _discountMode == mode ? pal.danger : pal.sunken,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(label,
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: _discountMode == mode
                                ? Colors.white : pal.body)),
                  ),
                ),
              ),
            SizedBox(
              width: 74,
              height: 26,
              child: TextField(
                controller: _discountC,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [DecimalTextInputFormatter()],
                onChanged: (_) => setState(() => _discountMode = 'fixed'),
                style: T.mono.copyWith(fontSize: 11, color: pal.heading),
                decoration: InputDecoration(
                    hintText: 'ETB',
                    hintStyle: TextStyle(
                        fontFamily: kFontMono,
                        fontSize: 9.5, color: pal.faint),
                    isDense: true,
                    filled: true,
                    fillColor: pal.sunken,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 5)),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: _discountReason,
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 10.5, color: pal.heading),
                decoration: InputDecoration(
                    hintText: 'Reason (audited)',
                    hintStyle: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 9.5, color: pal.faint),
                    isDense: true,
                    filled: true,
                    fillColor: pal.sunken,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 5)),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  /// Digital reference panel — the Telebirr / CBE / bank reference the web
  /// payment panel collects (its receipt auto-verify rides the browser; the
  /// reference number is the portable half).
  Widget _referencePanel(Pal pal) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: _reference,
        style: T.mono.copyWith(fontSize: 12, color: pal.heading),
        decoration: InputDecoration(
            labelText: 'Reference / transaction number (optional)',
            labelStyle: TextStyle(
                fontFamily: kFontBody, fontSize: 10.5, color: pal.muted),
            isDense: true,
            filled: true,
            fillColor: pal.sunken),
      ),
    );
  }

  /// Split card — per-method legs with the remaining tracker; valid when
  /// the legs land on the total (the web split-bill contract).
  Widget _splitCard(Pal pal) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: _splitValid ? pal.successBorder : pal.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.call_split, size: 14, color: pal.primary),
            const SizedBox(width: 5),
            Expanded(
              child: Text('SPLIT BILL — ${_splitLegs.length} LEGS',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.7,
                      color: pal.muted)),
            ),
            InkWell(
              onTap: () => setState(() => _splitting = false),
              child: Text('Close',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: pal.muted)),
            ),
          ]),
          const SizedBox(height: 8),
          for (var i = 0; i < _splitLegs.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                SizedBox(
                  width: 120,
                  height: 30,
                  child: DropdownButtonFormField<String>(
                    initialValue: _splitLegs[i].$1,
                    isDense: true,
                    dropdownColor: pal.surface,
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 11, color: pal.heading),
                    decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: pal.sunken,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6)),
                    items: [
                      for (final (value, label, _) in _methods)
                        DropdownMenuItem(value: value, child: Text(label)),
                    ],
                    onChanged: (v) =>
                        setState(() => _splitLegs[i] =
                            (v ?? 'cash', _splitLegs[i].$2)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: SizedBox(
                    height: 30,
                    child: TextField(
                      controller: _splitLegs[i].$2,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [DecimalTextInputFormatter()],
                      onChanged: (_) => setState(() {}),
                      style: T.mono.copyWith(
                          fontSize: 11.5, color: pal.heading),
                      decoration: InputDecoration(
                          hintText: 'Amount ETB',
                          hintStyle: TextStyle(
                              fontFamily: kFontMono,
                              fontSize: 9.5, color: pal.faint),
                          isDense: true,
                          filled: true,
                          fillColor: pal.sunken),
                    ),
                  ),
                ),
                if (_splitLegs.length > 1)
                  InkWell(
                    onTap: () => setState(() {
                      _splitLegs[i].$2.dispose();
                      _splitLegs.removeAt(i);
                    }),
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: Icon(Icons.close,
                          size: 13, color: pal.danger),
                    ),
                  ),
              ]),
            ),
          RowAction('+ Add leg',
              () => setState(() => _splitLegs.add(
                  ('cash', TextEditingController())))),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: _splitRemaining.abs() <= 0.005
                  ? pal.successBg
                  : pal.warningBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: _splitRemaining.abs() <= 0.005
                      ? pal.successBorder
                      : pal.warningBorder),
            ),
            child: Row(children: [
              Text('REMAINING',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.7,
                      color: pal.muted)),
              const Spacer(),
              Text(money(_splitRemaining),
                  style: T.price.copyWith(
                      fontSize: 14,
                      color: _splitRemaining.abs() <= 0.005
                          ? pal.success
                          : pal.warning)),
            ]),
          ),
        ],
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
    if (_splitting) {
      final splits = [
        for (final (method, c) in _splitLegs)
          PaymentLine(
            method: method,
            amount: double.tryParse(c.text) ?? 0,
            reference: _digitalMethods.contains(method) &&
                    _reference.text.trim().isNotEmpty
                ? _reference.text.trim()
                : null,
          ),
      ];
      Navigator.of(context).pop(PaymentResult(
        primary: splits.first,
        splits: splits,
        tip: _tipValue,
        discount: _discountValue,
      ));
      return;
    }
    final line = PaymentLine(
      method: _method,
      amount: _total,
      tendered: _method == 'cash' ? _tenderedValue : null,
      change: _method == 'cash'
          ? (_tenderedValue > _total ? _tenderedValue - _total : 0)
          : null,
      reference: _digitalMethods.contains(_method) &&
              _reference.text.trim().isNotEmpty
          ? _reference.text.trim()
          : null,
    );
    if (widget.fixedTotal == null && context.mounted) {
      final cart = ref.read(cartProvider);
      cart.setPaymentMethod(_method);
      if (_method == 'cash') cart.setTendered(_tenderedValue);
    }
    Navigator.of(context).pop(PaymentResult(
      primary: line,
      tip: _tipValue,
      discount: _discountValue,
    ));
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
