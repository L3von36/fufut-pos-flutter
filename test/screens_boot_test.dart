// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fufut_pos/main.dart';
import 'package:fufut_pos/state/roles.dart';

/// UI/UX sweep: every screen, for every role, must BOOT and RENDER without
/// an exception or layout overflow.
///
/// The app boots with an unreachable API (mock identity), so every screen
/// exercises its chrome + error/empty states — exactly what a first-launch
/// on a dead network shows. Data states are covered by the live probe
/// (api_live_test.dart) and the contract suite (api_contract_test.dart).
///
/// A RenderFlex overflow, a provider miss, a bad fromJson on an empty
/// payload — any of it throws inside the widget tree and fails the sweep.
void main() {
  /// Settle animations without hanging on repeating indicators (live chips
  /// pulse forever by design, so pumpAndSettle times out) — then drain a
  /// fixed window so close animations always finish.
  Future<void> settle(WidgetTester tester) async {
    try {
      await tester.pumpAndSettle(
          const Duration(milliseconds: 60), EnginePhase.paint,
          const Duration(seconds: 4));
    } catch (_) {
      // Deliberate: some screens animate indefinitely.
    }
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

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
    tester.view.padding = const FakeViewPadding(
        top: 0, bottom: 0, left: 0, right: 0);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const FufutPosApp());
    await tester.pump(); // boot
    await tester.pump(const Duration(seconds: 1)); // revalidate fails
    await settle(tester);
  }

  /// Scroll the nav list (drawer on phone, sidebar on wide) until the row
  /// is built, then tap THAT row — scoped so topbar/content twins can't
  /// hijack the finder.
  Future<void> tapNavRow(WidgetTester tester, String label,
      {required bool drawer}) async {
    final navList = find.byType(ListView, skipOffstage: !drawer)
        .evaluate()
        .isNotEmpty
        ? (drawer ? find.byType(ListView).last : find.byType(ListView).first)
        : find.byType(ListView).first;
    for (var i = 0; i < 40; i++) {
      final row = find.descendant(of: navList, matching: find.text(label));
      if (row.evaluate().isNotEmpty) {
        await tester.ensureVisible(row.first);
        await settle(tester);
        await tester.tap(row.first, warnIfMissed: false);
        await settle(tester);
        return;
      }
      await tester.drag(navList, const Offset(0, -220));
      await tester.pump(const Duration(milliseconds: 60));
    }
    fail('nav row never appeared: $label');
  }

  Future<void> tapNav(WidgetTester tester, String label) async {
    await tapNavRow(tester, label, drawer: false);
  }

  final roles = kRolePermissions.keys.toList();
  for (final role in roles) {
    testWidgets('wide sweep: $role renders every granted screen',
        (tester) async {
      await boot(tester, const Size(1366, 900), role);
      print('$role: ${navForRole(role).length} destinations');

      // Land on the default view first, then walk the whole sidebar.
      for (final entry in navForRole(role)) {
        if (entry.key == NavKey.settings) continue; // settings = dialogs only
        await tapNav(tester, entry.label);
        // End of a successful tap: no exception, no overflow — the test
        // framework fails this block on either.
      }

      // Close on the HR trio's last screen: no live channel holds a timer.
      await tapNav(tester, 'My Activity');
    });
  }

  testWidgets('phone sweep: manager opens every screen via the drawer',
      (tester) async {
    await boot(tester, const Size(412, 915), 'manager');

    for (final entry in navForRole('manager')) {
      if (entry.key == NavKey.settings) continue;
      var opened = false;
      for (var attempt = 0; attempt < 4 && !opened; attempt++) {
        // Drain any in-flight drawer animation, then open the drawer.
        for (var i = 0;
            i < 10 && find.text('Sign Out').evaluate().isNotEmpty;
            i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.tap(find.byTooltip('All screens'), warnIfMissed: false);
        await settle(tester);
        opened = find.text('Sign Out').evaluate().isNotEmpty;
      }
      expect(opened, isTrue, reason: 'drawer never opened for ${entry.label}');
      await tapNavRow(tester, entry.label, drawer: true);
    }

    // The shell survived the whole catalogue on a phone factor.
    expect(find.byTooltip('All screens'), findsOneWidget);
  });
}
