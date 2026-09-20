import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/cart.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'checkout_sheet.dart';

/// The cart drawer: lines, order context, and the two actions — fire the
/// ticket to the kitchen, or go straight to payment.
class CartSheet extends StatefulWidget {
  const CartSheet({super.key});

  @override
  State<CartSheet> createState() => _CartSheetState();
}

class _CartSheetState extends State<CartSheet> {
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
      // The table picker degrades to a free-text field when /tables is not
      // readable for this role — ordering must never block on the floor plan.
    } catch (_) {
      // Same: fail soft.
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartState>();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.92,
      maxChildSize: 0.95,
      builder: (context, scrollCtrl) => Column(
        children: [
          Expanded(
            child: ListView(
              controller: scrollCtrl,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                const Text('Current order',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (cart.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(child: Text('Cart is empty')),
                  )
                else
                  ...cart.items.map((l) => _CartLineTile(line: l)),
                if (cart.isNotEmpty) ...[
                  const Divider(height: 24),
                  _buildOrderContext(cart),
                  const Divider(height: 24),
                  _buildTotals(cart),
                ],
              ],
            ),
          ),
          // ── Actions ────────────────────────────────────────────────────────
          if (cart.isNotEmpty)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _sending
                            ? null
                            : () {
                                cart.clear();
                                Navigator.of(context).pop();
                              },
                        child: const Text('Discard'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: OutlinedButton(
                        onPressed: _sending ? null : _sendToKitchen,
                        child: _sending
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Send to Kitchen'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: _sending ? null : _chargeNow,
                        icon: const Icon(Icons.payments_outlined, size: 18),
                        label: const Text('Charge'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Order context editors ────────────────────────────────────────────────

  Widget _buildOrderContext(CartState cart) {
    return _OrderContextEditor(cart: cart, tables: _tables);
  }

  Widget _buildTotals(CartState cart) {
    final grand = cart.subtotal +
        (cart.orderType == 'delivery' ? cart.deliveryFee : 0);
    return Row(
      children: [
        const Text('Total',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const Spacer(),
        Text(money(grand),
            style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Color(0xFF7FD1CE))),
      ],
    );
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  /// Dine-in: claim the table first — the same order of operations as the
  /// web POS, so a waiter cannot fire a round to a table that is reserved or
  /// already seated.
  Future<bool> _claimTableIfDineIn(ScaffoldMessengerState messenger) async {
    final cart = context.read<CartState>();
    final app = context.read<AppState>();
    if (cart.orderType != 'dine-in' || cart.tableNum.isEmpty) return true;
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
      if (mounted) {
        // Keep the fresh row so a second round does not re-claim.
        final chosen = match;
        setState(() {
          final i = _tables.indexWhere((t) => t.id == chosen.id);
          if (i >= 0) {
            _tables[i] = CafeTable(
              id: chosen.id,
              number: chosen.number,
              section: chosen.section,
              status: 'occupied',
              seats: chosen.seats,
            );
          }
        });
      }
      return true;
    } on ApiError catch (e) {
      showErrorOn(messenger, e);
      return false;
    }
  }

  Future<void> _sendToKitchen() async {
    final cart = context.read<CartState>();
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _sending = true);
    try {
      final ok = await _claimTableIfDineIn(messenger);
      if (!ok) return;
      final id = await app.api.sendToKitchen(
        itemsSummary: cart.itemsSummary,
        lines: cart.serializedLines,
        subtotal: cart.subtotal,
        total: cart.grandTotal(),
        orderType: cart.orderType,
        tableNum: cart.tableNum,
        customer: cart.customerName,
        customerPhone: cart.customerPhone,
        deliveryAddress: cart.deliveryAddress,
        deliveryFee: cart.orderType == 'delivery' ? cart.deliveryFee : 0,
        notes: cart.notes,
      );
      cart.clear();
      navigator.pop();
      showInfoOn(messenger, 'Order ${shortId(id)} sent to kitchen');
    } on ApiError catch (e) {
      if (e.isAuthError) {
        await app.sessionExpired();
      }
      showErrorOn(messenger, e);
    } catch (e) {
      showErrorOn(messenger, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _chargeNow() async {
    final cart = context.read<CartState>();
    final payment = await _openPaymentFlow(cart);
    if (payment == null || !mounted) return;
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _sending = true);
    try {
      final ok = await _claimTableIfDineIn(messenger);
      if (!ok) return;
      final id = await app.api.chargeNow(
        itemsSummary: cart.itemsSummary,
        lines: cart.serializedLines,
        subtotal: cart.subtotal,
        total: cart.grandTotal(),
        orderType: cart.orderType,
        payment: payment,
        paymentLabel: payment.method,
        tableNum: cart.tableNum,
        customer: cart.customerName,
        customerPhone: cart.customerPhone,
        notes: cart.notes,
      );
      cart.clear();
      navigator.pop();
      showInfoOn(messenger, 'Paid — order ${shortId(id)}');
    } on ApiError catch (e) {
      if (e.isAuthError) {
        await app.sessionExpired();
      }
      showErrorOn(messenger, e);
    } catch (e) {
      showErrorOn(messenger, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<PaymentLine?> _openPaymentFlow(CartState cart) async {
    final result = await showModalBottomSheet<PaymentLine>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => ChangeNotifierProvider.value(
        value: cart,
        child: const PaymentSheet(),
      ),
    );
    return result;
  }
}

class _CartLineTile extends StatelessWidget {
  final CartLine line;
  const _CartLineTile({required this.line});

  @override
  Widget build(BuildContext context) {
    final cart = context.read<CartState>();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(line.name,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (line.selectedModifiers.isNotEmpty)
            Text(
              line.selectedModifiers.map((m) => m.name).join(', '),
              style: const TextStyle(fontSize: 12, color: Color(0xFF7FD1CE)),
            ),
          Text(money(line.unitPrice),
              style: const TextStyle(fontSize: 12, color: Colors.white54)),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: () => cart.decrementQty(line),
            icon: const Icon(Icons.remove_circle_outline),
            tooltip: 'Less',
          ),
          Text('${line.qty}',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700)),
          IconButton(
            onPressed: () => cart.incrementQty(line),
            icon: const Icon(Icons.add_circle_outline),
            tooltip: 'More',
          ),
          SizedBox(
            width: 76,
            child: Text(money(line.lineTotal),
                textAlign: TextAlign.end,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

/// Accepts only digits and one decimal point — birr fields stay numeric
/// regardless of keyboard layout.
class DecimalTextInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final t = newValue.text;
    if (t.isEmpty) return newValue;
    final cleaned = t.replaceAll(RegExp(r'[^0-9.]'), '');
    if (cleaned == t) return newValue;
    return TextEditingValue(
      text: cleaned,
      selection: TextSelection.collapsed(offset: cleaned.length),
    );
  }
}

/// The who/where section of the cart, as its own widget so the text
/// controllers live exactly as long as the sheet does — rebuilding the
/// parent would otherwise hand every TextField a fresh controller and
/// restart the cursor mid-word on each keystroke.
class _OrderContextEditor extends StatefulWidget {
  final CartState cart;
  final List<CafeTable> tables;

  const _OrderContextEditor({required this.cart, required this.tables});

  @override
  State<_OrderContextEditor> createState() => _OrderContextEditorState();
}

class _OrderContextEditorState extends State<_OrderContextEditor> {
  late final TextEditingController _table;
  late final TextEditingController _customer;
  late final TextEditingController _phone;
  late final TextEditingController _address;
  late final TextEditingController _fee;
  late final TextEditingController _notes;

  @override
  void initState() {
    super.initState();
    final cart = widget.cart;
    _table = TextEditingController(text: cart.tableNum);
    _customer = TextEditingController(text: cart.customerName);
    _phone = TextEditingController(text: cart.customerPhone);
    _address = TextEditingController(text: cart.deliveryAddress);
    _fee =
        TextEditingController(text: cart.deliveryFee > 0 ? '${cart.deliveryFee}' : '');
    _notes = TextEditingController(text: cart.notes);
  }

  @override
  void dispose() {
    _table.dispose();
    _customer.dispose();
    _phone.dispose();
    _address.dispose();
    _fee.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cart = widget.cart;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Order for',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
                value: 'dine-in',
                label: Text('Dine-in'),
                icon: Icon(Icons.table_restaurant, size: 18)),
            ButtonSegment(
                value: 'takeaway',
                label: Text('Takeaway'),
                icon: Icon(Icons.shopping_bag_outlined, size: 18)),
            ButtonSegment(
                value: 'delivery',
                label: Text('Delivery'),
                icon: Icon(Icons.pedal_bike, size: 18)),
          ],
          selected: {cart.orderType},
          onSelectionChanged: (s) => cart.setOrderType(s.first),
        ),
        const SizedBox(height: 12),
        if (cart.orderType == 'dine-in') ...[
          if (widget.tables.isEmpty)
            TextField(
              decoration: const InputDecoration(
                  labelText: 'Table number',
                  prefixIcon: Icon(Icons.table_bar)),
              controller: _table,
              onChanged: cart.setTable,
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in widget.tables)
                  ChoiceChip(
                    label: Text('${t.number}${t.status == 'occupied' ? ' •' : ''}'),
                    selected: cart.tableNum == t.number,
                    onSelected: (_) => cart.setTable(t.number),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          TextField(
            decoration: const InputDecoration(labelText: 'Guest name (optional)'),
            controller: _customer,
            onChanged: cart.setCustomer,
          ),
        ] else if (cart.orderType == 'takeaway') ...[
          TextField(
            decoration:
                const InputDecoration(labelText: 'Customer name / call number'),
            controller: _customer,
            onChanged: cart.setCustomer,
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: const InputDecoration(
                labelText: 'Phone (for when it is ready)'),
            keyboardType: TextInputType.phone,
            controller: _phone,
            onChanged: cart.setCustomerPhone,
          ),
        ] else ...[
          TextField(
            decoration: const InputDecoration(labelText: 'Customer name'),
            controller: _customer,
            onChanged: cart.setCustomer,
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: const InputDecoration(labelText: 'Phone'),
            keyboardType: TextInputType.phone,
            controller: _phone,
            onChanged: cart.setCustomerPhone,
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: const InputDecoration(labelText: 'Delivery address'),
            controller: _address,
            onChanged: cart.setDeliveryAddress,
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: const InputDecoration(labelText: 'Delivery fee (ETB)'),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
            controller: _fee,
            onChanged: (v) => cart.setDeliveryFee(double.tryParse(v) ?? 0),
          ),
        ],
        const SizedBox(height: 8),
        TextField(
          decoration: const InputDecoration(
              labelText: 'Notes for the kitchen (allergies, prep…)'),
          controller: _notes,
          onChanged: cart.setNotes,
        ),
      ],
    );
  }
}
