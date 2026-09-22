/// Cart state — a faithful port of the web POS `stores/order.js` cart half.
///
/// Two invariants carried over:
///  * Line identity includes name, price, modifiers and notes, so a blank or
///    duplicated menu id can never silently merge two different products
///    (the worst case becomes a visible split line, not a wrong total).
///  * The cart persists to disk for one shift's length (12h), so a flat
///    battery does not eat an order a waiter already read back to the guest.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

class CartState extends ChangeNotifier {
  final List<CartLine> _items = [];

  // Order context
  String orderType = 'dine-in'; // dine-in | takeaway | delivery
  String tableNum = '';
  String customerName = '';
  String customerPhone = '';
  String deliveryAddress = '';
  double deliveryFee = 0;
  String notes = '';

  // Add-a-round context — the web orderStore's isAddRound / activeOpenOrderId.
  // Set by the floor plan when the table being ordered against already has an
  // open check: the next Send to Kitchen PATCHes the open ticket instead of
  // POSTing a duplicate one, and dessert lands on the same bill.
  bool isAddRound = false;
  String? activeOpenOrderId;

  /// Wire the cart to an existing open check ("Add Round" from the floor
  /// plan). Clearing first so no leftover line from a previous order leaks
  /// into this tab.
  void startAddRound({required String orderId, required String tableNum}) {
    _items.clear();
    isAddRound = true;
    activeOpenOrderId = orderId;
    orderType = 'dine-in';
    this.tableNum = tableNum;
    _persist();
    notifyListeners();
  }

  /// Start a fresh order for a table (no open check to attach to).
  void startNewOrderForTable(String tableNum) {
    _items.clear();
    isAddRound = false;
    activeOpenOrderId = null;
    orderType = 'dine-in';
    this.tableNum = tableNum;
    _persist();
    notifyListeners();
  }

  /// Whether Send to Kitchen should PATCH the open ticket instead of POSTing
  /// a new one.
  bool get addingRound => isAddRound && activeOpenOrderId != null;

  // Payment
  String paymentMethod = 'cash'; // cash | card | mobile | telebirr | cbe | bank
  double tendered = 0;

  CartState() {
    _restore();
  }

  // ── Getters ───────────────────────────────────────────────────────────────

  List<CartLine> get items => List.unmodifiable(_items);

  double get subtotal =>
      _items.fold<double>(0, (s, l) => s + l.lineTotal);

  /// What the guest actually pays: food plus the delivery fee the driver
  /// settles with the cashier. The fee is not discountable and never part of
  /// a tip base — same rule as the web POS.
  double grandTotal() =>
      subtotal + (orderType == 'delivery' ? (deliveryFee > 0 ? deliveryFee : 0) : 0);

  int get itemCount => _items.fold<int>(0, (s, l) => s + l.qty);

  bool get isEmpty => _items.isEmpty;

  bool get isNotEmpty => _items.isNotEmpty;

  double get changeDue {
    if (paymentMethod != 'cash') return 0;
    final t = tendered;
    return t > subtotal ? t - subtotal : 0;
  }

  bool get canPay {
    if (isEmpty) return false;
    if (paymentMethod == 'cash' && tendered + 0.005 < subtotal) return false;
    return true;
  }

  // ── Cart actions ──────────────────────────────────────────────────────────

  String _dedupKey(String? menuItemId, List<MenuModifier> mods, String notes,
      String name, double price, String course) {
    final modNames = (mods.map((m) => m.name).toList()..sort()).join('|');
    return [
      menuItemId ?? '',
      name,
      price,
      modNames,
      notes.trim().toLowerCase(),
      course,
    ].join('::');
  }

  void addItem(MenuItem item,
      {List<MenuModifier> selected = const [],
      int qty = 1,
      String course = 'main'}) {
    if (qty < 1) return;
    final key = _dedupKey(
        item.id, selected, '', item.name, item.price, course);
    CartLine? existing;
    for (final l in _items) {
      if (l.uid == key) {
        existing = l;
        break;
      }
    }
    if (existing != null) {
      existing.qty += qty;
    } else {
      _items.add(CartLine(
        uid: key,
        menuItemId: item.id,
        name: item.name,
        basePrice: item.price,
        qty: qty,
        selectedModifiers: selected,
        course: course,
      ));
    }
    _persist();
    notifyListeners();
  }

  /// Total quantity of a menu item across all its lines (with any
  /// modifiers) — drives the in-cart count badge on the menu card.
  int qtyForItem(String? menuItemId) {
    if (menuItemId == null || menuItemId.isEmpty) return 0;
    return _items.fold<int>(
        0, (s, l) => l.menuItemId == menuItemId ? s + l.qty : s);
  }

  /// Re-inserts a line at its old position — the Undo of the cart's
  /// remove action, same contract as the web POS's 3s undo toast.
  void insertLine(int index, CartLine line) {
    final i = index.clamp(0, _items.length);
    _items.insert(i, line);
    _persist();
    notifyListeners();
  }

  void incrementQty(CartLine line) {
    line.qty++;
    _persist();
    notifyListeners();
  }

  void decrementQty(CartLine line) {
    if (line.qty <= 1) {
      _items.remove(line);
    } else {
      line.qty--;
    }
    _persist();
    notifyListeners();
  }

  void removeLine(CartLine line) {
    _items.remove(line);
    _persist();
    notifyListeners();
  }

  void clear() {
    _items.clear();
    orderType = 'dine-in';
    tableNum = '';
    customerName = '';
    customerPhone = '';
    deliveryAddress = '';
    deliveryFee = 0;
    notes = '';
    paymentMethod = 'cash';
    tendered = 0;
    // The round has been fired; the next order starts fresh (the web's
    // clearOrder resets both flags with the cart).
    isAddRound = false;
    activeOpenOrderId = null;
    _persist();
    notifyListeners();
  }

  /// Clears payment state but keeps who/where the order is for.
  void resetPayment() {
    paymentMethod = 'cash';
    tendered = 0;
    _persist();
    notifyListeners();
  }

  void setOrderType(String t) {
    orderType = t;
    if (t != 'dine-in') tableNum = '';
    if (t != 'delivery') {
      deliveryAddress = '';
      deliveryFee = 0;
    }
    _persist();
    notifyListeners();
  }

  void setTable(String num) {
    tableNum = num;
    _persist();
    notifyListeners();
  }

  void setCustomer(String name) {
    customerName = name;
    _persist();
    notifyListeners();
  }

  void setCustomerPhone(String phone) {
    customerPhone = phone;
    _persist();
    notifyListeners();
  }

  void setDeliveryAddress(String addr) {
    deliveryAddress = addr;
    _persist();
    notifyListeners();
  }

  void setDeliveryFee(double fee) {
    deliveryFee = fee;
    _persist();
    notifyListeners();
  }

  void setNotes(String n) {
    notes = n;
    _persist();
    notifyListeners();
  }

  void setPaymentMethod(String m) {
    paymentMethod = m;
    if (m != 'cash') tendered = 0;
    _persist();
    notifyListeners();
  }

  void setTendered(double amount) {
    tendered = amount;
    _persist();
    notifyListeners();
  }

  // ── Serialization for the API ─────────────────────────────────────────────

  /// The legacy flat summary string the kitchen board parses.
  String get itemsSummary => _items.map((l) {
        final sb = StringBuffer('${l.qty}x${l.name}');
        if (l.selectedModifiers.isNotEmpty) {
          sb.write(' [${l.selectedModifiers.map((m) => m.name).join(", ")}]');
        }
        if (l.notes.isNotEmpty) sb.write(' (${l.notes})');
        return sb.toString();
      }).join(', ');

  List<OrderItemLine> get serializedLines =>
      _items.map(OrderItemLine.fromCartLine).toList();

  String paymentLabelFor(List<PaymentLine> breakdown) =>
      breakdown.map((p) => p.method).join('+');

  List<PaymentLine> buildPaymentBreakdown() {
    final amount = subtotal;
    return [
      PaymentLine(
        method: paymentMethod,
        amount: amount,
        tendered: paymentMethod == 'cash' ? tendered : null,
        change: paymentMethod == 'cash' ? changeDue : null,
      )
    ];
  }

  // ── Persistence (12h, same contract as the web POS) ───────────────────────

  static const _kKey = 'fufut.pos.cart.v1';
  static const _kMaxAge = Duration(hours: 12);

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_items.isEmpty && tableNum.isEmpty && customerName.isEmpty) {
        await prefs.remove(_kKey);
        return;
      }
      await prefs.setString(_kKey, jsonEncode({
            'savedAt': DateTime.now().millisecondsSinceEpoch,
            'items': _items.map((l) => {
                  'key': l.uid,
                  'menuItemId': l.menuItemId,
                  'name': l.name,
                  'basePrice': l.basePrice,
                  'qty': l.qty,
                  'mods': l.modsToJson(),
                  'notes': l.notes,
                  'course': l.course,
                }).toList(),
            'orderType': orderType,
            'tableNum': tableNum,
            'isAddRound': isAddRound,
            'activeOpenOrderId': activeOpenOrderId,
            'customerName': customerName,
            'customerPhone': customerPhone,
            'deliveryAddress': deliveryAddress,
            'notes': notes,
          }));
    } catch (_) {
      // Quota/private-mode: losing persistence is preferable to throwing.
    }
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw == null) return;
      final saved = jsonDecode(raw) as Map<String, dynamic>;
      final at = saved['savedAt'] as int?;
      if (at == null ||
          DateTime.now().millisecondsSinceEpoch - at > _kMaxAge.inMilliseconds) {
        await prefs.remove(_kKey);
        return;
      }
      final rows = (saved['items'] as List?) ?? const [];
      for (final r in rows.whereType<Map>()) {
        final name = (r['name'] ?? '') as String;
        final basePrice = (r['basePrice'] as num?)?.toDouble() ?? 0;
        final qty = (r['qty'] as num?)?.toInt() ?? 0;
        if (name.isEmpty || qty < 1) continue; // totals need these
        final mods = ((r['mods'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => MenuModifier.fromJson(Map<String, dynamic>.from(m)))
            .toList();
        _items.add(CartLine(
          uid: (r['key'] ?? '') as String,
          menuItemId: r['menuItemId'] as String?,
          name: name,
          basePrice: basePrice,
          qty: qty,
          selectedModifiers: mods,
          notes: (r['notes'] ?? '') as String,
          course: (r['course'] ?? 'main') as String,
        ));
      }
      orderType = (saved['orderType'] ?? 'dine-in') as String;
      tableNum = (saved['tableNum'] ?? '') as String;
      isAddRound = saved['isAddRound'] == true;
      final savedOpenId = saved['activeOpenOrderId']?.toString() ?? '';
      activeOpenOrderId = savedOpenId.isEmpty ? null : savedOpenId;
      customerName = (saved['customerName'] ?? '') as String;
      customerPhone = (saved['customerPhone'] ?? '') as String;
      deliveryAddress = (saved['deliveryAddress'] ?? '') as String;
      notes = (saved['notes'] ?? '') as String;
      notifyListeners();
    } catch (_) {
      // A half-written entry must not take the till down at boot.
    }
  }
}
