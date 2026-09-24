/// Session-flavoured derived providers — the read model over [AppState].
///
/// AppState is one long-lived mutable object (the migration kept it that
/// way on purpose: the whole app calls `app.login(...)`,
/// `app.refreshTill()` the same way it did under package:provider, and the
/// test suite seeds it by field assignment). Watching the whole
/// [appStateProvider] therefore repaints on *every* mutation — a till
/// refresh, a category adoption, a session revalidation — even when the
/// only thing a screen cares about is the role.
///
/// These providers give screens narrow, value-equal handles: a
/// `Provider<String>` only notifies when the role string itself changes,
/// so `ref.watch(roleProvider)` in a build-path getter is cheap and
/// precise. Reaching the API through [fufutApiProvider] also means a
/// screen never needs `ref.read(appStateProvider).api` — the
/// service-locator shape the migration left behind in ~150 call sites.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/fufut_api.dart';
import 'app_state.dart';

/// The one [ApiClient] — the instance [AppState] owns and re-points when
/// Settings changes the base URL mid-shift.
final apiClientProvider =
    Provider<ApiClient>((ref) => ref.watch(appStateProvider).client);

/// The typed endpoint surface over [apiClientProvider].
final fufutApiProvider =
    Provider<FufutApi>((ref) => ref.watch(appStateProvider).api);

/// The signed-in role key ('' when signed out) — the RBAC read model.
/// Every `_role`/`_isManager` getter that used to `ref.read` the whole
/// AppState becomes a watched value with no extra rebuilds.
final roleProvider =
    Provider<String>((ref) => ref.watch(appStateProvider).roleKey ?? '');

/// Display name of the signed-in staff member ('' when signed out).
final userNameProvider = Provider<String>((ref) {
  final u = ref.watch(appStateProvider).user;
  return u?.firstName ?? u?.displayName ?? '';
});

/// API base URL ('' on web = same origin). SSE channels and any screen
/// that renders absolute links read from here.
final baseUrlProvider =
    Provider<String>((ref) => ref.watch(appStateProvider).baseUrl);

/// The session cookie token (null on web, where the browser carries the
/// cookie). SSE channels on native attach it as a Cookie header.
final sessionTokenProvider = Provider<String?>(
    (ref) => ref.watch(appStateProvider).client.sessionToken);
