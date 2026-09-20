import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fufut_pos/main.dart';

void main() {
  testWidgets('boots to the login screen when no session is stored',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const FufutPosApp());
    await tester.pumpAndSettle();
    expect(find.text('Fufut Coffee'), findsOneWidget);
    expect(find.text('Point of Sale'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });
}
