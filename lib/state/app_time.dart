/// The app's one clock — every stamp is parsed, compared, and printed the
/// same way, everywhere.
///
/// Before this library each screen carried its own copy of the time code:
/// eight stamp parsers, six day-key builders, ten `HH:mm` formatters, two
/// long-date formatters (with duplicated weekday/month arrays), four
/// duration formatters. The copies had already drifted — the table cards
/// and the till rows printed the server's UTC hour while the Order Log
/// printed the venue's hour for the very same ticket, three hours apart in
/// Addis. One module, one behaviour:
///
///   * **Parse** — every server stamp goes through [parseStamp]. The API
///     emits two shapes (see its doc); both come out as a local `DateTime`,
///     so `.hour` on the result is always the venue's wall clock.
///   * **Compare** — day boundaries are local-calendar strings built by
///     [dayKey] / [todayKey] / [yesterdayKey]; durations are instant math
///     (`.difference`), which is timezone-safe by construction.
///   * **Print** — one format per shape: [fmtClock] (HH:mm, 24h),
///     [fmtDayClock] (dd/MM HH:mm), [fmtLongDate] ('Mon, Sep 25, 2026'),
///     [fmtDur] ('42m' / '1h07m'), [timeAgo] ('4m ago').
///
/// Screens and services alike import this; none of them keep a private
/// copy anymore. Pure Dart — the tests and the services use it too.
library;

// ─────────────────────────────────────────────────────────────────────────────
// Parsing — the two stamp shapes the API emits
// ─────────────────────────────────────────────────────────────────────────────

/// Parses any server stamp into a local `DateTime`.
///
/// Two shapes live in the data:
///
///   * the order rows' naive local wall-clock — `"2026-08-06 01:55:46"`
///     (a space, no zone) — read as the venue's local time, which it is;
///   * the UTC ISO stamps — `"2026-09-25T07:12:33.000Z"` (stage columns,
///     audit rows, payments, the bill legs) — converted to local, so a
///     ticket born 07:12Z reads 10:12 on the wall in Addis.
///
/// Null, empty, and unparseable strings return null — callers decide what
/// a missing leg displays ('pending', '—', the raw text).
DateTime? parseStamp(String? s) {
  if (s == null || s.isEmpty) return null;
  final d = DateTime.tryParse(s.trim().replaceFirst(' ', 'T'));
  if (d == null) return null;
  return d.isUtc ? d.toLocal() : d;
}

/// The local `yyyy-MM-dd` day key of any server stamp, or null when the
/// stamp is absent/unparseable — the same shape [dayKey] produces, so a
/// row's stamp and a screen's day window compare as plain strings.
String? stampDayKey(String? s) {
  final d = parseStamp(s);
  return d == null ? null : fmtDay(d);
}

// ─────────────────────────────────────────────────────────────────────────────
// The local calendar — where "today" begins and ends
// ─────────────────────────────────────────────────────────────────────────────

String _two(int v) => v.toString().padLeft(2, '0');

/// The `yyyy-MM-dd` key of [d] in the device's local calendar — the shape
/// the API's from/to filters and every day window speak.
String fmtDay(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// The business-day key of any server stamp — '' when the stamp is missing
/// or unparseable. Screens render '—' for ''; they never throw. (The name
/// models.dart has always exported; implemented HERE so a stamp's day is
/// read through [parseStamp] — the venue's calendar, never the raw string
/// prefix of a UTC stamp.)
String dayKey(String? stamp) => stampDayKey(stamp) ?? '';

/// Today as a `yyyy-MM-DD` key in the device's local calendar — the live
/// service day every operational screen windows against.
String todayKey([DateTime? now]) => fmtDay(now ?? DateTime.now());

/// Yesterday's key — the Order Log's second chip, the Team screen's
/// compare-day, the snapshot date's default.
String yesterdayKey([DateTime? now]) =>
    fmtDay((now ?? DateTime.now()).add(const Duration(days: -1)));

// ─────────────────────────────────────────────────────────────────────────────
// Formatting — one format per shape
// ─────────────────────────────────────────────────────────────────────────────

/// `HH:mm`, 24-hour — the app's only clock format.
String fmtClock(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

/// A stamp → `HH:mm` through [parseStamp]; [blank] when the stamp is
/// absent. Text that was never a stamp but is already clock-shaped
/// (`"08:00"` — shift rows feed bare times and full stamps through one
/// pipe) passes through untouched, and any other unparseable string is
/// handed back as-is rather than swallowed.
String fmtClockStamp(String? s, {String blank = ''}) {
  if (s == null || s.isEmpty) return blank;
  final d = parseStamp(s);
  if (d == null) {
    if (s.length >= 5 && s.contains(':')) return s.substring(0, 5);
    return s;
  }
  return fmtClock(d);
}

/// `dd/MM HH:mm` — a stamp that may not be today (history tiles).
String fmtDayClock(DateTime d) =>
    '${_two(d.day)}/${_two(d.month)} ${fmtClock(d)}';

/// A stamp → `HH:mm` when it falls today, `dd/MM HH:mm` otherwise — the
/// table-history shape. [blank] when absent, raw text when unparseable.
String fmtWhenStamp(String? s, {String blank = ''}) {
  if (s == null || s.isEmpty) return blank;
  final d = parseStamp(s);
  if (d == null) return s;
  final now = DateTime.now();
  final today = d.year == now.year && d.month == now.month && d.day == now.day;
  return today ? fmtClock(d) : fmtDayClock(d);
}

const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _mo = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// `'Mon, Sep 25, 2026'` — the topbar's and the dashboard's long date.
String fmtLongDate(DateTime d) =>
    '${_wd[d.weekday - 1]}, ${_mo[d.month - 1]} ${d.day}, ${d.year}';

/// `'just now'` / `'4m ago'` / `'3h ago'` / `'2d ago'` — the web POS's
/// coarse relative time. Empty stamps read empty; unparseable ones read
/// back themselves.
String timeAgo(String? stamp, {DateTime? now}) {
  if (stamp == null || stamp.isEmpty) return '';
  final t = parseStamp(stamp);
  if (t == null) return stamp;
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// `'42m'` / `'1h07m'` — the app's only elapsed format, the KPI cards'
/// and the timeline legs' shape.
String fmtDur(Duration d) {
  final m = d.inMinutes;
  if (m < 60) return '${m}m';
  return '${d.inHours}h${_two(m % 60)}m';
}
