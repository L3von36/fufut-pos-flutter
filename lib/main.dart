import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/change_password_screen.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'state/app_state.dart';
import 'state/cart.dart';
import 'state/theme_controller.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  initSystemChrome();
  runApp(const FufutPosApp());
}

class FufutPosApp extends StatelessWidget {
  const FufutPosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
        ChangeNotifierProvider(create: (_) => CartState()),
        ChangeNotifierProvider(create: (_) => ThemeController()..load()),
      ],
      child: Consumer<ThemeController>(
        builder: (context, theme, _) => MaterialApp(
          title: 'FU FUT POS',
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: theme.mode,
          home: const RootGate(),
        ),
      ),
    );
  }
}

/// Waits for the session cache to load, then routes to the shell or login.
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  AppState? _app;

  @override
  void initState() {
    super.initState();
    // Save the reference: context.read inside dispose() looks up a
    // deactivated widget's ancestor and throws.
    final app = context.read<AppState>();
    _app = app;
    // boot() restores the persisted session and fires the /auth/me check;
    // the gate listens once and moves when the first notify arrives.
    app.boot().then((_) {
      if (mounted) setState(() {});
    });
    app.addListener(_onAppChange);
  }

  void _onAppChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _app?.removeListener(_onAppChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (!app.booted) {
      return const Scaffold(
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }
    if (!app.isLoggedIn) return const LoginScreen();
    // An account carrying a manager-issued password can go exactly one
    // place — the server refuses every other endpoint, so the shell would
    // only fill the screen with refusals. Same rule as the web guard.
    if (app.mustChangePassword) return const ChangePasswordScreen();
    return const HomeShell();
  }
}
