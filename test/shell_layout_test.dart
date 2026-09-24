import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fufut_pos/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Exercises the shell layouts at both breakpoints, plus the per-role
/// landing screens. A layout exception at any point fails the test — the
/// headless-browser blank frame we saw is inconclusive, this is not.
///
/// Identity is injected through the SharedPreferences cache, so the role
/// each test exercises is chosen by the `role` field of the identity JSON.
/// Base URL points at an unreachable port: under the test binding the data
/// calls never resolve, so these tests assert the CHROME — topbar, nav,
/// sidebar, drawer — which renders regardless of load state. Data states
/// are covered on-device.
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
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ProviderScope(child: FufutPosApp()));
    await tester.pump(); // boot
    await tester.pump(const Duration(seconds: 1)); // revalidate fails → offline
    await tester.pumpAndSettle();
  }

  testWidgets('phone layout: cashier shell renders at 412x915',
      (tester) async {
    await boot(tester, const Size(412, 915), 'Cashier');

    // The cashier lands on the Cash Drawer (their ROLE_DEFAULT_VIEW), and
    // the bar carries their first three destinations + More.
    expect(find.text('Cash Drawer'), findsWidgets);
    expect(find.text('Menu View'), findsWidgets);
    expect(find.text('Orders'), findsWidgets);
    expect(find.text('More'), findsOneWidget);
  });

  testWidgets('wide layout: sidebar shell renders at 1366x800',
      (tester) async {
    await boot(tester, const Size(1366, 800), 'Cashier');

    // Sidebar brand + section headers + sign out. Sections come from the
    // entries' own labels (Overview / Sales / Operations / … / System).
    expect(find.text('FU FUT'), findsWidgets);
    expect(find.text('SALES'), findsOneWidget);
    expect(find.text('Sign Out'), findsOneWidget);
    expect(find.text('Amanuel • Cashier'), findsOneWidget);
    // The full parity nav (30 destinations) scrolls — System is at the
    // bottom of the sidebar now, exactly like the web's sidebar.
    await tester.scrollUntilVisible(
      find.text('SYSTEM'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('SYSTEM'), findsOneWidget);
  });

  testWidgets('phone drawer: opens, shows brand + theme row, switches tab',
      (tester) async {
    await boot(tester, const Size(412, 915), 'Cashier');

    // Open the drawer via the app-bar hamburger.
    await tester.tap(find.byTooltip('All screens'));
    await tester.pumpAndSettle();

    // Drawer contents: user card, theme toggle, sign out.
    expect(find.text('Amanuel • Cashier'), findsOneWidget);
    expect(find.text('Dark theme'), findsOneWidget);
    expect(find.text('Sign Out'), findsOneWidget);

    // Jump to Settings from the drawer; the title switches and the
    // drawer closes. The drawer scrolls now that every role carries the
    // full parity nav.
    await tester.scrollUntilVisible(
      find.text('Settings'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Amanuel • Cashier'), findsNothing);
  });

  testWidgets('manager lands on the Dashboard, not the till',
      (tester) async {
    await boot(tester, const Size(412, 915), 'Manager');
    expect(find.text('Dashboard'), findsWidgets);
    expect(find.text('Cash Drawer'), findsNothing);
  });

  testWidgets('head chef lands on the Kitchen board', (tester) async {
    await boot(tester, const Size(412, 915), 'Head Chef');
    expect(find.text('Kitchen Display'), findsOneWidget);
  });

  testWidgets('barista lands on the Barista board with kitchen nav absent',
      (tester) async {
    await boot(tester, const Size(412, 915), 'Barista');
    expect(find.text('Barista Display'), findsOneWidget);
    // The barista's bar: their board, whole tickets, More. No Kitchen.
    expect(find.text('Kitchen Display'), findsNothing);
  });

  testWidgets('head waiter lands on the floor plan', (tester) async {
    await boot(tester, const Size(412, 915), 'Head Waiter');
    expect(find.text('Floor Plan'), findsWidgets);
  });

  testWidgets('cleaner lands on the Waste log', (tester) async {
    await boot(tester, const Size(412, 915), 'Cleaner');
    expect(find.text('Waste Log'), findsWidgets);
  });

  testWidgets('unknown role falls back to the till layout', (tester) async {
    await boot(tester, const Size(412, 915), 'Intern');
    expect(find.text('Menu View'), findsWidgets);
  });
}
