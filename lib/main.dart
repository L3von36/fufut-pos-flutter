import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/change_password_screen.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'screens/splash_screen.dart';
import 'state/app_state.dart';
import 'state/theme_controller.dart';
import 'theme.dart';

/// Minimum time the branded splash stays on screen — short enough to feel
/// like a beat, long enough that a fast session restore never strobes the
/// logo in and out. `--dart-define=FUFUT_SPLASH_HOLD=true` pins it for
/// visual QA screenshots (never set in release builds).
const _minSplash = bool.fromEnvironment('FUFUT_SPLASH_HOLD')
    ? Duration(seconds: 30)
    : Duration(milliseconds: 1100);

void main() {
  // NOTE: deliberately NOT calling FlutterNativeSplash.preserve() here. It
  // defers the first frame, and on web that wedges the engine's first-frame
  // metrics — the splash renders as a tiny card in the corner until the
  // next DOM mutation. Instead the native/HTML launch screen is released on
  // the first Flutter frame (RootGate initState post-frame callback): the
  // Flutter splash paints the identical seal-on-teal, so the handoff is
  // invisible anyway.
  WidgetsFlutterBinding.ensureInitialized();
  initSystemChrome();
  // One container above MaterialApp: every route, dialog and modal bottom
  // sheet reads the same providers (the old ChangeNotifierProvider.value
  // re-provisioning for sheets is no longer needed).
  runApp(const ProviderScope(child: FufutPosApp()));
}

class FufutPosApp extends ConsumerWidget {
  const FufutPosApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'FU FUT POS',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: themeMode,
      home: const RootGate(),
    );
  }
}

/// Waits for the session cache to load, then routes to the shell or login.
class RootGate extends ConsumerStatefulWidget {
  const RootGate({super.key});

  @override
  ConsumerState<RootGate> createState() => _RootGateState();
}

class _RootGateState extends ConsumerState<RootGate> {
  DateTime? _bootStarted;
  bool _splashDismissed = false;

  @override
  void initState() {
    super.initState();
    // boot() restores the persisted session and fires the /auth/me check;
    // build()'s ref.watch(appStateProvider) moves the gate on the first
    // notify — no manual listener bookkeeping anymore.
    _bootStarted = DateTime.now();
    ref.read(appStateProvider).boot().whenComplete(_finishSplash);
    // Release the native/HTML launch screen as soon as the first Flutter
    // frame is on screen — the splash shows the same seal on the same teal,
    // so there is no visible seam. On web this also drops the #splash DOM
    // node the engine otherwise keeps measuring against.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FlutterNativeSplash.remove();
    });
  }

  /// Lets the router move past the splash once boot is done — never before
  /// [_minSplash], so the brand beat always plays.
  Future<void> _finishSplash() async {
    final elapsed = DateTime.now().difference(_bootStarted!);
    final remaining = _minSplash - elapsed;
    if (remaining > Duration.zero) {
      await Future.delayed(remaining);
    }
    if (mounted) setState(() => _splashDismissed = true);
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appStateProvider);
    // Stage 0 — session still restoring: the branded splash (boot errors
    // surface on the login screen, same as before).
    if (!app.booted || !_splashDismissed) {
      return const SplashScreen();
    }
    // Crossfade each gate transition once: splash → login/password/shell.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 380),
      switchOutCurve: Curves.easeOut,
      switchInCurve: Curves.easeIn,
      // The default layout builder stacks children with loose constraints,
      // under which a Scaffold shrink-wraps to its content (the splash would
      // render as a tiny card in the corner). Force every stage full-bleed.
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [...previousChildren, if (currentChild != null) currentChild],
      ),
      child: KeyedSubtree(
        // An account carrying a manager-issued password can go exactly one
        // place — the server refuses every other endpoint, so the shell
        // would only fill the screen with refusals. Same rule as the web.
        key: ValueKey(app.isLoggedIn
            ? (app.mustChangePassword ? 'password' : 'shell')
            : 'login'),
        child: !app.isLoggedIn
            ? const LoginScreen()
            : app.mustChangePassword
                ? const ChangePasswordScreen()
                : const HomeShell(),
      ),
    );
  }
}
