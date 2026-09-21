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
  final String? createdById; // the web's created_by — order scoping reads it
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
    this.createdById,
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
      createdById: (j['created_by'] ?? j['created_by_id'])?.toString(),
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
  final String? guests;
  final String? billRequestedAt; // when the party asked for the bill

  const CafeTable({
    required this.id,
    required this.number,
    this.section,
    required this.status,
    this.seats,
    this.guests,
    this.billRequestedAt,
  });

  bool get billRequested => billRequestedAt != null && billRequestedAt!.isNotEmpty;

  factory CafeTable.fromJson(Map<String, dynamic> j) => CafeTable(
        id: (j['id'] ?? '') as String,
        number: (j['number'] ?? j['id'] ?? '').toString(),
        section: j['section'] as String?,
        status: (j['status'] ?? 'available') as String,
        // The server names the field `capacity`; older rows said `seats`.
        // Both parse so the card's "4p" hint renders on every shape.
        seats: j['seats'] is int
            ? j['seats'] as int
            : int.tryParse('${j['seats'] ?? j['capacity'] ?? ''}'),
        guests: j['guests']?.toString(),
        billRequestedAt:
            (j['bill_requested_at'] ?? j['billRequestedAt'])?.toString(),
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
// Cash drawer — sessions, Z-report, shift audit
// ─────────────────────────────────────────────────────────────────────────────

/// One drawer session (`GET /api/cashdrawer` rows, active or closed). Field
/// names arrive both camelCase (newer handler) and snake_case (D1 columns);
/// every alias is accepted.
class DrawerSession {
  final String id;
  final String status; // open | closed
  final double openingBal;
  final double cashSales;
  final double paidIn;
  final double paidOut;
  final double closingBal;
  final double variance;
  final String? opened;
  final String? closed;
  final String? openedBy;

  const DrawerSession({
    required this.id,
    this.status = 'open',
    this.openingBal = 0,
    this.cashSales = 0,
    this.paidIn = 0,
    this.paidOut = 0,
    this.closingBal = 0,
    this.variance = 0,
    this.opened,
    this.closed,
    this.openedBy,
  });

  /// opening float + cash sales + paid-in − paid-out — what the drawer
  /// *should* count out to (server migration 020, web `expectedOf`).
  double get expected => openingBal + cashSales + paidIn - paidOut;

  factory DrawerSession.fromJson(Map<String, dynamic> j) => DrawerSession(
        id: (j['id'] ?? '').toString(),
        status: (j['status'] ?? 'open').toString(),
        openingBal: _asDouble(j['openingBal'] ?? j['opening_balance']),
        cashSales: _asDouble(j['cashSales'] ?? j['cash_sales']),
        paidIn: _asDouble(j['paidIn'] ?? j['paid_in']),
        paidOut: _asDouble(j['paidOut'] ?? j['paid_out']),
        closingBal: _asDouble(j['closingBal'] ?? j['closing_balance']),
        variance: _asDouble(j['variance']),
        opened: (j['opened'] ?? j['opened_at'])?.toString(),
        closed: (j['closed'] ?? j['closed_at'])?.toString(),
        openedBy: (j['openedBy'] ?? j['opened_by'] ?? j['actor_name'])?.toString(),
      );
}

/// `GET /api/cashdrawer` — the active session (null when the till is closed)
/// plus the day's sessions.
class CashDrawerState {
  final DrawerSession? active;
  final List<DrawerSession> drawers;

  const CashDrawerState({this.active, this.drawers = const []});

  factory CashDrawerState.fromJson(Map<String, dynamic> j) => CashDrawerState(
        active: j['active'] is Map
            ? DrawerSession.fromJson(
                Map<String, dynamic>.from(j['active'] as Map))
            : null,
        drawers: (j['drawers'] as List? ?? const [])
            .whereType<Map>()
            .map((m) => DrawerSession.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
      );
}

/// One payment-method row of the Z-report.
class ZReportPayment {
  final String method;
  final int count;
  final double total;
  const ZReportPayment({required this.method, required this.count, required this.total});

  factory ZReportPayment.fromJson(Map<String, dynamic> j) => ZReportPayment(
        method: (j['method'] ?? 'other').toString(),
        count: _asInt(j['count']),
        total: _asDouble(j['total']),
      );
}

/// The cash reconciliation block of a Z-report.
class ZReportCash {
  final double openingFloat;
  final double cashSales;
  final double paidIn;
  final double paidOut;
  final double expected;
  final double counted;
  final double variance;

  const ZReportCash({
    this.openingFloat = 0,
    this.cashSales = 0,
    this.paidIn = 0,
    this.paidOut = 0,
    this.expected = 0,
    this.counted = 0,
    this.variance = 0,
  });

  factory ZReportCash.fromJson(Map<String, dynamic> j) => ZReportCash(
        openingFloat: _asDouble(j['openingFloat'] ?? j['opening_float']),
        cashSales: _asDouble(j['cashSales'] ?? j['cash_sales']),
        paidIn: _asDouble(j['paidIn'] ?? j['paid_in']),
        paidOut: _asDouble(j['paidOut'] ?? j['paid_out']),
        expected: _asDouble(j['expected']),
        counted: _asDouble(j['counted'] ?? j['closingBal'] ?? j['closing_balance']),
        variance: _asDouble(j['variance']),
      );
}

/// `GET /api/cashdrawer/:id/z-report` — the fiscal close-out of one shift.
/// Parsed defensively: anything missing renders as a dash, never an error.
class ZReport {
  final String zNumber;
  final String drawerId;
  final String? openedAt;
  final String? closedAt;
  final String status;
  final ZReportCash cash;
  final List<ZReportPayment> payments;
  final double serviceCharge;
  final double tips;
  final int zCount;
  final double cumulativeCashSales;

  const ZReport({
    this.zNumber = '',
    this.drawerId = '',
    this.openedAt,
    this.closedAt,
    this.status = 'closed',
    this.cash = const ZReportCash(),
    this.payments = const [],
    this.serviceCharge = 0,
    this.tips = 0,
    this.zCount = 0,
    this.cumulativeCashSales = 0,
  });

  factory ZReport.fromJson(Map<String, dynamic> j) {
    final cashRaw = j['cashReconciliation'] is Map
        ? Map<String, dynamic>.from(j['cashReconciliation'] as Map)
        : const <String, dynamic>{};
    final grand = j['grandTotals'] is Map
        ? Map<String, dynamic>.from(j['grandTotals'] as Map)
        : const <String, dynamic>{};
    return ZReport(
      zNumber: (j['header'] is Map
              ? (j['header'] as Map)['zNumber']
              : j['zNumber'])
          ?.toString() ??
          '',
      drawerId: (j['header'] is Map
              ? (j['header'] as Map)['drawerId']
              : j['drawerId'])
          ?.toString() ??
          '',
      openedAt: (j['header'] is Map
              ? ((j['header'] as Map)['openedAt'] ?? (j['header'] as Map)['opened'])
              : j['openedAt'])
          ?.toString(),
      closedAt: (j['header'] is Map
              ? ((j['header'] as Map)['closedAt'] ?? (j['header'] as Map)['closed'])
              : j['closedAt'])
          ?.toString(),
      status: (j['header'] is Map
              ? ((j['header'] as Map)['status'] ?? 'closed')
              : j['status'] ?? 'closed')
          .toString(),
      cash: cashRaw.isEmpty ? const ZReportCash() : ZReportCash.fromJson(cashRaw),
      payments: (j['paymentBreakdown'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => ZReportPayment.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
      serviceCharge: _asDouble(j['serviceCharge'] ?? j['service_charge']),
      tips: _asDouble(j['tips']),
      zCount: _asInt(grand['zCount']),
      cumulativeCashSales: _asDouble(grand['cumulativeCashSales']),
    );
  }
}

/// One row of `GET /api/cashdrawer/shift-log` — the audit timeline.
class ShiftLogEntry {
  final String at;
  final String action;
  final String reason;
  final String actorName;

  const ShiftLogEntry({
    required this.at,
    required this.action,
    this.reason = '',
    this.actorName = '',
  });

  factory ShiftLogEntry.fromJson(Map<String, dynamic> j) => ShiftLogEntry(
        at: (j['at'] ?? j['created'] ?? '').toString(),
        action: (j['action'] ?? '').toString(),
        reason: (j['reason'] ?? '').toString(),
        actorName: (j['actorName'] ?? j['actor_name'] ?? '').toString(),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// HR — time clock, payslips, audit (My Activity), handover
// ─────────────────────────────────────────────────────────────────────────────

/// One punch of the time clock (`timeclock/me`, `timeclock/me/history`).
class TimeclockEntry {
  final String id;
  final String? date;
  final String? clockIn;
  final String? clockOut;
  final String? created;
  final bool onBreak;

  const TimeclockEntry({
    required this.id,
    this.date,
    this.clockIn,
    this.clockOut,
    this.created,
    this.onBreak = false,
  });

  factory TimeclockEntry.fromJson(Map<String, dynamic> j) => TimeclockEntry(
        id: (j['id'] ?? '').toString(),
        date: (j['date'] ?? j['work_date'])?.toString(),
        clockIn: (j['clockIn'] ?? j['clock_in'])?.toString(),
        clockOut: (j['clockOut'] ?? j['clock_out'])?.toString(),
        created: j['created']?.toString(),
        // Break state rides the entry under whatever key the handler chose;
        // every known alias is accepted.
        onBreak: (j['on_break'] ??
                j['onBreak'] ??
                j['break_started'] ??
                j['breakStarted'] ??
                j['in_break']) ==
            true,
      );
}

/// `GET /api/timeclock/me` — am I on shift right now?
class TimeclockMe {
  final bool clockedIn;
  final TimeclockEntry? entry;

  const TimeclockMe({required this.clockedIn, this.entry});

  factory TimeclockMe.fromJson(Map<String, dynamic> j) => TimeclockMe(
        clockedIn: j['clockedIn'] == true || j['clocked_in'] == true,
        entry: j['entry'] is Map
            ? TimeclockEntry.fromJson(
                Map<String, dynamic>.from(j['entry'] as Map))
            : null,
      );
}

/// A staff row (`GET /api/staff`) — roster names.
class StaffMember {
  final String id;
  final String name;
  final String role;

  const StaffMember({required this.id, required this.name, this.role = ''});

  factory StaffMember.fromJson(Map<String, dynamic> j) => StaffMember(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ??
                [j['firstName'], j['lastName']]
                    .where((p) => p != null && '$p'.trim().isNotEmpty)
                    .join(' '))
            .toString(),
        role: (j['role'] ?? '').toString(),
      );
}

/// `GET /api/handovers/latest` → `{handover: …}` — snake_case on read.
class Handover {
  final String staffName;
  final String created;
  final String pendingOrders;
  final String pendingTasks;
  final String cashInfo;
  final String problems;
  final String customerIssues;
  final String importantNotes;

  const Handover({
    this.staffName = '',
    this.created = '',
    this.pendingOrders = '',
    this.pendingTasks = '',
    this.cashInfo = '',
    this.problems = '',
    this.customerIssues = '',
    this.importantNotes = '',
  });

  factory Handover.fromJson(Map<String, dynamic> j) => Handover(
        staffName: (j['staffName'] ?? j['staff_name'] ?? '').toString(),
        created: (j['created'] ?? '').toString(),
        pendingOrders: (j['pending_orders'] ?? j['pendingOrders'] ?? '').toString(),
        pendingTasks: (j['pending_tasks'] ?? j['pendingTasks'] ?? '').toString(),
        cashInfo: (j['cash_info'] ?? j['cashInfo'] ?? '').toString(),
        problems: (j['problems'] ?? '').toString(),
        customerIssues:
            (j['customer_issues'] ?? j['customerIssues'] ?? '').toString(),
        importantNotes:
            (j['important_notes'] ?? j['importantNotes'] ?? '').toString(),
      );
}

/// One payslip row of `GET /api/payroll/me`.
class Payslip {
  final String id;
  final String periodStart;
  final String periodEnd;
  final double baseSalary;
  final double overtimePay;
  final double bonuses;
  final double deductions;
  final double incomeTax;
  final double pensionEmployee;
  final double netPay;
  final double tipsEarned;
  final String runStatus;
  final bool provisional;

  const Payslip({
    required this.id,
    this.periodStart = '',
    this.periodEnd = '',
    this.baseSalary = 0,
    this.overtimePay = 0,
    this.bonuses = 0,
    this.deductions = 0,
    this.incomeTax = 0,
    this.pensionEmployee = 0,
    this.netPay = 0,
    this.tipsEarned = 0,
    this.runStatus = '',
    this.provisional = false,
  });

  factory Payslip.fromJson(Map<String, dynamic> j) => Payslip(
        id: (j['id'] ?? '').toString(),
        periodStart: (j['period_start'] ?? j['periodStart'] ?? '').toString(),
        periodEnd: (j['period_end'] ?? j['periodEnd'] ?? '').toString(),
        baseSalary: _asDouble(j['base_salary'] ?? j['baseSalary']),
        overtimePay: _asDouble(j['overtime_pay'] ?? j['overtimePay']),
        bonuses: _asDouble(j['bonuses']),
        deductions: _asDouble(j['deductions']),
        incomeTax: _asDouble(j['income_tax'] ?? j['incomeTax']),
        pensionEmployee:
            _asDouble(j['pension_employee'] ?? j['pensionEmployee']),
        netPay: _asDouble(j['net_pay'] ?? j['netPay']),
        tipsEarned: _asDouble(j['tips_earned'] ?? j['tipsEarned']),
        runStatus: (j['run_status'] ?? j['runStatus'] ?? '').toString(),
        provisional: j['provisional'] == true,
      );
}

/// `GET /api/payroll/me` — current contract + payslip history.
class PayrollMe {
  final double baseSalary;
  final String salaryPeriod;
  final String employmentType;
  final List<Payslip> payslips;

  const PayrollMe({
    this.baseSalary = 0,
    this.salaryPeriod = '',
    this.employmentType = '',
    this.payslips = const [],
  });

  bool get hasProvisional => payslips.any((p) => p.provisional);

  factory PayrollMe.fromJson(Map<String, dynamic> j) {
    final current = j['current'] is Map
        ? Map<String, dynamic>.from(j['current'] as Map)
        : const <String, dynamic>{};
    return PayrollMe(
      baseSalary: _asDouble(current['baseSalary'] ?? current['base_salary']),
      salaryPeriod: (current['salaryPeriod'] ?? current['salary_period'] ?? '')
          .toString(),
      employmentType:
          (current['employmentType'] ?? current['employment_type'] ?? '')
              .toString(),
      payslips: (j['payslips'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => Payslip.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
    );
  }
}

/// One audit row (`GET /api/audit?actor_id=…`) — the My Activity feed.
class AuditEntry {
  final String id;
  final String at;
  final String entity;
  final String action;
  final String entityId;
  final String reason;
  final dynamic before;
  final dynamic after;
  final String actorName;
  final String actorRole;

  const AuditEntry({
    required this.id,
    required this.at,
    this.entity = '',
    this.action = '',
    this.entityId = '',
    this.reason = '',
    this.before,
    this.after,
    this.actorName = '',
    this.actorRole = '',
  });

  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
        id: (j['id'] ?? '').toString(),
        at: (j['at'] ?? j['created'] ?? '').toString(),
        entity: (j['entity'] ?? '').toString(),
        action: (j['action'] ?? '').toString(),
        entityId: (j['entity_id'] ?? j['entityId'] ?? '').toString(),
        reason: (j['reason'] ?? '').toString(),
        before: j['before'],
        after: j['after'],
        actorName: (j['actor_name'] ?? j['actorName'] ?? '').toString(),
        actorRole: (j['actor_role'] ?? j['actorRole'] ?? '').toString(),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Reservations (waiter dashboard) & kitchen line tracking
// ─────────────────────────────────────────────────────────────────────────────

/// One row of `GET /api/reservations`.
class Reservation {
  final String id;
  final String name;
  final String? date;
  final String? time;
  final int guests;
  final String status;
  final String? phone;

  const Reservation({
    required this.id,
    this.name = '',
    this.date,
    this.time,
    this.guests = 0,
    this.status = '',
    this.phone,
  });

  factory Reservation.fromJson(Map<String, dynamic> j) => Reservation(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? j['customer'] ?? j['guest_name'] ?? 'Guest').toString(),
        date: (j['date'] ?? j['reservation_date'])?.toString(),
        time: (j['time'] ?? j['reservation_time'])?.toString(),
        guests: _asInt(j['guests'] ?? j['party_size']),
        status: (j['status'] ?? '').toString(),
        phone: (j['phone'] ?? j['customer_phone'])?.toString(),
      );
}

/// One line of `GET /api/orders/items/active` — the kitchen's per-line
/// tracking rows. `status` walks the same item flow: new → preparing →
/// ready → served.
class ActiveOrderItem {
  final String id;
  final String orderId;
  final int lineNo;
  final int qty;
  final String name;
  final String category;
  final String course;
  final String status;
  final String? notes;

  const ActiveOrderItem({
    required this.id,
    required this.orderId,
    this.lineNo = 0,
    this.qty = 1,
    this.name = '',
    this.category = '',
    this.course = 'main',
    this.status = 'new',
    this.notes,
  });

  factory ActiveOrderItem.fromJson(Map<String, dynamic> j) => ActiveOrderItem(
        id: (j['id'] ?? '').toString(),
        orderId: (j['order_id'] ?? j['orderId'] ?? '').toString(),
        lineNo: _asInt(j['line_no'] ?? j['lineNo']),
        qty: _asInt(j['qty'] ?? j['quantity']),
        name: (j['name'] ?? '').toString(),
        category: (j['category'] ?? '').toString(),
        course: (j['course'] ?? 'main').toString(),
        status: (j['status'] ?? 'new').toString(),
        notes: (j['notes'])?.toString(),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Operations alerts — the cron sweep's SLA breaches (`GET /api/alerts`,
// the `alerts_update` SSE payload rows, the web AlertsBanner's list)
// ─────────────────────────────────────────────────────────────────────────────

/// One operations alert: a rule breach the server wrote (a table waiting too
/// long for acceptance, an order sitting on the pass, a driver stalled on a
/// run). The banner sorts critical first, then oldest first — the thing about
/// to be lost is the thing to read first.
class OpsAlert {
  final String id;
  final String ruleId;
  final String severity; // warning | critical
  final String entityType;
  final String entityId;
  final String entityLabel;
  final String message;
  final String status; // open | acknowledged | resolved
  final String created;

  /// True while nobody has acknowledged the breach — the only rows the
  /// banner shows (the server serves open rows to the read endpoint).
  bool get isOpen => status == 'open';

  const OpsAlert({
    required this.id,
    this.ruleId = '',
    this.severity = 'warning',
    this.entityType = '',
    this.entityId = '',
    this.entityLabel = '',
    this.message = '',
    this.status = 'open',
    this.created = '',
  });

  factory OpsAlert.fromJson(Map<String, dynamic> j) => OpsAlert(
        id: (j['id'] ?? '').toString(),
        ruleId: (j['rule_id'] ?? j['ruleId'] ?? '').toString(),
        severity: (j['severity'] ?? 'warning').toString(),
        entityType: (j['entity_type'] ?? j['entityType'] ?? '').toString(),
        entityId: (j['entity_id'] ?? j['entityId'] ?? '').toString(),
        entityLabel: (j['entity_label'] ?? j['entityLabel'] ?? '').toString(),
        message: (j['message'] ?? '').toString(),
        status: (j['status'] ?? 'open').toString(),
        created: (j['created'] ?? '').toString(),
      );

  /// Critical first, then oldest first — the web banner's `sorted` computed.
  static int rank(OpsAlert a, OpsAlert b) {
    final aCritical = a.severity == 'critical';
    final bCritical = b.severity == 'critical';
    if (aCritical != bCritical) return aCritical ? -1 : 1;
    return a.created.compareTo(b.created);
  }
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
