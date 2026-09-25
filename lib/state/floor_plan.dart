/// Floor-plan helpers — ports of the web POS's `lib/tableUrgency.js`,
/// `lib/openChecks.js`, `lib/sections.js` and the small table utilities
/// inside `TablesView.vue`.
///
/// Pure functions only: every rule here is display-side. The server remains
/// the authority for what actually blocks a table, closes a check or frees a
/// seat — these helpers exist so the native floor plan can *explain* the same
/// story the web tells, word for word.
library;

import '../models/models.dart';
import 'app_time.dart' show fmtClock, parseStamp;

/// The venue's rule: a sitting lasts at most four hours. The server enforces
/// it (its staleness sweep releases held tables); this constant only colors
/// the tile and picks the wording.
const int maxTableHours = 4;

/// Seating-lead, display only — the server decides what blocks.
const int leadMinutes = 60;

/// Mirrors the worker's GRACE_MIN. Display only.
const int graceMinutes = 15;

/// The floor's zones shipped before the manager edits them; the server's list
/// (`GET /api/tables/sections`) replaces these the moment it arrives.
const List<String> defaultSections = [
  'Patio',
  'Main Hall',
  'Window',
  'VIP Room',
  'Bar',
];

/// Bucket a table's seated time so the card can colour it.
///
/// 'fresh'   — under 45 minutes, an ordinary sitting
/// 'warm'    — under 90, ready to pay or has been forgotten
/// 'late'    — past 90 minutes, somebody should look at it
/// 'overdue' — past the maximum; the sweep releases the table within the minute
/// 'none'    — no readable seated_at (the server stamps those itself)
String occupancyUrgency(CafeTable table, {DateTime? now}) {
  final raw = table.seatedAt;
  if (raw == null || raw.trim().isEmpty) return 'none';
  final seated = DateTime.tryParse(raw.trim())?.toUtc();
  if (seated == null) return 'none';
  final mins = ((now ?? DateTime.now()).toUtc().difference(seated).inSeconds) /
      60.0;
  if (mins < 0) return 'none';
  if (mins >= maxTableHours * 60) return 'overdue';
  if (mins < 45) return 'fresh';
  if (mins < 90) return 'warm';
  return 'late';
}

/// "{h}h {m}m" / "{m}m" / "just now" — how long the party has been sitting.
String occupancyTimer(String? seatedAt, {DateTime? now}) {
  if (seatedAt == null || seatedAt.trim().isEmpty) return '';
  final seated = DateTime.tryParse(seatedAt.trim())?.toUtc();
  if (seated == null) return '';
  final diff = (now ?? DateTime.now()).toUtc().difference(seated).inSeconds;
  if (diff < 0) return 'just now';
  final h = diff ~/ 3600;
  final m = (diff % 3600) ~/ 60;
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m';
  return 'just now';
}

/// Can this order still take lines and be settled — i.e. is it an open check?
///
/// A check is open until it is paid. Only cancellation, completion or actual
/// payment close it — which is exactly the API's own definition in
/// listOpenChecks. 'fulfilled'/'served' with money still owed counts: that is
/// the normal state of a table between the kitchen finishing and the bill
/// being settled, and excluding it was the leak that silently opened second
/// tickets on the web.
bool isResumableCheck(FufutOrder? order) {
  if (order == null) return false;
  final status = order.status.toLowerCase();
  if (status == 'cancelled' || status == 'completed') return false;
  return (order.paymentStatus ?? '').toLowerCase() != 'paid';
}

/// Does this check belong to the table's CURRENT seating — the party
/// sitting now?
///
/// The owner's rule (2026-09-25): the table's Active Orders are the NEW
/// customers' orders only. When a party leaves and the table is freed, the
/// server stamps every check it leaves behind with `cleared_at` — a freed
/// party's leftover (typically served-but-unpaid money) belongs to the
/// table's history, never to the next guests' bill. The seating clock
/// (`seated_at`) is the fallback for turns that bypass the free endpoint
/// (quick-status edits): an order created before the current party sat is
/// a previous party's.
///
/// A 90-second tolerance absorbs clock skew — `seated_at` is the claiming
/// device's clock, `created` is the server's.
bool isCurrentSeatingOrder(FufutOrder? order, CafeTable? table) {
  if (order == null || table == null) return true;
  if ((order.clearedAt ?? '').isNotEmpty) return false;
  final seated = parseStamp(table.seatedAt);
  if (seated == null) return true;
  final created = parseStamp(order.created);
  if (created == null) return true;
  return !created
      .isBefore(seated.subtract(const Duration(seconds: 90)));
}

/// The open check a table's next action should attach to: the newest
/// resumable order for that table number, or null when starting fresh.
///
/// "Newest" is by created timestamp, not array position. Table ids are
/// compared as strings because they have drifted between 'T-01', 'Table 1'
/// and '1' over the life of the data.
FufutOrder? latestResumableCheck(List<FufutOrder> orders, String tableNum) {
  FufutOrder? best;
  var bestTime = -1; // ms; -1 keeps "later array position wins" for ties
  final target = tableNum;
  for (final o in orders) {
    final tn = o.tableNum ?? '';
    if (!isResumableCheck(o)) continue;
    if (!_sameTable(tn, target)) continue;
    final t = DateTime.tryParse(o.created ?? '')?.toUtc().millisecondsSinceEpoch;
    final score = t ?? -1;
    if (score >= bestTime) {
      bestTime = score;
      best = o;
    }
  }
  return best;
}

/// '1' == 'T1' == 'T-1' — the string-drift tolerance the web's comparison
/// grew after years of hand-typed table numbers.
bool _sameTable(String a, String b) {
  String norm(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');
  if (a == b) return true;
  final na = norm(a);
  final nb = norm(b);
  return na.isNotEmpty && na == nb;
}

/// Merge the server's zone list with the zones actually on tables.
///
/// Rules (the web's mergeSections, verbatim):
///   - server order wins — the manager arranged it, the pickers honour it;
///   - a zone that exists only on tables is appended, case-insensitively
///     de-duplicated, so a table can never fall out of the picker;
///   - an empty or unusable server list changes nothing.
List<String> mergeSections(List<String>? serverList, List<CafeTable> rows) {
  final fromServer = (serverList ?? const [])
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final merged = [...fromServer];
  final have = fromServer.map((s) => s.toLowerCase()).toSet();
  for (final row in rows) {
    final s = (row.section ?? '').trim();
    if (s.isNotEmpty && !have.contains(s.toLowerCase())) {
      have.add(s.toLowerCase());
      merged.add(s);
    }
  }
  return merged;
}

/// Stable hue per server name — hashing the name (h*31+c, mod 360) rather
/// than assigning from a rota survives reloads and needs no storage. Fixed
/// saturation/lightness keeps every badge legible in both themes.
int serverHue(String name) {
  var h = 0;
  for (final code in name.codeUnits) {
    h = (h * 31 + code) % 360;
  }
  return h;
}

/// "Yonas Girmay" → "YG" — first letter of the first two words, uppercased.
String serverInitials(String? name) {
  return (name ?? '')
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .take(2)
      .map((w) => w[0])
      .join()
      .toUpperCase();
}

/// "holding until 19:30" or "from 18:00" — whichever the waiter needs to
/// know. Before the sitting starts the useful fact is when the guests are
/// due; once it has started, it is when the table frees up. Stamps read
/// through app_time's [parseStamp] — the venue's wall, not a UTC hour the
/// `.toUtc()` used to leak into the label.
String holdWindowLabel(String? startAt, String? endAt, {DateTime? now}) {
  final start = parseStamp(startAt);
  final end = parseStamp(endAt);
  if (start == null || end == null) return '';
  final n = now ?? DateTime.now();
  return n.isBefore(start) ? 'from ${fmtClock(start)}' : 'until ${fmtClock(end)}';
}

/// The money state of a party's checks, word for word with the web.
String paymentLabel(String? state) {
  switch ((state ?? '').toLowerCase()) {
    case 'paid':
      return 'Paid';
    case 'partial':
      return 'Partly Paid';
    case 'unpaid':
      return 'Unpaid';
    default:
      return state ?? '';
  }
}

/// "T4" is how the system names a table; a waiter reads "Table 4".
String tableLabel(String? id) {
  if (id == null || id.isEmpty) return 'No table';
  final m = RegExp(r'^T?(\d+)$', caseSensitive: false).firstMatch(id);
  return m != null ? 'Table ${m.group(1)}' : id;
}

/// `(n).toLocaleString() + ' ETB'` — the web's formatETB, grouped digits and
/// the currency after the number.
String formatETB(num? n) {
  final v = (n ?? 0).toDouble();
  final whole = v.round();
  final s = '$whole'.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
  return '$s ETB';
}

/// "3x Latte, 1x Cake" — the pending card's one-line summary.
String summariseItems(List<OrderItemLine> lines) {
  return lines.map((l) => '${l.qty}x ${l.name}').join(', ');
}

/// How long the guest has been waiting for somebody to look — "just now" or
/// "{n} min". Guest stamps arrive as naive local strings; the web appends Z
/// before parsing, so a stamp without timezone information is read as UTC.
String waitingFor(String? created, {DateTime? now}) {
  if (created == null || created.isEmpty) return '';
  var raw = created.trim().replaceFirst(' ', 'T');
  final hasZone =
      raw.endsWith('Z') || RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(raw);
  if (!hasZone) raw = '${raw}Z';
  final c = DateTime.tryParse(raw)?.toUtc();
  if (c == null) return '';
  final mins = ((now ?? DateTime.now())
          .toUtc()
          .difference(c)
          .inMilliseconds /
      60000.0)
      .round();
  // The web only guards mins < 1 — a future stamp (clock skew) reads
  // "just now" there too, so the same shape is kept.
  return mins < 1 ? 'just now' : '$mins min';
}
