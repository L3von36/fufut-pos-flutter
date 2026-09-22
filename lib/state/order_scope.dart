/// Which orders a role sees on the Orders screen, and which lines of each —
/// the Flutter half of the web POS `lib/orderScope.js`, kept rule-for-rule.
///
/// The boards route strictly by station, but a shared Orders list showed the
/// waiter the chef's tickets and one waiter another waiter's tables. This is
/// the single source of truth for that screen's scoping:
///
///   barista                    tickets with at least one drink line, drinks only
///   head-chef, assistant-chef  tickets with at least one food line, food only
///   head-waiter                tickets he created, or tickets sitting on a
///                              table assigned to him — whole ticket, because
///                              the whole guest's bill is his to run
///   everyone else              unchanged (manager, cashier, accountant…)
///
/// "Drink" is judged exactly the way the boards judge it — `nameIsDrink` in
/// `state/roles.dart` carries the web's DRINK_WORDS regex. The scoping is a
/// screen focus, not a security boundary: every one of these roles already
/// holds a server-side orders READ grant, so nothing new is exposed here;
/// what changes is what the screen puts in front of them.
library;

import '../models/models.dart';
import 'roles.dart';

/// One parsed line of a legacy flat summary — enough to classify a ticket
/// when the structured lines are absent.
class _FlatLine {
  final String name;
  final int qty;
  const _FlatLine(this.name, this.qty);
}

/// Mirror of the server's parseFlatItems (fufut-api/src/lib/timing.js), which
/// has seen these shapes in production: "1xMacchiato, 1xFut breakfast Gebeta"
/// and "2x Latte [oat-milk, vanilla] (extra hot), 1x Espresso". Splitting on
/// a comma alone would break every dish whose name contains one, so the split
/// lands only where a comma is followed by the next "<qty>x" marker.
List<_FlatLine> _parseFlatItems(String flat) {
  final text = flat.trim();
  if (text.isEmpty) return const [];
  final chunks = text.split(RegExp(r',\s*(?=\d+\s*x)', caseSensitive: false));
  final out = <_FlatLine>[];
  for (final chunk in chunks) {
    final m = RegExp(r'^(\d+)\s*x\s*(.+)$', caseSensitive: false)
        .firstMatch(chunk.trim());
    if (m == null) continue;
    final name = m
        .group(2)!
        .replaceAll(RegExp(r'\[[^\]]*\]'), '') // modifier list
        .replaceAll(RegExp(r'\([^)]*\)'), '') // line note
        .trim();
    if (name.isEmpty) continue;
    out.add(_FlatLine(name, int.tryParse(m.group(1)!) ?? 1));
  }
  return out;
}

bool _lineIsDrink(String name, {String? category}) {
  if (category != null && nameIsDrink(category, '')) return true;
  return nameIsDrink('', name);
}

/// The board's renderable lines of a ticket: the structured lines when the
/// order row carries them, the legacy flat summary parsed back into lines
/// otherwise. The /api/orders rows (and the SSE snapshots built from them)
/// carry NO `orderItems` — just the flat "2x Latte, 1xDish" string the
/// server stores on the order — so without this fallback every pushed
/// ticket parsed line-less and the board filtered it into silence.
List<OrderItemLine> boardLines(FufutOrder order) {
  if (order.items.isNotEmpty) return order.items;
  return [
    for (final f in _parseFlatItems(order.itemsRaw))
      OrderItemLine(
        menuItemId: null,
        name: f.name,
        basePrice: 0,
        qty: f.qty,
        lineTotal: 0,
      ),
  ];
}

/// The station's own lines of a ticket. [station] is 'bar' (drinks) or
/// 'kitchen' (everything else), matching the board filters. Reads the
/// structured lines when the ticket carries them, falls back to the legacy
/// flat summary otherwise. Null means genuinely unclassifiable — the caller
/// fails OPEN: a ticket nobody can classify is shown rather than silently
/// hiding somebody's work behind a parse failure.
List<OrderItemLine>? scopedLines(FufutOrder order, String station) {
  final wantDrink = station == 'bar';
  if (order.items.isNotEmpty) {
    return order.items
        .where((l) => _lineIsDrink(l.name) == wantDrink)
        .toList();
  }
  // Legacy flat summary: reconstruct just enough line shape to classify.
  final flats = _parseFlatItems(order.itemsRaw);
  if (flats.isEmpty) return null;
  final names = flats.where((f) => _lineIsDrink(f.name) == wantDrink);
  if (names.isEmpty) return const [];
  return [
    for (final f in names)
      OrderItemLine(
        menuItemId: null,
        name: f.name,
        basePrice: 0,
        qty: f.qty,
        lineTotal: 0,
      ),
  ];
}

/// Does this order belong on this role's Orders screen at all?
///
/// [myId] is the signed-in staff id (orders stamp the creator's id
/// server-side as created_by); [myTables] carries the table numbers the
/// caller may work — for a head-waiter the server already narrows /api/tables
/// to the tables assigned to them by name.
bool orderVisibleToRole(
  FufutOrder order,
  String? roleKey, {
  String? myId,
  Set<String> myTables = const {},
}) {
  final role = (roleKey ?? '').toLowerCase();
  switch (role) {
    case 'barista':
      final lines = scopedLines(order, 'bar');
      return lines == null || lines.isNotEmpty;
    case 'head-chef':
    case 'assistant-chef':
      final lines = scopedLines(order, 'kitchen');
      return lines == null || lines.isNotEmpty;
    case 'head-waiter':
      final mine = myId != null &&
          myId.isNotEmpty &&
          order.createdById == myId;
      if (mine) return true;
      // A ticket on one of his assigned tables is his to run even when a
      // colleague or a guest QR order fired it. Takeaways with no table stay
      // with whoever took them.
      if (myTables.isEmpty) return false;
      final tid = order.tableNum ?? '';
      return tid.isNotEmpty && myTables.contains(tid);
    default:
      return true;
  }
}

/// The lines of a ticket this role should READ, or null to show the ticket
/// unchanged. Station roles get only their own lines — the same strict split
/// the boards use, so a dimmed Chechebesa line never sits in the barista's
/// list implying it is theirs to make.
List<OrderItemLine>? orderLinesForRole(FufutOrder order, String? roleKey) {
  switch ((roleKey ?? '').toLowerCase()) {
    case 'barista':
      return scopedLines(order, 'bar');
    case 'head-chef':
    case 'assistant-chef':
      return scopedLines(order, 'kitchen');
    default:
      return null;
  }
}

/// The empty-state hint per role — the web OrdersView's three lines.
String emptyOrdersHint(String? roleKey) {
  switch ((roleKey ?? '').toLowerCase()) {
    case 'barista':
      return 'Drink tickets will appear here as they are ordered.';
    case 'head-chef':
    case 'assistant-chef':
      return 'Food tickets will appear here as they are ordered.';
    case 'head-waiter':
      return 'Orders you take, or on your assigned tables, will appear here.';
    default:
      return 'No orders match the current filters.';
  }
}

// ── Day scoping ──────────────────────────────────────────────────────────────

/// Today as a `YYYY-MM-DD` key in the device's local calendar. Server rows
/// carry naive local-time stamps ("2026-08-06 01:55:46"), never UTC, so the
/// day is the ten-character prefix of `created` — string-prefix matching is
/// the established, timezone-safe pattern (role_dashboard, alerts, waste…).
String localTodayKey([DateTime? now]) {
  final n = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${n.year}-${two(n.month)}-${two(n.day)}';
}

/// True when the order was created today — the live service day. Operational
/// screens (Orders, Pipeline, Open Checks) show today's tickets only; older
/// ones belong to Order History.
bool orderIsToday(FufutOrder o, {DateTime? now}) =>
    (o.created ?? '').startsWith(localTodayKey(now));

/// True when the order counts as real money — the Flutter mirror of the web's
/// `isRealOrder` / the API's REAL_ORDERS rule (`voided_at IS NULL AND status
/// <> 'cancelled'`). A void sets both markers, so either one excludes.
bool orderIsReal(FufutOrder o) {
  if ((o.voidedAt ?? '').isNotEmpty) return false;
  final s = o.status.toLowerCase();
  return s != 'cancelled' && s != 'voided';
}
