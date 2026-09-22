import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fufut_pos/main.dart';

/// SafeArea regression tests — the app runs edge-to-edge
/// (SystemUiMode.edgeToEdge in theme.dart), so every surface must clear the
/// status bar / gesture nav bar insets itself.
///
/// User report behind these tests: the drawer (and sidebar) pinned their
/// Sign Out row under the Android gesture bar. We inject fake device insets
/// via the test view and assert the bottom-most chrome clears the bottom
/// inset by a comfortable margin.
void main() {
  Future<void> boot(WidgetTester tester, Size size, String role) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.fufut.pos.session': 'stub-session-token',
      'flutter.fufut.pos.identity':
          '{"id":"U-MOCK","name":"Amanuel Fekadu","first_name":"Amanuel",'
          '"last_name":"Fekadu","email":"amanuel@fufut.coffee","role":"$role"}',
      'flutter.fufut.pos.baseUrl': 'http://127.0.0.1:1', // unreachable
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = FakeViewPadding(
        top: 40.0, bottom: 48.0, left: 0.0, right: 0.0); // gesture-bar phone
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const FufutPosApp());
    await tester.pump(); // boot
    await tester.pump(const Duration(seconds: 1)); // revalidate fails → offline
    await tester.pumpAndSettle();
  }

  testWidgets('phone drawer: Sign Out clears the bottom inset', (tester) async {
    await boot(tester, const Size(412, 915), 'Cashier');

    // Open the shell drawer and let the open animation settle.
    final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
    scaffold.openDrawer();
    await tester.pumpAndSettle();

    final signOutBottom = tester.getBottomRight(find.text('Sign Out')).dy;
    // 48px bottom inset injected — the row must sit fully above it.
    expect(signOutBottom, lessThanOrEqualTo(915 - 48),
        reason:
            'Drawer Sign Out hid behind the edge-to-edge gesture nav bar '
            '(bottom=$signOutBottom, allowed ≤ ${915 - 48})');
  });

  testWidgets('wide sidebar: Sign Out clears the bottom inset', (tester) async {
    await boot(tester, const Size(1366, 800), 'Cashier');

    final signOutBottom = tester.getBottomRight(find.text('Sign Out')).dy;
    expect(signOutBottom, lessThanOrEqualTo(800 - 48),
        reason:
            'Sidebar Sign Out hid behind the edge-to-edge gesture nav bar '
            '(bottom=$signOutBottom, allowed ≤ ${800 - 48})');
  });
}
