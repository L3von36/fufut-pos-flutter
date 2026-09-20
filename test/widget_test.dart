import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fufut_pos/main.dart';

void main() {
  testWidgets('boots to the login screen when no session is stored',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const FufutPosApp());
    await tester.pumpAndSettle();
    // The split login card: brand panel + form, PWA wording.
    expect(find.text('FU FUT'), findsWidgets);
    expect(find.text('COFFEE · POS'), findsOneWidget);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Sign In'), findsOneWidget);
  });
}
