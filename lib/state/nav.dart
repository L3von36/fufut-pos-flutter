/// Which shell tab is on stage — the global nav state.
///
/// The shell used to broadcast this as a raw `ValueNotifier<NavKey>`
/// constructor-injected into every keep-alive screen (five screens listened
/// to gate their SSE channels and refresh on return), and the shell wrote
/// `activeTab.value = _tab` during every build — a side effect in the
/// middle of the build phase. A provider makes the same state watchable,
/// listenable, and writable only through its notifier.
///
/// Ownership: the shell *decides* the tab (role defaults, permission
/// guards) and writes through [ActiveTabNotifier]; keep-alive screens
/// `ref.watch(activeTabProvider) == widget.self` to know they are on
/// stage, and `ref.listen` to refresh when they become visible again.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'roles.dart';

class ActiveTabNotifier extends Notifier<NavKey> {
  @override
  NavKey build() => NavKey.dashboard;

  /// Navigate. Same-value writes no-op (Riverpod skips identical state),
  /// so a drawer tap on the current tab never rebuilds anything.
  void go(NavKey key) => state = key;
}

final activeTabProvider =
    NotifierProvider<ActiveTabNotifier, NavKey>(ActiveTabNotifier.new);
