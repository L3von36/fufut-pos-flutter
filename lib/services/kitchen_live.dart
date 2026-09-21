/// Kitchen board snapshot-diff engine — the web `KitchenView.vue`
/// `connectSSE()` logic, extracted so it unit-tests without a widget.
///
/// The fufut-api SSE channel is a **snapshot, not a diff**: every
/// `new_order` / `order_update` event carries the full current orders list
/// (the same `SELECT … WHERE status NOT IN (closed)` the GET endpoint
/// serves). Transitions are therefore detected client-side:
///
///  * The FIRST snapshot after connecting is the baseline — the board's
///    initial view of the world, not a transition into it. Without this,
///    opening the kitchen screen would announce every standing ticket as
///    "new" (the web shipped exactly that bug once).
///  * `new_order` after the baseline: the first order id the board has
///    never seen is the genuinely-new ticket → ding + toast.
///  * `order_update`: the first order that is `ready` now and was not
///    ready before is the ready transition → chime + toast. The event
///    payload never carries a status field — checking it was always
///    `undefined` on the web, which is why the ready chime there keys off
///    the before/after sets.
///
/// The engine persists across SSE reconnects (like the web's closure
/// state): a reconnect re-sends the whole board, every id is already
/// known, and only tickets created while the stream was down actually
/// fire. [reset] exists for explicit re-baselining (logout, account
/// switch) — the board never needs it mid-shift.
library;

import '../models/models.dart';

class KitchenLive {
  bool _baselineSeen = false;
  Set<String> _knownIds = {};

  bool get baselineSeen => _baselineSeen;
  Set<String> get knownIds => Set<String>.unmodifiable(_knownIds);

  /// Apply a `new_order` snapshot. Returns the id of the genuinely-new
  /// ticket (to ding), or null (baseline / nothing new).
  String? applyNewOrderSnapshot(List<FufutOrder> fresh) {
    final prev = _knownIds;
    _knownIds = fresh.map((o) => o.id).toSet();

    if (!_baselineSeen) {
      _baselineSeen = true;
      return null;
    }
    // Web parity: any unseen id counts, whatever its status — a ticket that
    // arrived and was bumped to preparing inside one poll window still
    // deserves its entrance ding.
    for (final o in fresh) {
      if (!prev.contains(o.id)) return o.id;
    }
    return null;
  }

  /// `order_update` transition detector: given the board state BEFORE the
  /// snapshot and the fresh list, the first order that entered `ready`.
  static String? newlyReadyIn(
      Iterable<FufutOrder> prev, List<FufutOrder> fresh) {
    final wasReady = prev
        .where((o) => o.status.toLowerCase() == 'ready')
        .map((o) => o.id)
        .toSet();
    for (final o in fresh) {
      if (o.status.toLowerCase() == 'ready' && !wasReady.contains(o.id)) {
        return o.id;
      }
    }
    return null;
  }

  /// Forget everything — the next snapshot becomes a baseline again.
  void reset() {
    _baselineSeen = false;
    _knownIds = {};
  }
}
