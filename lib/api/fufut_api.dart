/// Fufut API endpoints, typed.
///
/// Endpoint contracts match the deployed fufut-api Worker:
///  * POST /api/auth/login  {staffId|email, password} → {ok,user,role,...} + session cookie
///  * GET  /api/auth/me     → session check
///  * POST /api/auth/logout
///  * GET  /api/menu        → flat menu array
///  * GET  /api/tables      → floor plan rows
///  * GET  /api/orders[?open=1] → last 200 orders / open checks
///  * POST /api/orders      → create (kitchen ticket or paid sale)
///  * PUT  /api/orders/:id  → settle / advance status
///  * PATCH /api/orders/:id/items → add a round to an open tab
library;

import 'api_client.dart';
import '../models/models.dart';

class FufutApi {
  final ApiClient client;

  FufutApi(this.client);

  // ── Auth ──────────────────────────────────────────────────────────────────

  /// Login with a staff id or email. Returns the staff user; the session
  /// cookie is captured inside [client].
  Future<StaffUser> login(String account, String password) async {
    final body = account.contains('@')
        ? <String, dynamic>{'email': account.trim(), 'password': password}
        : <String, dynamic>{'staffId': account.trim(), 'password': password};
    final res = await client.post('auth/login', body);
    if (res is! Map || res['ok'] != true) {
      throw ApiError(
          (res is Map && res['error'] is String) ? res['error'] : 'Login failed',
          401);
    }
    final user = StaffUser.fromJson(
        Map<String, dynamic>.from(res['user'] as Map));
    return user;
  }

  /// Session check. Returns the signed-in user or null (also null when the
  /// server is unreachable — the caller decides whether that is fatal).
  Future<StaffUser?> me() async {
    try {
      final res = await client.get('auth/me');
      if (res is Map && res['ok'] == true && res['user'] is Map) {
        return StaffUser.fromJson(
            Map<String, dynamic>.from(res['user'] as Map));
      }
      return null;
    } on ApiError catch (e) {
      if (e.isAuthError) return null;
      rethrow;
    }
  }

  Future<void> logout() async {
    try {
      await client.post('auth/logout', {});
    } on ApiError {
      // Logging out locally matters even if the server never heard it.
    }
  }

  /// A manager-issued password must be replaced before the server answers
  /// anything else. Surfaces the same contract as the web POS change screen.
  Future<void> changePassword(String current, String next) async {
    final res = await client
        .post('auth/change-password', {'currentPassword': current, 'newPassword': next});
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not change password');
    }
  }

  // ── Menu ──────────────────────────────────────────────────────────────────

  Future<List<MenuItem>> menu() async {
    final res = await client.get('menu');
    if (res is! List) return const [];
    return res
        .whereType<Map>()
        .map((m) => MenuItem.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  // ── Tables ────────────────────────────────────────────────────────────────

  Future<List<CafeTable>> tables() async {
    final res = await client.get('tables');
    if (res is! List) return const [];
    return res
        .whereType<Map>()
        .map((m) => CafeTable.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// Seat a party: claim the table atomically, exactly like the web POS —
  /// the conditional UPDATE means two waiters cannot both seat the table,
  /// and an already-occupied table is simply left alone.
  Future<void> claimTable(CafeTable t) async {
    await client.put('tables/${t.id}', {
      ...Map<String, dynamic>.from(_tableJson(t)),
      'status': 'occupied',
      'seated_at': DateTime.now().toUtc().toIso8601String(),
      'newSeating': true,
    });
  }

  Map<String, dynamic> _tableJson(CafeTable t) => {
        'id': t.id,
        'number': t.number,
        if (t.section != null) 'section': t.section,
        'status': t.status,
        if (t.seats != null) 'seats': t.seats,
      };

  // ── Orders ────────────────────────────────────────────────────────────────

  Future<List<FufutOrder>> orders({bool openOnly = false}) async {
    final res = await client.get(openOnly ? 'orders?open=1' : 'orders');
    if (res is! List) return const [];
    return res
        .whereType<Map>()
        .map((m) => FufutOrder.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// Send a ticket to the kitchen: status stays `new`, payment stays unpaid,
  /// and the kitchen fires on it before any money changes hands.
  Future<String> sendToKitchen({
    required String itemsSummary,
    required List<OrderItemLine> lines,
    required double subtotal,
    required double total,
    required String orderType,
    String? tableNum,
    String? customer,
    String? customerPhone,
    String? deliveryAddress,
    String? notes,
    double deliveryFee = 0,
  }) async {
    final res = await client.post('orders', {
      'items': itemsSummary,
      'orderItems': lines.map((l) => l.toJson()).toList(),
      'subtotal': _r2(subtotal),
      'total': _r2(total),
      'status': 'new',
      'payment': 'unpaid',
      'paymentBreakdown': <Map<String, dynamic>>[],
      'tip': 0,
      'tipType': 'none',
      'type': orderType,
      if (tableNum != null && tableNum.isNotEmpty) 'tableNum': tableNum,
      'customer': (customer != null && customer.isNotEmpty) ? customer : 'Walk-in',
      if (customerPhone != null && customerPhone.isNotEmpty)
        'customerPhone': customerPhone,
      // The delivery job is built from `address`; on any other order type it
      // is omitted rather than sent empty (same rule as the web POS).
      if (orderType == 'delivery' &&
          deliveryAddress != null &&
          deliveryAddress.isNotEmpty)
        'address': deliveryAddress,
      if (orderType == 'delivery' && deliveryFee > 0) 'deliveryFee': deliveryFee,
      if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
    });
    final id = res is Map ? (res['id'] ?? res['orderId']) : null;
    return (id ?? '').toString();
  }

  /// Charge now: one POST carrying the payment breakdown, like the web POS
  /// CheckoutView's no-tab flow.
  Future<String> chargeNow({
    required String itemsSummary,
    required List<OrderItemLine> lines,
    required double subtotal,
    required double total,
    required String orderType,
    required PaymentLine payment,
    required String paymentLabel,
    String? tableNum,
    String? customer,
    String? customerPhone,
    String? notes,
    double tip = 0,
    double discount = 0,
    double deliveryFee = 0,
  }) async {
    final res = await client.post('orders', {
      'items': itemsSummary,
      'orderItems': lines.map((l) => l.toJson()).toList(),
      'subtotal': _r2(subtotal),
      'total': _r2(total),
      'status': 'new',
      'payment': paymentLabel,
      'paymentBreakdown': [payment.toJson()],
      'tip': _r2(tip),
      'tipType': tip > 0 ? 'fixed' : 'none',
      'discount': _r2(discount),
      'discountType': discount > 0 ? 'fixed' : 'none',
      'type': orderType,
      if (tableNum != null && tableNum.isNotEmpty) 'tableNum': tableNum,
      'customer': (customer != null && customer.isNotEmpty) ? customer : 'Walk-in',
      if (customerPhone != null && customerPhone.isNotEmpty)
        'customerPhone': customerPhone,
      if (orderType == 'delivery' && deliveryFee > 0) 'deliveryFee': deliveryFee,
      if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
    });
    final id = res is Map ? (res['id'] ?? res['orderId']) : null;
    return (id ?? '').toString();
  }

  /// Settle an open tab with a PUT — mirrors CheckoutView's settlement body.
  Future<void> settleOrder(
      FufutOrder order, String paymentLabel, PaymentLine payment) async {
    await client.put('orders/${order.id}', {
      'status': 'served',
      'payment': paymentLabel,
      'total': _r2(order.total),
      'subtotal': _r2(order.subtotal),
      'paymentBreakdown': [payment.toJson()],
    });
  }

  /// Advance an order through the pipeline (new → preparing → ready → …).
  Future<void> updateStatus(FufutOrder order, String status) async {
    await client.put('orders/${order.id}', {'id': order.id, 'status': status});
  }

  /// Add a round to an open tab.
  Future<void> addRound(FufutOrder order, List<OrderItemLine> lines,
      String itemsSummary) async {
    await client.patch('orders/${order.id}/items', {
      'orderItems': lines.map((l) => l.toJson()).toList(),
      'items': itemsSummary,
    });
  }

  // ── Reports (manager / accountant / cashier dashboards) ───────────────────

  /// `GET /api/reports/dashboard?period=<day|week|month>` — net sales, order
  /// mix, payment methods and the operations counters the KPI cards show.
  Future<DashboardStats> reportsDashboard({String period = 'day'}) async {
    final res = await client.get('reports/dashboard?period=$period');
    if (res is Map) {
      return DashboardStats.fromJson(Map<String, dynamic>.from(res));
    }
    return const DashboardStats();
  }

  // ── Waste (cleaner / barista) ─────────────────────────────────────────────

  /// `GET /api/waste` — the log, newest first.
  Future<List<WasteEntry>> wasteLog() async {
    final res = await client.get('waste');
    if (res is! List) return const [];
    return res
        .whereType<Map>()
        .map((m) => WasteEntry.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `POST /api/waste` — record what was thrown away. Free-text form: the
  /// server stores the name as typed; a real inventory item can be attached
  /// with [inventoryId], which also takes it off the shelf.
  Future<void> postWaste({
    required String name,
    required double qty,
    required String reason,
    double cost = 0,
    String? inventoryId,
  }) async {
    final res = await client.post('waste', {
      'name': name.trim(),
      'quantity': qty,
      'reason': reason.trim(),
      if (cost > 0) 'cost': cost,
      if (inventoryId != null && inventoryId.isNotEmpty)
        'inventoryId': inventoryId,
    });
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not record waste');
    }
  }

  // ── Delivery (driver's run list) ──────────────────────────────────────────

  /// `GET /api/delivery` — the jobs, newest first, each joined with its order.
  Future<List<DeliveryJob>> deliveries() async {
    final res = await client.get('delivery');
    if (res is! List) return const [];
    return res
        .whereType<Map>()
        .map((m) => DeliveryJob.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `POST /api/delivery/:id/status` — move a job along
  /// (new → assigned → out-for-delivery → delivered).
  Future<void> advanceDelivery(String id, String status) async {
    final res = await client.post('delivery/$id/status', {'status': status});
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not update delivery');
    }
  }

  // ── Small helpers ─────────────────────────────────────────────────────────

  static double _r2(double v) => (v * 100).roundToDouble() / 100;
}
