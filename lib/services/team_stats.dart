/// Team performance — the per-person numbers behind the Team screen.
///
/// Pure aggregation: no Flutter widgets, no network. The screen feeds rows
/// in (the day's orders, the floor tables, the till's payments, the audit
/// log's stage rows) and reads aggregated sections out; the tests feed
/// fixtures and assert the arithmetic, so the math here is the single place
/// that decides what "how good is each of them doing" means.
///
/// Attribution, per section:
///
///   * **Floor** — an order belongs to the person who took it
///     (`created_by_name`, stamped by the server at POST time). Money,
///     tips and the take→serve clock are theirs.
///   * **Kitchen / Bar** — a stage belongs to the person whose account
///     tapped it: the audit log's `status` rows (fufut-api writes one per
///     real transition, actor attached, commit d89ed50). Rows only exist
///     from that deploy on — an empty history reads as "no data yet",
///     never as "nobody worked".
///   * **Till** — a payment belongs to the person recorded in
///     `collected_by_name` the moment the money was taken; the verify
///     queue answers to its own status.
///
/// Guests are an estimate by nature: a table's party size counts once, for
/// the person who took the party's first ticket; every takeaway/delivery
/// order counts one; a dine-in ticket whose table carries no party number
/// counts one too. The screen labels the figure "(est.)" for the same
/// reason — the honest word for a number the floor never scans.
library;

import '../models/models.dart';
import '../state/order_scope.dart' show scopedLines;

// ─────────────────────────────────────────────────────────────────────────────
// Time helpers — two stamp shapes live in the data
// ─────────────────────────────────────────────────────────────────────────────

/// Parses both stamp shapes the API emits: the orders' naive local
/// wall-clock ("2026-08-06 01:55:46") and the UTC ISO stamps
/// ("2026-09-25T07:12:33.000Z" — audit rows, payments, the stage columns).
/// UTC converts to local, so every duration is computed on one clock.
DateTime? teamParseStamp(String? s) {
  if (s == null || s.isEmpty) return null;
  final d = DateTime.tryParse(s.trim().replaceFirst(' ', 'T'));
  if (d == null) return null;
  return d.isUtc ? d.toLocal() : d;
}

/// The local `YYYY-MM-DD` day key of any stamp — the same shape
/// `localTodayKey` produces, so day windows compare as plain strings.
String? teamDayKey(String? s) {
  final d = teamParseStamp(s);
  if (d == null) return null;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// Minutes between two stamps, or null when either leg never happened or
/// runs backwards — a live ticket never drags an average negative.
double? _minsBetween(String? a, String? b) {
  final ta = teamParseStamp(a);
  final tb = teamParseStamp(b);
  if (ta == null || tb == null || !tb.isAfter(ta)) return null;
  return tb.difference(ta).inMicroseconds / Duration.microsecondsPerMinute;
}

double? _avg(List<double> xs) =>
    xs.isEmpty ? null : xs.reduce((a, b) => a + b) / xs.length;

// ─────────────────────────────────────────────────────────────────────────────
// Result shapes
// ─────────────────────────────────────────────────────────────────────────────

/// One floor person's day.
class FloorStaffDay {
  final String name;
  int orders = 0;
  double sales = 0; // money brought in, tips excluded
  double tips = 0;
  int guests = 0; // estimated covers (see the library doc)
  int served = 0; // of their tickets, how many reached served
  final List<double> _serveMins = [];

  FloorStaffDay(this.name);

  double? get avgServeMin => _avg(_serveMins);
}

/// One station person's day, read from the audit log's stage rows.
class StationPersonDay {
  final String name;
  int bumped = 0; // lines/orders pushed into preparing
  int readied = 0; // lines/orders pushed into ready
  final List<double> _makeMins = []; // per ticket they readied

  StationPersonDay(this.name);

  double? get avgMakeMin => _avg(_makeMins);

  int get touches => bumped + readied;
}

/// One station's day — ticket flow from the order stamps, per-person
/// attribution from the audit rows.
class StationDay {
  final String name; // 'Kitchen' | 'Bar'
  int tickets = 0;
  int items = 0;
  final List<double> _newMins = []; // created → preparing
  final List<double> _makeMins = []; // preparing → ready
  final List<double> _passMins = []; // ready → picked up
  final Map<String, StationPersonDay> people = {};

  StationDay(this.name);

  double? get avgNewMin => _avg(_newMins);
  double? get avgMakeMin => _avg(_makeMins);
  double? get avgPassMin => _avg(_passMins);

  List<StationPersonDay> get peopleSorted {
    final list = people.values.toList()
      ..sort((a, b) => b.touches.compareTo(a.touches));
    return list;
  }
}

/// One till person's day.
class TillStaffDay {
  final String name;
  int payments = 0;
  double collected = 0; // positive money taken; refunds are not takings
  int transfersVerified = 0; // non-cash rows that left the verify queue

  TillStaffDay(this.name);
}

/// The whole day, every section the viewer's role may see.
class TeamDayStats {
  final String dayKey;
  int ordersCount = 0; // real orders (voided/cancelled excluded)
  double revenue = 0; // order totals minus tips — the same rule Analytics uses
  double tips = 0;
  int guests = 0; // estimated covers
  double? avgServeMin; // mean take→serve across the day — the house pace
  final List<FloorStaffDay> floor = [];
  final StationDay kitchen = StationDay('Kitchen');
  final StationDay bar = StationDay('Bar');
  final List<TillStaffDay> till = [];
  final Map<String, double> moneyByMethod = {};
  int transfersPending = 0; // recorded, not yet verified

  TeamDayStats(this.dayKey);
}

// ─────────────────────────────────────────────────────────────────────────────
// The engine
// ─────────────────────────────────────────────────────────────────────────────

/// True when the order counts as real money — the API's REAL_ORDERS rule
/// (`voided_at IS NULL AND status <> 'cancelled'`), mirrored in order_scope.
bool teamOrderIsReal(FufutOrder o) {
  if ((o.voidedAt ?? '').isNotEmpty) return false;
  final s = o.status.toLowerCase();
  return s != 'cancelled' && s != 'voided';
}

/// Computes the day. [orders] must already be windowed to the day by the
/// caller; [payments] and [statusRows] arrive as wider fetches and are
/// filtered here. [tablesByNumber] feeds the guest estimate; [catByName]
/// feeds the kitchen/bar split (same rule the boards ride).
TeamDayStats computeTeamDay({
  required String dayKey,
  required List<FufutOrder> orders,
  Map<String, CafeTable> tablesByNumber = const {},
  List<FufutPayment> payments = const [],
  List<AuditEntry> statusRows = const [],
  Map<String, String>? catByName,
}) {
  final stats = TeamDayStats(dayKey);
  final floorByName = <String, FloorStaffDay>{};
  final partiesSeen = <String>{}; // tables whose party already counted
  final orderById = {for (final o in orders) o.id: o};

  // ── Orders: the house picture + the floor section ────────────────────────
  for (final o in orders) {
    if (!teamOrderIsReal(o)) continue;
    stats.ordersCount++;
    stats.revenue += o.total - o.tip;
    stats.tips += o.tip;

    final who = (o.createdByName ?? '').trim();
    final person = floorByName.putIfAbsent(
        who.isNotEmpty ? who : 'Unassigned', () => FloorStaffDay(who));
    person.orders++;
    person.sales += o.total - o.tip;
    person.tips += o.tip;
    if ((o.servedAt ?? '').isNotEmpty) person.served++;

    // Guest estimate: a table's party counts once — the first ticket naming
    // the table claims it; later tickets from the same party add nothing.
    final type = (o.type ?? '').toLowerCase();
    final tableKey = (o.tableNum ?? '').trim();
    final isSitDown = type != 'takeaway' && type != 'delivery' && tableKey.isNotEmpty;
    if (isSitDown && !partiesSeen.contains(tableKey)) {
      partiesSeen.add(tableKey);
      final party = tablesByNumber[tableKey]?.partySize ?? 0;
      person.guests += party > 0 ? party : 1;
    } else if (!isSitDown) {
      person.guests += 1;
    }

    final serve = _minsBetween(o.created, o.servedAt);
    if (serve != null) person._serveMins.add(serve);
  }

  stats.floor.addAll(floorByName.values);
  stats.floor.sort((a, b) => b.sales.compareTo(a.sales));
  for (final p in floorByName.values) {
    stats.guests += p.guests;
  }
  final allServe = <double>[
    for (final p in floorByName.values) ...p._serveMins,
  ];
  stats.avgServeMin = _avg(allServe);

  // ── Stations: ticket flow from the order stamps ──────────────────────────
  void stationFlow(StationDay st, bool drinks) {
    for (final o in orders) {
      if (!teamOrderIsReal(o)) continue;
      final lines = scopedLines(o, drinks ? 'bar' : 'kitchen',
          catByName: catByName);
      if (lines == null || lines.isEmpty) continue;
      st.tickets++;
      st.items += lines.fold<int>(0, (s, l) => s + l.qty);
      final inNew = _minsBetween(o.created, o.preparingAt);
      if (inNew != null) st._newMins.add(inNew);
      final make = _minsBetween(o.preparingAt, o.readyAt);
      if (make != null) st._makeMins.add(make);
      final pass = _minsBetween(o.readyAt, o.pickedUpAt);
      if (pass != null) st._passMins.add(pass);
    }
  }

  stationFlow(stats.kitchen, false);
  stationFlow(stats.bar, true);

  // ── Stations: per-person attribution from the audit stage rows ───────────
  // Only the station roles' rows belong to a station — the server forces
  // the scope (a chef cannot bump bar lines), so the actor's role IS the
  // station. Row shapes: the line route writes after:{itemId, lineStatus,
  // orderStatus}; the order route writes after:{status, station?}.
  const kitchenRoles = {'head-chef', 'assistant-chef'};
  void stationPeople(StationDay st, bool kitchen) {
    for (final r in statusRows) {
      if (r.entity != 'orders' || r.action != 'status') continue;
      final isKitchen = kitchenRoles.contains(r.actorRole.toLowerCase());
      if (isKitchen != kitchen) continue;
      final after = r.after;
      if (after is! Map) continue;
      final line = (after['lineStatus'] ?? after['status'] ?? '')
          .toString()
          .toLowerCase();
      if (line != 'preparing' && line != 'ready') continue;
      final name = r.actorName.trim().isNotEmpty ? r.actorName.trim() : 'Unassigned';
      final p = st.people.putIfAbsent(name, () => StationPersonDay(name));
      if (line == 'preparing') {
        p.bumped++;
      } else {
        p.readied++;
        final o = orderById[r.entityId];
        final make = o == null ? null : _minsBetween(o.preparingAt, o.readyAt);
        if (make != null) p._makeMins.add(make);
      }
    }
  }

  stationPeople(stats.kitchen, true);
  stationPeople(stats.bar, false);

  // ── Till: the payments ledger ─────────────────────────────────────────────
  final tillByName = <String, TillStaffDay>{};
  for (final p in payments) {
    if (teamDayKey(p.createdAt) != dayKey) continue;
    if (p.amount <= 0) continue; // refunds are not takings
    final who = (p.collectedByName ?? '').trim();
    final person = tillByName.putIfAbsent(who.isNotEmpty ? who : 'Till',
        () => TillStaffDay(who.isNotEmpty ? who : 'Till'));
    person.payments++;
    person.collected += p.amount;
    if (p.status == 'verified') {
      final m = p.method.toLowerCase();
      if (m != 'cash') person.transfersVerified++;
    }
    final method = p.method.toLowerCase();
    stats.moneyByMethod[method] = (stats.moneyByMethod[method] ?? 0) + p.amount;
    if (p.needsVerification) stats.transfersPending++;
  }
  stats.till.addAll(tillByName.values);
  stats.till.sort((a, b) => b.collected.compareTo(a.collected));

  return stats;
}
