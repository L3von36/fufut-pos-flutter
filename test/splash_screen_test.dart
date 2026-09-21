import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fufut_pos/screens/splash_screen.dart';

// Regression guard for the web boot splash: whatever renders first must
// fill the window, not shrink-wrap to its content (the shrink showed up on
// flutter web as a 150x255 splash card in the top-left corner).
void main() {
  testWidgets('SplashScreen fills the window as MaterialApp.home',
      (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: SplashScreen()));
    // Advance past the 850ms entrance timeline (pumpAndSettle would hang:
    // the splash spinner animates forever by design).
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      tester.getSize(find.byType(SplashScreen)),
      const Size(900, 700),
    );
    // The Scaffold alone filling is not enough: its body Container gets
    // LOOSE constraints and shrink-wraps to the content (a ~152x255 card in
    // the corner) unless it is forced to expand. Assert the body Stack.
    expect(
      tester.getSize(find.byType(Stack).first),
      const Size(900, 700),
    );
    // The brand copy is on screen, centered.
    expect(find.text('FU FUT'), findsOneWidget);
    expect(find.text('Restoring your session…'), findsOneWidget);
  });
}
