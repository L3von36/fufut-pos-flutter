// Smoke test against the production fufut-api Worker.
//
// Proves the four things a native client must get right before any UI is
// trusted: the browser-shaped UA clears Cloudflare Bot Fight Mode, public
// reads work, wrong credentials get the API's real JSON refusal (not an
// edge block), and session-gated reads answer 401 without a cookie.
//
// Run: dart run tool/api_smoke.dart [base_url]
import 'package:fufut_pos/api/api_client.dart';
import 'package:fufut_pos/api/fufut_api.dart';

Future<void> main(List<String> args) async {
  final base = args.isNotEmpty
      ? args[0]
      : 'https://fufut-api.fufutcoffee.workers.dev';
  final client = ApiClient(baseUrl: base);
  final api = FufutApi(client);
  var failures = 0;

  void check(String name, bool ok, [String detail = '']) {
    print('${ok ? "PASS" : "FAIL"}  $name${detail.isEmpty ? "" : " — $detail"}');
    if (!ok) failures++;
  }

  // 1. Health endpoint reachable (UA not 1010'd).
  try {
    await client.get('health');
    check('GET /api/health (browser UA clears Bot Fight Mode)', true);
  } on ApiError catch (e) {
    check('GET /api/health', false, '$e');
  }

  // 2. Public menu read.
  try {
    final menu = await api.menu();
    check('GET /api/menu returns items', menu.isNotEmpty,
        '${menu.length} items, e.g. ${menu.first.name}');
  } on ApiError catch (e) {
    check('GET /api/menu', false, '$e');
  }

  // 3. Wrong credentials → the API's own 401 refusal.
  try {
    await client
        .post('auth/login', {'email': 'nobody@fufut.coffee', 'password': 'x'});
    check('POST /api/auth/login wrong creds rejected', false, 'accepted?!');
  } on ApiError catch (e) {
    check('POST /api/auth/login wrong creds rejected',
        e.status == 401 || e.status == 404, '${e.status} ${e.message}');
  }

  // 4. Session-gated read without a session.
  try {
    await client.get('orders');
    check('GET /api/orders without session refused', false,
        '200 without auth?!');
  } on ApiError catch (e) {
    check('GET /api/orders without session refused', e.status == 401,
        '${e.status}');
  }

  print(failures == 0
      ? 'ALL SMOKE CHECKS PASSED'
      : '$failures SMOKE CHECKS FAILED');
}
