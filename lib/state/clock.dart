/// Shared wall clocks.
///
/// Screens used to own their own tick: the kitchen board and the pipeline
/// each ran a 1-second `Timer.periodic` that fired a bare `setState` every
/// second (repainting the whole board to move a few elapsed labels), the
/// floor re-tinted table tiles off its own 10s tick, and the topbar kept a
/// 60s date clock. One clock each granularity, watched only while a
/// consumer exists (autoDispose stops the stream the moment the last
/// watcher leaves), replaces all of them.
///
///   * [wallClockProvider]  — every second; elapsed timers on the boards.
///   * [minuteClockProvider]— fires only when the minute turns; occupancy
///     buckets, the topbar date, and any "refresh every minute" poll that
///     a back-office screen used to run with `Timer.periodic`.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A `DateTime.now()` snapshot [every] interval, with the first sample
/// emitted immediately — a screen never spends its first second in a
/// loading state just to learn what time it is.
Stream<DateTime> _ticks(Duration every) async* {
  yield DateTime.now();
  await for (final _ in Stream<void>.periodic(every)) {
    yield DateTime.now();
  }
}

/// Every second, starting now. Consumers that only need coarse time
/// (occupancy colours, dates) should watch [minuteClockProvider] instead —
/// watching this repaints once per second.
final wallClockProvider = StreamProvider<DateTime>((ref) {
  return _ticks(const Duration(seconds: 1));
});

/// One emission per minute — the second-sample truncated to the minute and
/// deduplicated, so a watcher rebuilds only when the displayed minute can
/// actually change. Feeds the topbar date, the floor's occupancy re-tint,
/// and minute-granularity refresh loops.
final minuteClockProvider = StreamProvider<DateTime>((ref) {
  return _ticks(const Duration(seconds: 1))
      .map((d) => DateTime(d.year, d.month, d.day, d.hour, d.minute))
      .distinct();
});
