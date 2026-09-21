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

/// Who the server says is signed in, plus the change-password flag — a
/// manager-issued password has to be replaced before the server honors
/// anything else, and the router treats that flag exactly like the web guard
/// treats it (guard.js: "An account carrying a manager-issued password can go
/// exactly one place").
class SessionUser {
  final StaffUser user;
  final bool mustChangePassword;
  const SessionUser(this.user, {this.mustChangePassword = false});
}

class FufutApi {
  final ApiClient client;

  FufutApi(this.client);

  // ── Auth ──────────────────────────────────────────────────────────────────

  /// Login with a staff id or email. Returns the staff user plus the
  /// must-change-password flag; the session cookie is captured inside
  /// [client].
  Future<SessionUser> login(String account, String password) async {
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
    return SessionUser(user,
        mustChangePassword: res['mustChangePassword'] == true);
  }

  /// Session check. Returns the signed-in user or null (also null when the
  /// server is unreachable — the caller decides whether that is fatal).
  Future<SessionUser?> me() async {
    try {
      final res = await client.get('auth/me');
      if (res is Map && res['ok'] == true && res['user'] is Map) {
        return SessionUser(
          StaffUser.fromJson(Map<String, dynamic>.from(res['user'] as Map)),
          mustChangePassword: res['mustChangePassword'] == true,
        );
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

  // ── Reservations (waiter dashboard) ───────────────────────────────────────

  /// `GET /api/reservations` — today's book plus the upcoming days. A 403
  /// (roles without the grant) reads as an empty book, never an error.
  Future<List<Reservation>> reservations() async {
    try {
      final res = await client.get('reservations');
      if (res is! List) return const [];
      return res
          .whereType<Map>()
          .map((m) => Reservation.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } on ApiError catch (e) {
      if (e.status == 403 || e.status == 404) return const [];
      rethrow;
    }
  }

  // ── Cash drawer — the till's full shift lifecycle ─────────────────────────

  /// `GET /api/cashdrawer` — active session + today's drawers.
  Future<CashDrawerState> cashdrawer() async {
    final res = await client.get('cashdrawer');
    if (res is Map) return CashDrawerState.fromJson(Map<String, dynamic>.from(res));
    return const CashDrawerState();
  }

  /// `GET /api/cashdrawer/history` — past sessions with variance.
  Future<List<DrawerSession>> cashdrawerHistory() async {
    final res = await client.get('cashdrawer/history');
    final list = res is Map ? res['drawers'] : res;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => DrawerSession.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `GET /api/cashdrawer/shift-log` — who opened / closed / paid what.
  Future<List<ShiftLogEntry>> cashdrawerShiftLog() async {
    final res = await client.get('cashdrawer/shift-log');
    final list = res is Map ? res['entries'] : res;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => ShiftLogEntry.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `POST /api/cashdrawer/open {openingBal}` — start a shift with a float.
  Future<void> openDrawer(double openingBal) async {
    await client.post('cashdrawer/open', {'openingBal': _r2(openingBal)});
  }

  /// `POST /api/cashdrawer/close {id, closingBal, denominations}` — the Z
  /// count. Denominations keys are the ETB notes: "200","100","50","20","10","5".
  Future<void> closeDrawer(
      String id, double closingBal, Map<String, int> denominations) async {
    await client.post('cashdrawer/close', {
      'id': id,
      'closingBal': _r2(closingBal),
      'denominations': {
        for (final e in denominations.entries) e.key: e.value,
      },
    });
  }

  /// `POST /api/cashdrawer/paid-in {amount, reason}`.
  Future<void> paidIn(double amount, String reason) async {
    await client.post('cashdrawer/paid-in', {'amount': _r2(amount), 'reason': reason});
  }

  /// `POST /api/cashdrawer/paid-out {amount, reason}`.
  Future<void> paidOut(double amount, String reason) async {
    await client.post('cashdrawer/paid-out', {'amount': _r2(amount), 'reason': reason});
  }

  /// `POST /api/cashdrawer/pop {reason}` — pop the physical drawer.
  Future<void> popDrawer(String reason) async {
    await client.post('cashdrawer/pop', {'reason': reason});
  }

  /// `GET /api/cashdrawer/:id/z-report` — the fiscal close-out.
  Future<ZReport> zReport(String id) async {
    final res = await client.get('cashdrawer/$id/z-report');
    if (res is Map) return ZReport.fromJson(Map<String, dynamic>.from(res));
    return const ZReport();
  }

  // ── HR trio — time clock, payslips, my activity ───────────────────────────

  /// `GET /api/timeclock/me` — on shift?
  Future<TimeclockMe> timeclockMe() async {
    final res = await client.get('timeclock/me');
    if (res is Map) return TimeclockMe.fromJson(Map<String, dynamic>.from(res));
    return const TimeclockMe(clockedIn: false);
  }

  /// `GET /api/timeclock/me/history` — my punches.
  Future<List<TimeclockEntry>> timeclockHistory() async {
    final res = await client.get('timeclock/me/history');
    final list = res is Map ? res['entries'] : res;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => TimeclockEntry.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `GET /api/timeclock` — the whole team's roster. Floor roles get a 403;
  /// that reads as "no roster section", never an error.
  Future<List<TimeclockEntry>> timeclockRoster() async {
    try {
      final res = await client.get('timeclock');
      if (res is! List) return const [];
      return res
          .whereType<Map>()
          .map((m) => TimeclockEntry.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } on ApiError catch (e) {
      if (e.status == 403 || e.status == 404) return const [];
      rethrow;
    }
  }

  /// `GET /api/staff` — roster names. Empty on a 403, like the web.
  Future<List<StaffMember>> staff() async {
    try {
      final res = await client.get('staff');
      if (res is! List) return const [];
      return res
          .whereType<Map>()
          .map((m) => StaffMember.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } on ApiError catch (e) {
      if (e.status == 403 || e.status == 404) return const [];
      rethrow;
    }
  }

  Future<void> clockIn() async {
    final res = await client.post('timeclock/clock-in', {});
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not clock in');
    }
  }

  /// `POST /api/timeclock/clock-out` — refused while checks are open unless
  /// [force] (the manager override, `{force:true}` on the wire).
  Future<void> clockOut({bool force = false}) async {
    final res = await client.post(
        'timeclock/clock-out', force ? {'force': true} : {});
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not clock out');
    }
  }

  Future<void> breakStart() => client.post('timeclock/break-start', {});

  /// Returns the break length the server computed, when it says.
  Future<int?> breakEnd() async {
    final res = await client.post('timeclock/break-end', {});
    if (res is Map && res['durationMin'] != null) {
      return int.tryParse('${res['durationMin']}');
    }
    return null;
  }

  /// `GET /api/handovers/latest`.
  Future<Handover?> latestHandover() async {
    try {
      final res = await client.get('handovers/latest');
      final h = res is Map ? res['handover'] : null;
      if (h is Map) return Handover.fromJson(Map<String, dynamic>.from(h));
      return null;
    } on ApiError catch (e) {
      if (e.status == 403 || e.status == 404) return null;
      rethrow;
    }
  }

  /// `POST /api/handovers` — camelCase on write (the server stores both).
  Future<void> postHandover({
    required String pendingOrders,
    required String pendingTasks,
    required String cashInfo,
    required String problems,
    required String customerIssues,
    required String importantNotes,
  }) async {
    await client.post('handovers', {
      'pendingOrders': pendingOrders,
      'pendingTasks': pendingTasks,
      'cashInfo': cashInfo,
      'problems': problems,
      'customerIssues': customerIssues,
      'importantNotes': importantNotes,
    });
  }

  /// `GET /api/payroll/me` — my contract + payslips.
  Future<PayrollMe> payrollMe() async {
    final res = await client.get('payroll/me');
    if (res is Map) return PayrollMe.fromJson(Map<String, dynamic>.from(res));
    return const PayrollMe();
  }

  /// `GET /api/audit?actor_id=…&from=…` — my own audit trail.
  Future<List<AuditEntry>> audit({
    required String actorId,
    required String from,
    String? to,
    int limit = 500,
  }) async {
    final q = 'audit?actor_id=$actorId&from=$from&limit=$limit'
        '${to != null ? '&to=$to' : ''}';
    final res = await client.get(q);
    final list = res is Map ? res['entries'] : res;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => AuditEntry.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  // ── Checks — split / move / merge, bill requests, per-line kitchen flow ───

  /// `POST /api/orders/:id/split {seatCount}` — returns the new check legs.
  Future<int> splitCheck(String orderId, int seatCount) async {
    final res =
        await client.post('orders/$orderId/split', {'seatCount': seatCount});
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not split the check');
    }
    final splits = res is Map ? res['splits'] : null;
    return splits is List ? splits.length : seatCount;
  }

  /// `POST /api/orders/:id/transfer {tableNumber}` — move the check. The
  /// table number rides as a string, exactly like the web.
  Future<void> transferCheck(String orderId, String tableNumber) async {
    final res = await client
        .post('orders/$orderId/transfer', {'tableNumber': tableNumber});
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not move the check');
    }
  }

  /// `POST /api/orders/merge {sourceOrderId, targetOrderId}`.
  Future<void> mergeChecks(String sourceOrderId, String targetOrderId) async {
    final res = await client.post('orders/merge', {
      'sourceOrderId': sourceOrderId,
      'targetOrderId': targetOrderId,
    });
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not merge checks');
    }
  }

  /// `POST /api/tables/:id/request-bill` — the party wants the bill; it rides
  /// to the cashier's dashboard as a bill request.
  Future<void> requestBill(String tableId) async {
    await client.post('tables/$tableId/request-bill', {});
  }

  /// `POST /api/tables/:id/cancel-bill-request`.
  Future<void> cancelBillRequest(String tableId) async {
    await client.post('tables/$tableId/cancel-bill-request', {});
  }

  // ── Kitchen per-line flow ─────────────────────────────────────────────────

  /// `GET /api/orders/items/active` — one row per live order line.
  Future<List<ActiveOrderItem>> orderItemsActive() async {
    final res = await client.get('orders/items/active');
    if (res is! List) return const [];
    return res
        .whereType<Map>()
        .map((m) => ActiveOrderItem.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `PUT /api/orders/:orderId/items/:itemId {status}` — advance one line.
  /// Returns the order's new overall status when the server says
  /// (`orderStatus`), e.g. `fulfilled` once every line is served.
  Future<String?> advanceOrderItem(
      String orderId, String itemId, String status) async {
    final res = await client.put('orders/$orderId/items/$itemId', {'status': status});
    return res is Map ? res['orderStatus']?.toString() : null;
  }

  // ── Small helpers ─────────────────────────────────────────────────────────

  static double _r2(double v) => (v * 100).roundToDouble() / 100;
}
