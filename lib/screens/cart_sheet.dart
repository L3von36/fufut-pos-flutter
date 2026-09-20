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

/// The check — a port of the web POS cart panel.
///
/// Rendered three ways by the same widget tree:
///  * [CartPill] — the floating teal pill on phones,
///  * [CartPanel] in a modal bottom sheet (≤500px wide, 24px top radius),
///  * [CartPanel] docked (`docked: true`) as the 340px right column on
///    wide landscape screens.
///
/// Lines have the circular −/+ steppers and ✕-with-undo of the web cart;
/// the action pair is "Send to Kitchen" + "Checkout" for dine-in and
/// flips to "Take Payment" first for takeaway/delivery.
class CartPill extends StatelessWidget {
  final VoidCallback onOpenCart;
  const CartPill({super.key, required this.onOpenCart});

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartState>();
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        alignment: Alignment.center,
        child: Material(
          color: const Color(0xFF0A4A47), // teal-800
          borderRadius: BorderRadius.circular(24),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpenCart,
            child: Container(
              constraints: const BoxConstraints(minWidth: 240),
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x4D073735),
                      blurRadius: 32,
                      offset: Offset(0, 8)),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(Icons.shopping_cart_outlined,
                          size: 26, color: Colors.white),
                      Positioned(
                        right: -7,
                        top: -7,
                        child: Container(
                          width: 22,
                          height: 22,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFFD6B36A), // gold
                          ),
                          child: Text('${cart.itemCount}',
                              style: const TextStyle(
                                  fontFamily: kFontBody,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF073735))),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(cart.itemCount == 1 ? '1 ITEM' : '${cart.itemCount} ITEMS',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                              color: Colors.white.withValues(alpha: 0.72))),
                      Text(money(cart.grandTotal()),
                          style: T.price.copyWith(fontSize: 15.5, color: Colors.white)),
                    ],
                  ),
                  const SizedBox(width: 12),
                  const Icon(Icons.keyboard_arrow_up,
                      size: 20, color: Colors.white70),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The check body — lines, details, totals, actions.
class CartPanel extends StatefulWidget {
  final bool docked;
  const CartPanel({super.key, this.docked = false});

  @override
  State<CartPanel> createState() => _CartPanelState();
}

class _CartPanelState extends State<CartPanel> {
  List<CafeTable> _tables = [];
  bool _sending = false;
  bool _detailsOpen = false;

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
    final pal = Pal.of(context);
    final dineIn = cart.orderType == 'dine-in';

    return Padding(
      padding: EdgeInsets.fromLTRB(20, widget.docked ? 16 : 0, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.docked) const SheetHandle(),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text('Current Order',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: pal.heading)),
                    ),
                    if (cart.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 9, vertical: 3),
                          decoration: BoxDecoration(
                            color: pal.tintBg,
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text('${cart.itemCount} items',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontFamily: kFontMono,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: pal.primary)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: cart.isEmpty
                    ? null
                    : () => _confirmClear(context, cart),
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(44, 40)),
                icon: Icon(Icons.delete_outline_rounded,
                    size: 16,
                    color: cart.isEmpty ? pal.faint : pal.danger),
                label: Text('Clear',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: cart.isEmpty ? pal.faint : pal.danger)),
              ),
            ],
          ),
          Flexible(
            child: cart.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 36),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: pal.sunken,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.room_service_outlined,
                              size: 30, color: pal.faint),
                        ),
                        const SizedBox(height: 12),
                        Text('Nothing on this order yet',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: pal.heading)),
                        const SizedBox(height: 4),
                        Text(
                          'Tap a dish to add it. Press and hold to add several.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 12.5,
                              color: pal.muted),
                        ),
                      ],
                    ),
                  )
                : ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(top: 4),
                    children: [
                      ..._buildLines(cart, pal),
                      const SizedBox(height: 10),
                      _buildDetails(cart, pal),
                    ],
                  ),
          ),
          if (cart.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              decoration: BoxDecoration(
                color: pal.sunken,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  _moneyRow('Subtotal', money(cart.subtotal),
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 13,
                          color: pal.muted)),
                  if (cart.orderType == 'delivery' && cart.deliveryFee > 0) ...[
                    const SizedBox(height: 4),
                    _moneyRow('Delivery', money(cart.deliveryFee),
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 13,
                            color: pal.muted)),
                  ],
                  const SizedBox(height: 5),
                  _moneyRow('Total', money(cart.grandTotal()),
                      style: T.price.copyWith(fontSize: 17.5, color: pal.heading)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // Dine-in: kitchen first, then checkout. Takeaway/delivery:
            // payment first — the web's settle-first flip.
            FilledButton.icon(
              onPressed: _sending ? null : (dineIn ? _sendToKitchen : _openReview),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
              icon: Icon(dineIn ? Icons.local_fire_department_rounded : Icons.payments_outlined,
                  size: 20),
              label: Text(dineIn
                  ? 'Send to Kitchen'
                  : 'Take Payment — ${money(cart.grandTotal())}'),
            ),
            const SizedBox(height: 9),
            OutlinedButton.icon(
              onPressed: _sending ? null : (dineIn ? _openReview : _sendToKitchen),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(54)),
              icon: Icon(dineIn ? Icons.payments_outlined : Icons.local_fire_department_rounded,
                  size: 19),
              label: Text(dineIn ? 'Checkout' : 'Send to Kitchen'),
            ),
            const SizedBox(height: 8),
            Text(
              dineIn
                  ? 'Send to Kitchen opens a tab for this table — settle it when they leave.'
                  : 'Take Payment settles the bill immediately; the kitchen copy fires with it.',
              textAlign: TextAlign.center,
              style: TextStyle(fontFamily: kFontBody, fontSize: 11, color: pal.muted),
            ),
          ],
        ],
      ),
    );
  }

  // ── Lines ──────────────────────────────────────────────────────────────────

  List<Widget> _buildLines(CartState cart, Pal pal) {
    final items = cart.items;
    return [
      for (var i = 0; i < items.length; i++)
        _CartLineTile(
          line: items[i],
          showCourse: items[i].course != 'main',
          onRemove: () {
            final line = items[i];
            cart.removeLine(line);
            showUndoOn(
              ScaffoldMessenger.of(context),
              '${line.name} removed',
              () => cart.insertLine(i, line),
            );
          },
        ),
    ];
  }

  // ── Details (who / where) ──────────────────────────────────────────────────

  Widget _buildDetails(CartState cart, Pal pal) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: pal.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: _detailsOpen,
          onExpansionChanged: (v) => setState(() => _detailsOpen = v),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          iconColor: pal.muted,
          collapsedIconColor: pal.muted,
          title: Text('Order details',
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: pal.body)),
          subtitle: Text(
            cart.orderType == 'dine-in'
                ? (cart.tableNum.isEmpty
                    ? 'Dine-in · no table picked'
                    : 'Dine-in · Table ${cart.tableNum}')
                : '${cart.orderType == 'takeaway' ? 'Takeaway' : 'Delivery'}'
                    '${cart.customerName.isEmpty ? '' : ' · ${cart.customerName}'}',
            style: TextStyle(fontFamily: kFontBody, fontSize: 11.5, color: pal.muted),
          ),
          children: [
            OrderContextEditor(cart: cart, tables: _tables),
          ],
        ),
      ),
    );
  }

  Widget _moneyRow(String label, String value, {TextStyle? style}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: style),
        Text(value, style: style),
      ],
    );
  }

  // ── Clear-all confirm ──────────────────────────────────────────────────────

  void _confirmClear(BuildContext context, CartState cart) {
    final pal = Pal.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: pal.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHandle(),
              const Text('🗑️',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 34)),
              const SizedBox(height: 10),
              Text('Clear All Items?',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: pal.heading)),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () {
                  cart.clear();
                  Navigator.pop(sheetCtx);
                },
                style: FilledButton.styleFrom(
                    backgroundColor: pal.danger,
                    minimumSize: const Size.fromHeight(52)),
                child: const Text('Yes, Clear All'),
              ),
              const SizedBox(height: 9),
              OutlinedButton(
                onPressed: () => Navigator.pop(sheetCtx),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52)),
                child: const Text('Keep Items'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Actions ────────────────────────────────────────────────────────────────

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
      HapticFeedback.mediumImpact();
      navigator.pop();
      showInfoOn(messenger, 'Order ${shortId(id)} sent to kitchen!');
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

  /// Checkout → the web's review step, then payment, then the success state.
  Future<void> _openReview() async {
    final cart = context.read<CartState>();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Pal.of(context).surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      builder: (_) => ChangeNotifierProvider.value(
        value: cart,
        child: const ReviewSheet(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// One cart line — neutral-50 card, circular steppers, ✕ with undo.
// ─────────────────────────────────────────────────────────────────────────────

class _CartLineTile extends StatelessWidget {
  final CartLine line;
  final bool showCourse;
  final VoidCallback onRemove;

  const _CartLineTile({
    required this.line,
    required this.showCourse,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final cart = context.read<CartState>();
    final pal = Pal.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: pal.sunken,
        borderRadius: BorderRadius.circular(12),
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
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: pal.heading)),
                if (line.selectedModifiers.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    line.selectedModifiers.map((m) => m.name).join(', '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: kFontBody, fontSize: 11, color: pal.muted),
                  ),
                ],
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(money(line.unitPrice),
                        style: T.mono.copyWith(fontSize: 11, color: pal.muted)),
                    if (showCourse) ...[
                      const SizedBox(width: 7),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: pal.tintBg,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(line.course.toUpperCase(),
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.4,
                                color: pal.primary)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          _RoundStepper(
            icon: Icons.remove_rounded,
            onTap: () => cart.decrementQty(line),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('${line.qty}',
                style: T.price.copyWith(fontSize: 14.5)),
          ),
          _RoundStepper(
            icon: Icons.add_rounded,
            onTap: () => cart.incrementQty(line),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 70,
            child: Text(money(line.lineTotal),
                textAlign: TextAlign.end,
                style: T.mono.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: pal.heading)),
          ),
          const SizedBox(width: 6),
          _RoundStepper(
            icon: Icons.close_rounded,
            danger: true,
            onTap: onRemove,
          ),
        ],
      ),
    );
  }
}

/// 36px circular stepper button — 1.5px border, primary fill on press.
class _RoundStepper extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;

  const _RoundStepper({required this.icon, required this.onTap, this.danger = false});

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
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: pal.borderStrong, width: 1.5),
          ),
          child: Icon(icon, size: 17, color: danger ? pal.danger : pal.body),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Who/where editor — kept from the first build (the text controllers must
// live exactly as long as the panel, or every rebuild restarts the cursor).
// ─────────────────────────────────────────────────────────────────────────────

class OrderContextEditor extends StatefulWidget {
  final CartState cart;
  final List<CafeTable> tables;

  const OrderContextEditor({super.key, required this.cart, required this.tables});

  @override
  State<OrderContextEditor> createState() => OrderContextEditorState();
}

class OrderContextEditorState extends State<OrderContextEditor> {
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
    _fee = TextEditingController(
        text: cart.deliveryFee > 0 ? '${cart.deliveryFee}' : '');
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
    final pal = Pal.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('ORDER FOR',
            style: TextStyle(
                fontFamily: kFontBody,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.9,
                color: pal.muted)),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
                value: 'dine-in',
                label: Text('Dine-in'),
                icon: Icon(Icons.table_restaurant, size: 15)),
            ButtonSegment(
                value: 'takeaway',
                label: Text('Takeaway'),
                icon: Icon(Icons.shopping_bag_outlined, size: 15)),
            ButtonSegment(
                value: 'delivery',
                label: Text('Delivery'),
                icon: Icon(Icons.pedal_bike, size: 15)),
          ],
          selected: {cart.orderType},
          onSelectionChanged: (s) => cart.setOrderType(s.first),
          style: SegmentedButton.styleFrom(
            selectedForegroundColor: Colors.white,
            selectedBackgroundColor: pal.primary,
            foregroundColor: pal.body,
            backgroundColor: pal.sunken,
            side: BorderSide(color: pal.border),
            textStyle: const TextStyle(
                fontFamily: kFontBody,
                fontSize: 10.0,
                fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 10),
        if (cart.orderType == 'dine-in') ...[
          if (widget.tables.isEmpty)
            TextField(
              decoration: const InputDecoration(
                  labelText: 'Table number'),
              controller: _table,
              onChanged: cart.setTable,
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in widget.tables)
                  _TableChip(
                    number: t.number,
                    occupied: t.status == 'occupied',
                    selected: cart.tableNum == t.number,
                    onTap: () {
                      _table.text = t.number;
                      cart.setTable(t.number);
                    },
                  ),
              ],
            ),
          const SizedBox(height: 10),
          TextField(
            decoration:
                const InputDecoration(labelText: 'Guest name (optional)'),
            controller: _customer,
            onChanged: cart.setCustomer,
          ),
        ] else if (cart.orderType == 'takeaway') ...[
          TextField(
            decoration: const InputDecoration(
                labelText: 'Customer name / call number'),
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
            decoration:
                const InputDecoration(labelText: 'Customer name'),
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
            decoration:
                const InputDecoration(labelText: 'Delivery address'),
            controller: _address,
            onChanged: cart.setDeliveryAddress,
          ),
          const SizedBox(height: 8),
          TextField(
            decoration:
                const InputDecoration(labelText: 'Delivery fee (ETB)'),
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

/// Table pill — number, dot-flagged when occupied, teal when chosen.
class _TableChip extends StatelessWidget {
  final String number;
  final bool occupied;
  final bool selected;
  final VoidCallback onTap;

  const _TableChip({
    required this.number,
    required this.occupied,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        constraints: const BoxConstraints(minHeight: 46, minWidth: 48),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? pal.primary : pal.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? pal.primary : pal.borderStrong, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(number,
                style: TextStyle(
                    fontFamily: kFontMono,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : pal.body)),
            if (occupied) ...[
              const SizedBox(width: 5),
              Icon(Icons.circle,
                  size: 7,
                  color: selected
                      ? Colors.white70
                      : Pal.of(context).warning),
            ],
          ],
        ),
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
