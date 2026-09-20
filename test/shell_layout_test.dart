import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fufut_pos/main.dart';

/// Exercises the phone-size shell layout (narrow branch: topbar + bottom
/// nav + menu grid in overlay mode). A layout exception at this width fails
/// the test — the headless-browser blank frame we saw is inconclusive, this
/// is not.
void main() {
  testWidgets('phone layout: shell renders the menu at 412x915',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.fufut.pos.session': 'stub-session-token',
      'flutter.fufut.pos.identity':
          '{"id":"U-MOCK","name":"Amanuel Fekadu","first_name":"Amanuel",'
          '"last_name":"Fekadu","email":"amanuel@fufut.coffee","role":"Cashier"}',
      'flutter.fufut.pos.baseUrl': 'http://127.0.0.1:1', // unreachable → offline banner
    });
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const FufutPosApp());
    await tester.pump(); // boot
    await tester.pump(const Duration(seconds: 1)); // revalidate fails → offline
    await tester.pumpAndSettle();

    // The shell chrome is present (phone: topbar + bottom nav, no sidebar).
    expect(find.text('Menu View'), findsWidgets);
    expect(find.text('Orders'), findsWidgets);
    expect(find.text('Open Checks'), findsWidgets);
    expect(find.text('More'), findsWidgets);
    // Menu column: category chips row and search hint survive the offline path.
    expect(find.text('Search menu items...'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
  });

  testWidgets('wide layout: sidebar shell renders at 1366x800',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.fufut.pos.session': 'stub-session-token',
      'flutter.fufut.pos.identity':
          '{"id":"U-MOCK","name":"Amanuel Fekadu","first_name":"Amanuel",'
          '"last_name":"Fekadu","email":"amanuel@fufut.coffee","role":"Cashier"}',
      'flutter.fufut.pos.baseUrl': 'http://127.0.0.1:1',
    });
    tester.view.physicalSize = const Size(1366, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const FufutPosApp());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    // Sidebar brand + section headers + sign out.
    expect(find.text('FU FUT'), findsWidgets);
    expect(find.text('SALES'), findsOneWidget);
    expect(find.text('SYSTEM'), findsOneWidget);
    expect(find.text('Sign Out'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
  });

  testWidgets('phone drawer: opens, shows brand + theme row, switches tab',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.fufut.pos.session': 'stub-session-token',
      'flutter.fufut.pos.identity':
          '{"id":"U-MOCK","name":"Amanuel Fekadu","first_name":"Amanuel",'
          '"last_name":"Fekadu","email":"amanuel@fufut.coffee","role":"Cashier"}',
      'flutter.fufut.pos.baseUrl': 'http://127.0.0.1:1',
    });
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const FufutPosApp());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    // Open the drawer via the app-bar hamburger.
    await tester.tap(find.byTooltip('All screens'));
    await tester.pumpAndSettle();

    // Drawer contents: user card, theme toggle, sign out.
    expect(find.text('Amanuel • Cashier'), findsOneWidget);
    expect(find.text('Dark theme'), findsOneWidget);
    expect(find.text('Sign Out'), findsOneWidget);

    // Jump to Settings from the drawer; the title switches and the
    // drawer closes.
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Amanuel • Cashier'), findsNothing);
  });
}
