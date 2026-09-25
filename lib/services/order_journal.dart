/// The order journal — a per-device timestamped log of every pipeline event
/// the app performs or witnesses.
///
/// The fufut-api `orders` table carries only `created` / `updated_at`; there
/// is no server-side preparing_at / ready_at / picked_up_at. The Order Log
/// screens therefore need the *devices* to record what happens and when:
///
///   * the till records `created` the moment Send to Kitchen / Charge Now
///     returns an id;
///   * the kitchen & barista boards record `preparing` / `ready` — their own
///     taps exactly, and SSE-witnessed transitions within one poll interval;
///   * the floor records `pickedUp` / `served` (the two new waiter actions),
///     `billRequested` (feed diff), `paid` (settlement) and `tableCleared`.
///
/// Every entry lives on the device that saw it (shared_preferences, 7-day
/// TTL, hard cap). A stage observed through a feed/SSE diff rather than a
/// local action is stamped `approximate` — honest about the ≤ poll-interval
/// slack. The Order Log screen merges the journal with today's orders and
/// the floor's table rows to build the per-order timeline.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// One pipeline stage. Stored as a short string key in the journal.
enum OrderStage {
  created('created', 'Order taken'),
  preparing('preparing', 'Prep started'),
  ready('ready', 'Ready at the pass'),
  pickedUp('pickedUp', 'Picked up by waiter'),
  served('served', 'Served to guests'),
  billRequested('billRequested', 'Bill asked for'),
  paid('paid', 'Bill settled'),
  tableCleared('tableCleared', 'Table cleared');

  final String key;
  final String label;
  const OrderStage(this.key, this.label);

  static OrderStage? tryOf(String key) {
    for (final s in OrderStage.values) {
      if (s.key == key) return s;
    }
    return null;
  }
}

/// One journal entry: what happened to which order, when, by whom.
class OrderEvent {
  final String orderId;
  final OrderStage stage;
  final DateTime at;

  /// Display name of the staff member whose action produced this event, when
  /// known (the signed-in user on the recording device).
  final String? by;

  /// Approximate flag: the event was *observed* (SSE snapshot diff, poll
  /// diff) rather than performed here, so the timestamp carries up to one
  /// refresh-interval of slack.
  final bool approximate;

  /// Free context: table number, payment method, party size…
  final String? note;

  const OrderEvent({
    required this.orderId,
    required this.stage,
    required this.at,
    this.by,
    this.approximate = false,
    this.note,
  });

  Map<String, dynamic> toJson() => {
        'orderId': orderId,
        'stage': stage.key,
        'at': at.millisecondsSinceEpoch,
        if (by != null) 'by': by,
        if (approximate) 'approx': 1,
        if (note != null) 'note': note,
      };

  factory OrderEvent.fromJson(Map<String, dynamic> j) => OrderEvent(
        orderId: (j['orderId'] ?? '') as String,
        stage: OrderStage.tryOf('${j['stage']}') ?? OrderStage.created,
        at: DateTime.fromMillisecondsSinceEpoch(
            _asInt(j['at']) ?? DateTime.now().millisecondsSinceEpoch),
        by: j['by'] as String?,
        approximate: j['approx'] == 1,
        note: j['note'] as String?,
      );

  static int? _asInt(dynamic v) => v is int ? v : int.tryParse('$v');
}

/// The singleton journal. All recording goes through [record]; reads are
/// synchronous over the in-memory copy (loaded once at boot).
///
/// [revision] is the change bell: every successful [record] bumps it, and
/// the Order Log listens so a stage stamped anywhere in the app (a pickup on
/// the kitchen board, a settle at the till) repaints the timeline the moment
/// it lands — the log is a live view, not a page you reload.
class OrderJournal {
  OrderJournal._();
  static final OrderJournal instance = OrderJournal._();

  /// Bumped on every recorded event — listeners rebuild their timelines.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static const _kKey = 'fufut.pos.orderJournal.v1';
  static const _kTtl = Duration(days: 7);
  static const _kMaxEvents = 4000;

  final Map<String, List<OrderEvent>> _byOrder = {};
  bool _loaded = false;
  bool _loadFailed = false;

  /// Visible to tests.
  @visibleForTesting
  void debugReset() {
    _byOrder.clear();
    _loaded = false;
    _loadFailed = false;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true; // one attempt only — a poisoned store must not loop
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw == null || raw.isEmpty) return;
      final rows = (jsonDecode(raw) as List?) ?? const [];
      final cutoff = DateTime.now().subtract(_kTtl);
      for (final row in rows.whereType<Map>()) {
        try {
          final e = OrderEvent.fromJson(Map<String, dynamic>.from(row));
          if (e.at.isBefore(cutoff)) continue;
          _byOrder.putIfAbsent(e.orderId, () => []).add(e);
        } catch (_) {/* one bad row never sinks the log */}
      }
      for (final list in _byOrder.values) {
        list.sort((a, b) => a.at.compareTo(b.at));
      }
    } catch (_) {
      _loadFailed = true;
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cutoff = DateTime.now().subtract(_kTtl);
      final rows = <Map<String, dynamic>>[];
      final orderIds = _byOrder.keys.toList()..sort();
      for (final id in orderIds) {
        for (final e in _byOrder[id]!) {
          if (e.at.isBefore(cutoff)) continue;
          rows.add(e.toJson());
        }
      }
      // Hard cap, newest first — a runaway device must not fill its disk.
      if (rows.length > _kMaxEvents) {
        rows.removeRange(0, rows.length - _kMaxEvents);
      }
      await prefs.setString(_kKey, jsonEncode(rows));
    } catch (_) {
      // Quota/private-mode: the log degrades to in-memory, never throws.
    }
  }

  /// Record that [stage] happened to [orderId]. Fire-and-forget safe.
  Future<void> record(
    String orderId,
    OrderStage stage, {
    String? by,
    bool approximate = false,
    String? note,
    DateTime? at,
  }) async {
    if (orderId.isEmpty) return;
    await _ensureLoaded();
    if (_loadFailed) return;
    final event = OrderEvent(
      orderId: orderId,
      stage: stage,
      at: at ?? DateTime.now(),
      by: by,
      approximate: approximate,
      note: note,
    );
    final list = _byOrder.putIfAbsent(orderId, () => []);
    // Idempotence guard: the same stage within 2s (double tap, both the
    // actor's record and the SSE echo) collapses into one entry.
    for (final existing in list) {
      if (existing.stage == stage &&
          event.at.difference(existing.at).inSeconds.abs() < 2) {
        return;
      }
    }
    list.add(event);
    list.sort((a, b) => a.at.compareTo(b.at));
    revision.value++; // the log screen's bell — repaint the timelines
    await _persist();
  }

  /// All events for one order, chronological.
  Future<List<OrderEvent>> eventsFor(String orderId) async {
    await _ensureLoaded();
    return List<OrderEvent>.unmodifiable(_byOrder[orderId] ?? const []);
  }

  /// Synchronous view once loaded — the log screen loads once per build.
  List<OrderEvent> eventsForSync(String orderId) =>
      List<OrderEvent>.unmodifiable(_byOrder[orderId] ?? const []);

  /// The latest recorded time of [stage] on [orderId], or null.
  DateTime? latestStageAtSync(String orderId, OrderStage stage) {
    DateTime? best;
    for (final e in _byOrder[orderId] ?? const <OrderEvent>[]) {
      if (e.stage == stage && (best == null || e.at.isAfter(best))) best = e.at;
    }
    return best;
  }

  /// Whether [stage] has been recorded on [orderId].
  bool hasStageSync(String orderId, OrderStage stage) =>
      latestStageAtSync(orderId, stage) != null;

  /// Diff two order lists and return every order whose status moved — the
  /// SSE/poll observers feed the result to [record] so a device that merely
  /// watches the board still logs the kitchen's progress (stamped
  /// approximate).
  static List<(FufutOrder, OrderStage)> statusDiffs(
    List<FufutOrder> before,
    List<FufutOrder> after,
  ) {
    final prev = {for (final o in before) o.id: o};
    final out = <(FufutOrder, OrderStage)>[];
    for (final o in after) {
      final was = prev[o.id]?.status.toLowerCase();
      final now = o.status.toLowerCase();
      if (was == now) continue;
      if (was == null) {
        // A brand-new ticket the observer had not seen yet.
        out.add((o, OrderStage.created));
        continue;
      }
      const map = {
        'preparing': OrderStage.preparing,
        'ready': OrderStage.ready,
        'fulfilled': OrderStage.pickedUp,
        'served': OrderStage.served,
      };
      final stage = map[now];
      if (stage != null) out.add((o, stage));
    }
    return out;
  }
}
