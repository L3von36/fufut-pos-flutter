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
  /// CheckoutView's no-tab flow. [breakdown] carries split-bill legs when the
  /// guest pays across methods; [tip]/[discount] ride the same body with the
  /// audited [discountReason].
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
    String? discountReason,
    List<PaymentLine>? breakdown,
    double deliveryFee = 0,
  }) async {
    final res = await client.post('orders', {
      'items': itemsSummary,
      'orderItems': lines.map((l) => l.toJson()).toList(),
      'subtotal': _r2(subtotal),
      'total': _r2(total),
      'status': 'new',
      'payment': paymentLabel,
      'paymentBreakdown':
          (breakdown ?? [payment]).map((p) => p.toJson()).toList(),
      'tip': _r2(tip),
      'tipType': tip > 0 ? 'fixed' : 'none',
      'discount': _r2(discount),
      'discountType': discount > 0 ? 'fixed' : 'none',
      if (discountReason != null && discountReason.isNotEmpty)
        'discountReason': discountReason,
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
  /// [tip] lands on the check (the staff's cut), [breakdown] carries split
  /// legs when the guest pays across methods.
  Future<void> settleOrder(
      FufutOrder order, String paymentLabel, PaymentLine payment,
      {double tip = 0, List<PaymentLine>? breakdown}) async {
    await client.put('orders/${order.id}', {
      'status': 'served',
      'payment': paymentLabel,
      'total': _r2(order.total),
      'subtotal': _r2(order.subtotal),
      if (tip > 0) ...{'tip': _r2(tip), 'tipType': 'fixed'},
      'paymentBreakdown':
          (breakdown ?? [payment]).map((p) => p.toJson()).toList(),
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

  // ── Operations alerts — the web AlertsBanner's three calls ───────────────

  /// `GET /api/alerts` — the open SLA breaches. The endpoint answers either a
  /// bare array or `{ok, alerts}` depending on the handler path; both parse.
  /// A refused fetch (role without the resource) surfaces as an ApiError the
  /// banner swallows into an empty list — silence, not an error banner on an
  /// error banner.
  Future<List<OpsAlert>> alerts() async {
    final res = await client.get('alerts');
    final List rows;
    if (res is List) {
      rows = res;
    } else if (res is Map && res['alerts'] is List) {
      rows = res['alerts'] as List;
    } else {
      return const [];
    }
    return rows
        .whereType<Map>()
        .map((m) => OpsAlert.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `POST /api/alerts/:id/acknowledge` — per-alert ack (manager, head-chef,
  /// head-waiter, cashier). Other roles get the server's 403 and the banner
  /// renders no button for them in the first place.
  Future<void> acknowledgeAlert(String id) async {
    await client.post('alerts/$id/acknowledge', {});
  }

  /// `POST /api/alerts/acknowledge-all` — manager only ("Manager only" 403
  /// for everyone else; the banner's bulk button is manager-gated to match).
  Future<void> acknowledgeAllAlerts() async {
    await client.post('alerts/acknowledge-all', {});
  }

  // ── Backoffice — the manager/accountant/chef domains (web parity) ────────

  // Menu management (`MenuMgmtView.vue`)

  /// `POST /api/menu` — catalogue add (manager).
  Future<void> postMenu(Map<String, dynamic> payload) async {
    final res = await client.post('menu', payload);
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not save the item');
    }
  }

  /// `PUT /api/menu/:id` — catalogue edit (manager).
  Future<void> updateMenu(String id, Map<String, dynamic> payload) async {
    final res = await client.put('menu/$id', payload);
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not save the item');
    }
  }

  /// `DELETE /api/menu/:id` (manager).
  Future<void> deleteMenu(String id) async {
    await client.delete('menu/$id', {'id': id});
  }

  /// `PUT /api/menu/:id/availability {available}` — the dish-86 toggle,
  /// chef-permitted; the server stamps changedBy/changedAt.
  Future<void> setAvailability(String id, bool available) async {
    final res = await client.put('menu/$id/availability', {'available': available});
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not change availability');
    }
  }

  // Tables management (`TablesView.vue` manager tools)

  /// `POST /api/tables` — add a table to the floor (manager).
  Future<void> addTable({
    required String number,
    required int capacity,
    String? section,
    String? name,
    String shape = 'square',
  }) async {
    final res = await client.post('tables', {
      'number': number,
      'capacity': capacity,
      if (section != null && section.isNotEmpty) 'section': section,
      if (name != null && name.isNotEmpty) 'name': name,
      'shape': shape,
    });
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not add the table');
    }
  }

  /// `DELETE /api/tables/:id` (manager).
  Future<void> deleteTable(String id) async {
    await client.delete('tables/$id', {'id': id});
  }

  /// `PUT /api/tables/:id` — generic edit (status quick-set, guests,
  /// server assignment) without touching seating.
  Future<void> updateTable(String id, Map<String, dynamic> payload) async {
    final res = await client.put('tables/$id', payload);
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not update the table');
    }
  }

  // Orders extras (`OrdersView.vue` quick-sale, QR accept, `ReportsView.vue`)

  /// `GET /api/orders/pending` — guest QR orders waiting to be accepted.
  Future<List<FufutOrder>> pendingOrders() async {
    final res = await client.get('orders/pending');
    if (res is! List) return const [];
    return res
        .whereType<Map>()
        .map((m) => FufutOrder.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `POST /api/orders/:id/accept` — accept a QR order into the kitchen.
  Future<void> acceptOrder(String id) async {
    await client.post('orders/$id/accept', {});
  }

  /// `GET /api/orders/timing?from=` — kitchen time-to-table rows, one per
  /// category ({category, served, averageMinutes, fastestMinutes,
  /// slowestMinutes}). The top-level `sampled` count is folded into each row
  /// for the section header.
  Future<List<Map<String, dynamic>>> orderTiming(String fromIso) async {
    final res = await client.get('orders/timing?from=$fromIso');
    if (res is! Map) return const [];
    final sampled = res['sampled'];
    final cats = res['categories'];
    if (cats is! List) return const [];
    return cats
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m)
          ..['sampled'] = sampled)
        .toList();
  }

  // Reservations (`ReservationsView.vue`)

  /// `GET /api/reservations/availability?date&time&duration` — table ids
  /// already held at that slot.
  Future<Set<String>> reservationAvailability(
      String date, String time, int durationMin) async {
    final res = await client.get(
        'reservations/availability?date=$date&time=$time&duration=$durationMin');
    final list = res is Map ? res['taken'] ?? res['tableIds'] : res;
    if (list is! List) return const {};
    return list.map((e) => e.toString()).toSet();
  }

  /// `POST /api/reservations` — book a table. A 409 clash carries the
  /// server's message ("Table 7 is taken at that time").
  Future<void> postReservation({
    required String name,
    required int guests,
    required String date,
    required String time,
    required String tableNum,
    String? phone,
    int durationMin = 90,
  }) async {
    final res = await client.post('reservations', {
      'name': name.trim(),
      'guests': guests,
      'date': date,
      'time': time,
      'tableNum': tableNum,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      'duration_min': durationMin,
      'status': 'new',
    });
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not book the table');
    }
  }

  /// `PUT /api/reservations/:id {status}` — confirm / complete / cancel.
  Future<void> updateReservation(String id, String status) async {
    await client.put('reservations/$id', {'status': status});
  }

  /// `POST /api/reservations/:id/release` — free a no-show hold.
  Future<void> releaseReservation(String id) async {
    await client.post('reservations/$id/release', {});
  }

  // Expenses (`ExpensesView.vue`) — manager + accountant's write domain

  /// `GET /api/expenses`.
  Future<List<Expense>> expenses() async {
    final res = await client.get('expenses');
    if (res is! List) return const [];
    return res
        .whereType<Map>()
        .map((m) => Expense.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<void> postExpense({
    required String category,
    required String description,
    required double amount,
    required String date,
  }) async {
    final res = await client.post('expenses', {
      'category': category,
      'description': description.trim(),
      'amount': _r2(amount),
      'date': date,
    });
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not record the expense');
    }
  }

  Future<void> updateExpense(String id, Map<String, dynamic> payload) async {
    final res = await client.put('expenses/$id', payload);
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not save the expense');
    }
  }

  Future<void> deleteExpense(String id) async {
    await client.delete('expenses/$id', {'id': id});
  }

  // Customers (`CustomersView.vue`)

  /// `GET /api/customers[?q=]`.
  Future<List<Customer>> customers({String query = ''}) async {
    final res = await client.get(query.isEmpty ? 'customers' : 'customers?q=$query');
    final list = res is Map ? res['customers'] : res;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => Customer.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `POST /api/customers` — add a loyalty profile.
  Future<void> postCustomer({
    required String name,
    String phone = '',
    String email = '',
    String notes = '',
  }) async {
    final res = await client.post('customers', {
      'name': name.trim(),
      'phone': phone.trim(),
      'email': email.trim(),
      'notes': notes.trim(),
    });
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not add the customer');
    }
  }

  /// `POST /api/customers/:id/points {points, description}` — returns the
  /// new balance.
  Future<int?> adjustCustomerPoints(
      String id, int points, String description) async {
    final res = await client.post('customers/$id/points', {
      'points': points,
      'description': description.trim(),
    });
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not adjust points');
    }
    return res is Map && res['newBalance'] != null
        ? int.tryParse('${res['newBalance']}')
        : null;
  }

  // Inventory (`InventoryView.vue`) + stock control (`StockControlView.vue`)

  /// `GET /api/inventory` — the stock catalogue.
  Future<List<InventoryItem>> inventory() async {
    try {
      final res = await client.get('inventory');
      if (res is! List) return const [];
      return res
          .whereType<Map>()
          .map((m) => InventoryItem.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } on ApiError catch (e) {
      // Any refusal (400/403/404) reads as "no catalogue visible" — the
      // waste screen's free-text path keeps working for the cleaner. A 401
      // is still fatal (the session is gone).
      if (e.isAuthError) rethrow;
      return const [];
    }
  }

  /// `POST /api/inventory` — catalogue add (manager + head-chef).
  Future<void> postInventory({
    required String name,
    required String category,
    required String unit,
    required double quantity,
    required double minLevel,
    double cost = 0,
  }) async {
    final res = await client.post('inventory', {
      'name': name.trim(),
      'category': category,
      'unit': unit,
      'quantity': quantity,
      'minLevel': minLevel,
      'cost': _r2(cost),
    });
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not add the item');
    }
  }

  /// `PUT /api/inventory/:id` — catalogue fields only; the server refuses
  /// direct quantity writes (the ledger owns stock).
  Future<void> updateInventory(String id, Map<String, dynamic> payload) async {
    final res = await client.put('inventory/$id', payload);
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not save the item');
    }
  }

  /// `POST /api/inventory/:id/adjust {newQty|qty, reason}` — the audited
  /// ledger adjustment. Returns the new stock level when the server says.
  Future<double?> adjustInventory(String id, double newQty, String reason) async {
    final res = await client.post('inventory/$id/adjust', {
      'newQty': newQty,
      'reason': reason.trim(),
    });
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not adjust stock');
    }
    final s = res is Map ? res['stock'] : null;
    return s is num
        ? s.toDouble()
        : s is String ? double.tryParse(s) : null;
  }

  /// `DELETE /api/inventory/:id` (manager).
  Future<void> deleteInventory(String id) async {
    await client.delete('inventory/$id', {'id': id});
  }

  /// `GET /api/inventory/reorder` — the buying list.
  Future<List<ReorderRow>> inventoryReorder() async {
    final res = await client.get('inventory/reorder');
    final list = res is Map ? res['items'] ?? res['rows'] : res;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => ReorderRow.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `GET /api/inventory/variance?from&to` — expected vs actual.
  Future<List<VarianceRow>> inventoryVariance(String fromIso, String toIso) async {
    final res =
        await client.get('inventory/variance?from=$fromIso&to=$toIso');
    final list = res is Map ? res['rows'] ?? res['items'] : res;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => VarianceRow.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `GET /api/inventory/snapshot?date=` — stock as of end of that day.
  Future<List<SnapshotRow>> inventorySnapshot(String date) async {
    final res = await client.get('inventory/snapshot?date=$date');
    final list = res is Map ? res['rows'] ?? res['items'] : res;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => SnapshotRow.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `GET /api/inventory/forecast?from&to`.
  Future<List<ForecastRow>> inventoryForecast(String fromIso, String toIso) async {
    final res =
        await client.get('inventory/forecast?from=$fromIso&to=$toIso');
    final list = res is Map ? res['rows'] ?? res['items'] : res;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => ForecastRow.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `GET /api/inventory/capacity` — what can we make right now.
  Future<List<CapacityRow>> inventoryCapacity() async {
    final res = await client.get('inventory/capacity');
    final list = res is Map ? res['rows'] ?? res['items'] : res;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => CapacityRow.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `POST /api/inventory/count {items:[{inventoryId, countedQty, reason}]}`
  /// — post a physical count; blank rows are never treated as zero.
  Future<void> postInventoryCount(
      List<Map<String, dynamic>> items, String notes) async {
    final res = await client.post('inventory/count', {
      'items': items,
      if (notes.trim().isNotEmpty) 'notes': notes.trim(),
    });
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not post the count');
    }
  }

  // Waste — manager delete (`WasteView.vue`)

  /// `DELETE /api/waste/:id` (manager only on the web).
  Future<void> deleteWaste(String id) async {
    await client.delete('waste/$id', {'id': id});
  }

  // Recipes (`RecipesView.vue`)

  /// `GET /api/recipes` — the BOM list.
  Future<List<RecipeRow>> recipes() async {
    final res = await client.get('recipes');
    final list = res is Map ? res['recipes'] : res;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => RecipeRow.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `GET /api/recipes/:id` — full detail with lines.
  Future<RecipeRow?> recipeDetail(String id) async {
    final res = await client.get('recipes/$id');
    final row = res is Map ? res['recipe'] ?? res : null;
    if (row is! Map) return null;
    return RecipeRow.fromJson(Map<String, dynamic>.from(row));
  }

  /// `GET /api/recipes/:id/capacity`.
  Future<RecipeCapacity> recipeCapacity(String id) async {
    final res = await client.get('recipes/$id/capacity');
    if (res is Map) {
      return RecipeCapacity.fromJson(Map<String, dynamic>.from(res));
    }
    return const RecipeCapacity();
  }

  /// `GET /api/recipes/:id/versions`.
  Future<List<RecipeVersion>> recipeVersions(String id) async {
    final res = await client.get('recipes/$id/versions');
    final list = res is Map ? res['versions'] : res;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => RecipeVersion.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `POST /api/recipes` — create the next version of a recipe.
  Future<void> postRecipe({
    required String menuItemId,
    required String name,
    String variant = '',
    double yieldQty = 1,
    String notes = '',
    required List<Map<String, dynamic>> lines,
  }) async {
    final res = await client.post('recipes', {
      'menuItemId': menuItemId,
      'name': name,
      if (variant.isNotEmpty) 'variant': variant,
      'yieldQty': yieldQty,
      if (notes.isNotEmpty) 'notes': notes,
      'lines': lines,
    });
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not save the recipe');
    }
  }

  /// `GET /api/units` — measurement units grouped by dimension. The server
  /// answers `{ok, units: {mass: [...], volume: [...], …}}`; a bare list is
  /// accepted too (older shape).
  Future<List<UnitRow>> units() async {
    final res = await client.get('units');
    final List rows;
    if (res is List) {
      rows = res;
    } else if (res is Map && res['units'] is Map) {
      rows = [
        for (final e in (res['units'] as Map).entries)
          ...(e.value is List
              ? (e.value as List)
                  .whereType<Map>()
                  .map((m) => Map<String, dynamic>.from(m))
                  .map((m) => {...m, 'dimension': m['dimension'] ?? e.key})
              : const <Map<String, dynamic>>[]),
      ];
    } else {
      return const [];
    }
    return rows
        .whereType<Map>()
        .map((m) => UnitRow.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  // Suppliers (`SuppliersView.vue`)

  /// `GET /api/suppliers` — vendor directory with money joined.
  Future<List<Supplier>> suppliers() async {
    final res = await client.get('suppliers');
    if (res is! List) return const [];
    return res
        .whereType<Map>()
        .map((m) => Supplier.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `GET /api/suppliers/:id` — statement ({supplier, totals, purchases}).
  Future<Map<String, dynamic>?> supplierStatement(String id) async {
    final res = await client.get('suppliers/$id');
    return res is Map ? Map<String, dynamic>.from(res) : null;
  }

  /// `POST /api/suppliers` (manager).
  Future<void> postSupplier(Map<String, dynamic> payload) async {
    final res = await client.post('suppliers', payload);
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not save the supplier');
    }
  }

  /// `PUT /api/suppliers/:id` (manager).
  Future<void> updateSupplier(String id, Map<String, dynamic> payload) async {
    final res = await client.put('suppliers/$id', payload);
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not save the supplier');
    }
  }

  // Purchases (`PurchasesView.vue`)

  /// `GET /api/purchases[?from=&to=]`.
  Future<List<Purchase>> purchases({String? from, String? to}) async {
    final q = [
      if (from != null && from.isNotEmpty) 'from=$from',
      if (to != null && to.isNotEmpty) 'to=$to',
    ].join('&');
    final res =
        await client.get(q.isEmpty ? 'purchases' : 'purchases?$q');
    if (res is! List) return const [];
    return res
        .whereType<Map>()
        .map((m) => Purchase.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `GET /api/purchases/:id` — the note with its item lines.
  Future<Purchase?> purchaseDetail(String id) async {
    final res = await client.get('purchases/$id');
    if (res is! Map) return null;
    return Purchase.fromJson(Map<String, dynamic>.from(res));
  }

  /// `POST /api/purchases` — record goods received (manager).
  Future<void> postPurchase({
    required String supplierId,
    required String date,
    required List<Map<String, dynamic>> items,
    required double total,
    double paid = 0,
    String paymentMethod = 'cash',
    String notes = '',
  }) async {
    final res = await client.post('purchases', {
      'supplierId': supplierId,
      'date': date,
      'items': items,
      'total': _r2(total),
      'paid': _r2(paid),
      'paymentMethod': paymentMethod,
      if (notes.isNotEmpty) 'notes': notes,
    });
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not record the purchase');
    }
  }

  /// `POST /api/purchases/analyse` — the projection preview for one line.
  Future<PurchaseAnalyse> analysePurchase({
    required String inventoryId,
    required double qty,
    required String unit,
    required double totalCost,
  }) async {
    final res = await client.post('purchases/analyse', {
      'inventoryId': inventoryId,
      'qty': qty,
      'unit': unit,
      'totalCost': _r2(totalCost),
    });
    if (res is Map) {
      return PurchaseAnalyse.fromJson(Map<String, dynamic>.from(res));
    }
    return const PurchaseAnalyse();
  }

  /// `POST /api/purchases/:id/pay {amount, method}` — pay a supplier.
  Future<void> payPurchase(String id, double amount, String method) async {
    final res = await client.post(
        'purchases/$id/pay', {'amount': _r2(amount), 'method': method});
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not record the payment');
    }
  }

  // Shifts (`ShiftsView.vue`) — the roster

  /// `GET /api/shifts` — the roster. Manager-only on the server; other
  /// roles get the 403 and read an empty list (view-only screen never
  /// renders for them anyway).
  Future<List<ShiftRow>> shifts() async {
    try {
      final res = await client.get('shifts');
      if (res is! List) return const [];
      return res
          .whereType<Map>()
          .map((m) => ShiftRow.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } on ApiError catch (e) {
      if (e.status == 403 || e.status == 404) return const [];
      rethrow;
    }
  }

  /// `POST /api/shifts` (manager).
  Future<void> postShift({
    required String staffId,
    required String shiftType,
    required String date,
    required String start,
    required String end,
  }) async {
    final res = await client.post('shifts', {
      'staffId': staffId,
      'shiftType': shiftType,
      'date': date,
      'start': start,
      'end': end,
    });
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not add the shift');
    }
  }

  /// `PUT /api/shifts/:id` (manager).
  Future<void> updateShift(String id, Map<String, dynamic> payload) async {
    final res = await client.put('shifts/$id', payload);
    if (res is Map && res['ok'] == false) {
      throw ApiError((res['error'] as String?) ?? 'Could not save the shift');
    }
  }

  /// `DELETE /api/shifts/:id` (manager).
  Future<void> deleteShift(String id) async {
    await client.delete('shifts/$id', {'id': id});
  }

  // Alerts dashboard (`AlertsDashboardView.vue`) + audit log + reports extras

  /// `GET /api/alerts?status=<open|acknowledged|resolved>&limit=`.
  Future<List<OpsAlert>> alertsByStatus(String status, {int limit = 100}) async {
    final res = await client.get('alerts?status=$status&limit=$limit');
    final List rows;
    if (res is List) {
      rows = res;
    } else if (res is Map && res['alerts'] is List) {
      rows = res['alerts'] as List;
    } else {
      return const [];
    }
    return rows
        .whereType<Map>()
        .map((m) => OpsAlert.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `GET /api/audit?entity=&action=&actor_id=&from=&to=&limit=` — the
  /// admin audit trail (manager).
  Future<List<AuditEntry>> auditFiltered({
    String? entity,
    String? action,
    String? actorId,
    String? from,
    String? to,
    int limit = 500,
  }) async {
    final q = StringBuffer('audit?limit=$limit');
    if (entity != null && entity.isNotEmpty) q.write('&entity=$entity');
    if (action != null && action.isNotEmpty) q.write('&action=$action');
    if (actorId != null && actorId.isNotEmpty) q.write('&actor_id=$actorId');
    if (from != null && from.isNotEmpty) q.write('&from=$from');
    if (to != null && to.isNotEmpty) q.write('&to=$to');
    final res = await client.get(q.toString());
    final list = res is Map ? res['entries'] : res;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => AuditEntry.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// `GET /api/reports/staff-performance` → `.staff`.
  Future<List<Map<String, dynamic>>> staffPerformance() async {
    final res = await client.get('reports/staff-performance');
    final list = res is Map ? res['staff'] : res;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  /// `GET /api/reports/hourly-heatmap` → `.hours` (7×24 grid rows).
  Future<List<Map<String, dynamic>>> hourlyHeatmap() async {
    final res = await client.get('reports/hourly-heatmap');
    final list = res is Map ? res['hours'] : res;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  // ── Small helpers ─────────────────────────────────────────────────────────

  static double _r2(double v) => (v * 100).roundToDouble() / 100;
}
