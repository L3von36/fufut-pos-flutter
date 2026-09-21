/// Data models for the Fufut POS app.
///
/// Field names mirror the fufut-api JSON contract exactly (snake_case from
/// D1 columns, camelCase from newer handlers). Parsing is defensive: any
/// field can be missing or the wrong type, and a malformed row must never
/// take down the screen that renders it.
library;

// ─────────────────────────────────────────────────────────────────────────────
// Menu
// ─────────────────────────────────────────────────────────────────────────────

/// One product on the menu board (`GET /api/menu` flat list).
class MenuItem {
  final String id;
  final String name;
  final String category;
  final double price;
  final String description;
  final String? image;
  final bool available;
  final List<MenuModifier> modifiers;

  const MenuItem({
    required this.id,
    required this.name,
    required this.category,
    required this.price,
    this.description = '',
    this.image,
    this.available = true,
    this.modifiers = const [],
  });

  factory MenuItem.fromJson(Map<String, dynamic> j) {
    final modsRaw = j['modifiers'];
    final mods = modsRaw is List
        ? modsRaw
            .whereType<Map>()
            .map((m) => MenuModifier.fromJson(Map<String, dynamic>.from(m)))
            .toList()
        : const <MenuModifier>[];
    return MenuItem(
      id: (j['id'] ?? '') as String,
      name: (j['name'] ?? '') as String,
      category: (j['category'] ?? 'Other') as String,
      price: _asDouble(j['price']),
      description: (j['description'] ?? '') as String,
      image: j['image'] as String?,
      available: j['available'] is bool ? j['available'] as bool : true,
      modifiers: mods,
    );
  }

  /// Absolute URL for the item image. The API may return a same-origin
  /// path (`/api/images/...`) or a full URL.
  String? imageUrl(String baseUrl) {
    final raw = image;
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    return '$baseUrl$raw';
  }
}

/// A modifier option attached to a menu item (e.g. "Extra shot +30").
class MenuModifier {
  final String name;
  final double priceDelta;

  const MenuModifier({required this.name, this.priceDelta = 0});

  factory MenuModifier.fromJson(Map<String, dynamic> j) => MenuModifier(
        name: (j['name'] ?? '') as String,
        priceDelta: _asDouble(j['priceDelta'] ?? j['price_delta']),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Cart
// ─────────────────────────────────────────────────────────────────────────────

/// A line in the cart. Mirrors the web POS cart item shape.
class CartLine {
  final String uid;
  final String? menuItemId;
  final String name;
  final double basePrice;
  int qty;
  final List<MenuModifier> selectedModifiers;
  final String notes;
  final String course;

  CartLine({
    required this.uid,
    required this.menuItemId,
    required this.name,
    required this.basePrice,
    this.qty = 1,
    this.selectedModifiers = const [],
    this.notes = '',
    this.course = 'main',
  });

  double get unitPrice =>
      basePrice + selectedModifiers.fold<double>(0, (s, m) => s + m.priceDelta);

  double get lineTotal => unitPrice * qty;

  /// Modifiers as `[{name, priceDelta}]` — the shape `orderItems` carries.
  List<Map<String, dynamic>> modsToJson() => selectedModifiers
      .map((m) => {'name': m.name, 'priceDelta': m.priceDelta})
      .toList();
}

/// One leg of a payment (`paymentBreakdown` on the wire).
class PaymentLine {
  final String method; // cash | card | mobile | telebirr | cbe | bank
  final double amount;
  final double? tendered;
  final double? change;
  final String? reference;

  const PaymentLine({
    required this.method,
    required this.amount,
    this.tendered,
    this.change,
    this.reference,
  });

  Map<String, dynamic> toJson() => {
        'method': method,
        'amount': _r2(amount),
        if (tendered != null) 'tendered': _r2(tendered!),
        if (change != null) 'change': _r2(change!),
        if (reference != null && reference!.isNotEmpty)
          'reference': reference,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Orders
// ─────────────────────────────────────────────────────────────────────────────

/// A structured order line as stored on the server (`order_items`).
class OrderItemLine {
  final String? menuItemId;
  final String name;
  final double basePrice;
  final int qty;
  final double lineTotal;
  final List<Map<String, dynamic>> modifiers;
  final String? notes;
  final String course;

  const OrderItemLine({
    required this.menuItemId,
    required this.name,
    required this.basePrice,
    required this.qty,
    required this.lineTotal,
    this.modifiers = const [],
    this.notes,
    this.course = 'main',
  });

  factory OrderItemLine.fromCartLine(CartLine l) => OrderItemLine(
        menuItemId: l.menuItemId,
        name: l.name,
        basePrice: l.basePrice,
        qty: l.qty,
        lineTotal: _r2(l.lineTotal),
        modifiers: l.modsToJson(),
        notes: l.notes.isEmpty ? null : l.notes,
        course: l.course,
      );

  Map<String, dynamic> toJson() => {
        'menuItemId': menuItemId,
        'name': name,
        'basePrice': _r2(basePrice),
        'qty': qty,
        'lineTotal': _r2(lineTotal),
        'modifiers': modifiers,
        if (notes != null) 'notes': notes,
        'course': course,
      };

  factory OrderItemLine.fromJson(Map<String, dynamic> j) {
    final modsRaw = j['modifiers'];
    final mods = modsRaw is List
        ? modsRaw
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList()
        : const <Map<String, dynamic>>[];
    return OrderItemLine(
      menuItemId: j['menuItemId'] as String?,
      name: (j['name'] ?? '') as String,
      basePrice: _asDouble(j['basePrice'] ?? j['unit_price'] ?? j['unitPrice']),
      qty: _asInt(j['qty']),
      lineTotal: _asDouble(j['lineTotal']),
      modifiers: mods,
      notes: j['notes'] as String?,
      course: (j['course'] ?? 'main') as String,
    );
  }
}

/// An order as the API returns it (`GET /api/orders`) and as the app
/// creates it.
class FufutOrder {
  final String id;
  final String status; // new | preparing | ready | served | completed | cancelled
  final String? type; // dine-in | takeaway | delivery
  final String? tableNum;
  final String? customer;
  final String? customerPhone;
  final String? notes;
  final double total;
  final double subtotal;
  final double discount;
  final double tip;
  final double deliveryFee;
  final String? payment; // method string or 'unpaid'
  final String? paymentStatus; // unpaid | paid
  final String? created; // "2026-08-06 01:55:46" style local stamp
  final String? updatedAt;
  final String? createdByName;
  final List<OrderItemLine> items; // parsed structured lines when present
  final String itemsRaw; // the legacy flat summary string

  const FufutOrder({
    required this.id,
    required this.status,
    this.type,
    this.tableNum,
    this.customer,
    this.customerPhone,
    this.notes,
    this.total = 0,
    this.subtotal = 0,
    this.discount = 0,
    this.tip = 0,
    this.deliveryFee = 0,
    this.payment,
    this.paymentStatus,
    this.created,
    this.updatedAt,
    this.createdByName,
    this.items = const [],
    this.itemsRaw = '',
  });

  bool get isPaid =>
      (paymentStatus ?? '').toLowerCase() == 'paid' ||
      (payment ?? '').toLowerCase() != 'unpaid';

  bool get isClosed {
    final s = status.toLowerCase();
    return s == 'completed' || s == 'served' || s == 'cancelled';
  }

  factory FufutOrder.fromJson(Map<String, dynamic> j) {
    // `items` may arrive as a JSON string (legacy summary), as a structured
    // array, or be absent. Structured lines are preferred; the flat string is
    // kept for display either way.
    String itemsRaw = '';
    final raw = j['items'];
    if (raw is String) itemsRaw = raw;
    if (raw is List) {
      itemsRaw = raw
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .map((m) => '${_asInt(m['qty'])}x ${m['name'] ?? ''}')
          .join(', ');
    }

    final lines = <OrderItemLine>[];
    final orderItems = j['orderItems'];
    if (orderItems is List) {
      for (final line in orderItems.whereType<Map>()) {
        try {
          lines.add(OrderItemLine.fromJson(Map<String, dynamic>.from(line)));
        } catch (_) {
          // A malformed line is skipped, never fatal.
        }
      }
    } else if (raw is List) {
      for (final line in raw.whereType<Map>()) {
        try {
          lines.add(OrderItemLine.fromJson(Map<String, dynamic>.from(line)));
        } catch (_) {
          // Same: skip quietly.
        }
      }
    }

    return FufutOrder(
      id: (j['id'] ?? '') as String,
      status: (j['status'] ?? 'new') as String,
      type: j['type'] as String?,
      tableNum: (j['tableNum'] ?? j['table_number'] ?? j['table_id'])?.toString(),
      customer: (j['customer'] ?? j['name']) as String?,
      customerPhone: (j['customer_phone'] ?? j['phone']) as String?,
      notes: j['notes'] as String?,
      total: _asDouble(j['total']),
      subtotal: _asDouble(j['subtotal'] ?? j['total']),
      discount: _asDouble(j['discount']),
      tip: _asDouble(j['tip']),
      deliveryFee: _asDouble(j['delivery_fee'] ?? j['deliveryFee']),
      payment: j['payment'] as String?,
      paymentStatus: j['payment_status'] as String?,
      created: j['created'] as String?,
      updatedAt: j['updated_at'] as String?,
      createdByName: j['created_by_name'] as String?,
      items: lines,
      itemsRaw: itemsRaw,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Staff & tables
// ─────────────────────────────────────────────────────────────────────────────

/// The signed-in staff member (`user` from the login / auth.me response).
class StaffUser {
  final String id;
  final String? name;
  final String? firstName;
  final String? lastName;
  final String? email;
  final String role;

  const StaffUser({
    required this.id,
    this.name,
    this.firstName,
    this.lastName,
    this.email,
    required this.role,
  });

  String get displayName {
    if (name != null && name!.trim().isNotEmpty) return name!;
    final f = firstName ?? '';
    final l = lastName ?? '';
    final joined = '$f $l'.trim();
    if (joined.isNotEmpty) return joined;
    return email ?? id;
  }

  factory StaffUser.fromJson(Map<String, dynamic> j) {
    return StaffUser(
      id: (j['id'] ?? '') as String,
      name: (j['name'] ?? j['full_name']) as String?,
      // The server sends camelCase (`firstName`); the cached identity blob
      // this model round-trips through stores snake_case. Accept both.
      firstName: (j['firstName'] ?? j['first_name']) as String?,
      lastName: (j['lastName'] ?? j['last_name']) as String?,
      email: j['email'] as String?,
      role: (j['role'] ?? '') as String,
    );
  }
}

/// A table on the floor plan (`GET /api/tables`).
class CafeTable {
  final String id;
  final String number; // compared as a string everywhere in the system
  final String? section;
  final String status; // available | occupied | reserved
  final int? seats;

  const CafeTable({
    required this.id,
    required this.number,
    this.section,
    required this.status,
    this.seats,
  });

  factory CafeTable.fromJson(Map<String, dynamic> j) => CafeTable(
        id: (j['id'] ?? '') as String,
        number: (j['number'] ?? j['id'] ?? '').toString(),
        section: j['section'] as String?,
        status: (j['status'] ?? 'available') as String,
        seats: j['seats'] is int ? j['seats'] as int : int.tryParse('${j['seats']}'),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Reports — the manager / accountant dashboard payload
// ─────────────────────────────────────────────────────────────────────────────

/// One payment-method row of the day (`paymentMethods[]`).
class PayMethod {
  final String method;
  final int count;
  final double total;
  const PayMethod({required this.method, required this.count, required this.total});

  factory PayMethod.fromJson(Map<String, dynamic> j) => PayMethod(
        method: (j['method'] ?? 'other').toString(),
        count: _asInt(j['count']),
        total: _asDouble(j['total']),
      );
}

/// One category sales row (`byCategory[]`).
class CategoryRow {
  final String category;
  final int quantity;
  final double revenue;
  const CategoryRow({required this.category, required this.quantity, required this.revenue});

  factory CategoryRow.fromJson(Map<String, dynamic> j) => CategoryRow(
        category: (j['category'] ?? 'Uncategorised').toString(),
        quantity: _asInt(j['quantity']),
        revenue: _asDouble(j['revenue']),
      );
}

/// `GET /api/reports/dashboard` — the trading day at a glance. Net sales is
/// `total - tip`: the tip is the guest's money, never the restaurant's.
class DashboardStats {
  final String period;
  final int orders;
  final double netSales;
  final double averageOrder;
  final double discounts;
  final int dineInOrders;
  final int takeawayOrders;
  final int deliveryOrders;
  final double tips;
  final double expenses;
  final double grossOfExpenses;
  final int lowStockItems;
  final int pendingKitchen;
  final int pendingDeliveries;
  final List<PayMethod> paymentMethods;
  final List<CategoryRow> byCategory;

  const DashboardStats({
    this.period = 'day',
    this.orders = 0,
    this.netSales = 0,
    this.averageOrder = 0,
    this.discounts = 0,
    this.dineInOrders = 0,
    this.takeawayOrders = 0,
    this.deliveryOrders = 0,
    this.tips = 0,
    this.expenses = 0,
    this.grossOfExpenses = 0,
    this.lowStockItems = 0,
    this.pendingKitchen = 0,
    this.pendingDeliveries = 0,
    this.paymentMethods = const [],
    this.byCategory = const [],
  });

  factory DashboardStats.fromJson(Map<String, dynamic> j) {
    final sales = j['sales'] is Map ? Map<String, dynamic>.from(j['sales'] as Map) : const <String, dynamic>{};
    final byType = j['byOrderType'] is Map ? Map<String, dynamic>.from(j['byOrderType'] as Map) : const <String, dynamic>{};
    final ops = j['operations'] is Map ? Map<String, dynamic>.from(j['operations'] as Map) : const <String, dynamic>{};
    int typeCount(String k) {
      final row = byType[k];
      return row is Map ? _asInt(row['orders']) : 0;
    }

    return DashboardStats(
      period: (j['period'] ?? 'day').toString(),
      orders: _asInt(sales['orders']),
      netSales: _asDouble(sales['netSales']),
      averageOrder: _asDouble(sales['averageOrder']),
      discounts: _asDouble(sales['discounts']),
      dineInOrders: typeCount('dineIn'),
      takeawayOrders: typeCount('takeaway'),
      deliveryOrders: typeCount('delivery'),
      tips: _asDouble(j['tips']),
      expenses: _asDouble(j['expenses']),
      grossOfExpenses: _asDouble(j['grossOfExpenses']),
      lowStockItems: _asInt(ops['lowStockItems']),
      pendingKitchen: _asInt(ops['pendingKitchenOrders']),
      pendingDeliveries: _asInt(ops['pendingDeliveries']),
      paymentMethods: (j['paymentMethods'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => PayMethod.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
      byCategory: (j['byCategory'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => CategoryRow.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Waste — the cleaner's / barista's log
// ─────────────────────────────────────────────────────────────────────────────

/// One row of `GET /api/waste`. The server aliases `qty`/`est_cost` into
/// `quantity`/`cost`; the item name comes from the inventory join or the
/// free-text `name` the entry was logged with.
class WasteEntry {
  final String id;
  final String item;
  final double qty;
  final String? unit;
  final String reason;
  final double cost;
  final String? date;
  final String? loggedBy;

  const WasteEntry({
    required this.id,
    required this.item,
    required this.qty,
    this.unit,
    this.reason = '',
    this.cost = 0,
    this.date,
    this.loggedBy,
  });

  factory WasteEntry.fromJson(Map<String, dynamic> j) => WasteEntry(
        id: (j['id'] ?? '').toString(),
        item: (j['item'] ?? j['name'] ?? 'Item').toString(),
        qty: _asDouble(j['quantity'] ?? j['qty']),
        unit: (j['unit'] as String?)?.toString(),
        reason: (j['reason'] ?? '').toString(),
        cost: _asDouble(j['cost'] ?? j['est_cost']),
        date: (j['date'] ?? j['created'])?.toString(),
        loggedBy: (j['logged_by'] ?? j['loggedBy'])?.toString(),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Delivery — the driver's run list
// ─────────────────────────────────────────────────────────────────────────────

/// One job of `GET /api/delivery`. The row joins the order behind it, so the
/// driver can see what is in the bag, what it comes to and whether it is paid.
class DeliveryJob {
  final String id;
  final String? orderId;
  final String? customer;
  final String? phone;
  final String? address;
  final String status;
  final String? driver;
  final double total;
  final String? itemsRaw;
  final String? paymentStatus;
  final String? created;

  const DeliveryJob({
    required this.id,
    this.orderId,
    this.customer,
    this.phone,
    this.address,
    this.status = 'new',
    this.driver,
    this.total = 0,
    this.itemsRaw,
    this.paymentStatus,
    this.created,
  });

  bool get isPaid =>
      (paymentStatus ?? '').toLowerCase() == 'paid';

  factory DeliveryJob.fromJson(Map<String, dynamic> j) => DeliveryJob(
        id: (j['id'] ?? '').toString(),
        orderId: (j['orderId'] ?? j['order_id'])?.toString(),
        customer: (j['customer'] ?? j['customer_name'])?.toString(),
        phone: (j['phone'] ?? j['customer_phone'])?.toString(),
        address: (j['address'] ?? j['delivery_address'])?.toString(),
        status: ((j['status'] ?? 'new') as String).replaceAll('_', '-'),
        driver: (j['driver'] ?? j['driver_name'])?.toString(),
        total: _asDouble(j['order_total'] ?? j['total']),
        itemsRaw: (j['order_items'] ?? j['items'])?.toString(),
        paymentStatus: (j['order_payment_status'] ?? j['payment_status'])?.toString(),
        created: (j['created'] ?? j['assigned_at'])?.toString(),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

double _asDouble(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

int _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v) ?? double.tryParse(v)?.round() ?? 1;
  return 1;
}

double _r2(double v) => (v * 100).roundToDouble() / 100;
