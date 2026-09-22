import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Staff sign-in — the PWA's split login card.
///
/// Left 40%: teal gradient brand panel (circular logo, FU FUT wordmark,
/// "COFFEE · POS" eyebrow, tagline). Right 60%: "Welcome back" form with
/// gold-icon uppercase labels. On narrow screens it stacks, brand panel on
/// top, exactly like the web's ≤600px breakpoint.
///
/// One field takes either a staff id (e.g. `MGR-01`) or an email — the API
/// disambiguates by the `@`. The server URL sits behind a collapsed tile so
/// a deployment move is fixable from the tablet itself.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  final _server = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;
  bool _advanced = false;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _server.text = app.baseUrl;
  }

  Future<void> _submit() async {
    final app = context.read<AppState>();
    final account = _account.text.trim();
    final password = _password.text;
    if (account.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter your staff id / email and password');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_server.text.trim() != app.baseUrl) {
        await app.setBaseUrl(_server.text);
      }
      await app.login(account, password);
      // Router picks the change up via listener in RootGate.
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Sign-in failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final stacked = width < 640; // the PWA's ≤600px breakpoint

    final card = Container(
      constraints: const BoxConstraints(maxWidth: 800, minHeight: 440),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              color: const Color(0xFF073735).withValues(alpha: 0.12),
              blurRadius: 40,
              offset: const Offset(0, 16)),
          BoxShadow(
              color: const Color(0xFF073735).withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 6)),
        ],
      ),
      child: stacked
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _brandPanel(compact: true),
                _formPanel(),
              ],
            )
          : IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 320, child: _brandPanel()),
                  Expanded(child: _formPanel()),
                ],
              ),
            ),
    );

    return Scaffold(
      body: Container(
        // The web page: linear-gradient(135deg, teal-50, teal-100).
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: Theme.of(context).brightness == Brightness.dark
                ? [pal.tintBg, pal.bg]
                : const [Color(0xFFEDF8F8), Color(0xFFD2EFEF)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: card,
            ),
          ),
        ),
      ),
    );
  }

  // ── Brand panel ─────────────────────────────────────────────────────────────

  Widget _brandPanel({bool compact = false}) {
    // Same white-badge mark the launcher icon and splash use — the dark
    // disc version read heavy next to the new splash's floating badge.
    final logo = Container(
      width: compact ? 54 : 70,
      height: compact ? 54 : 70,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
              color: Color(0x40000000), blurRadius: 22, offset: Offset(0, 9)),
        ],
      ),
      child: Image.asset('assets/branding/splash_badge.png'),
    );

    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: 28, vertical: compact ? 20 : 32),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0C5F5B), Color(0xFF0A4A47)], // teal-700 → teal-800
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          logo,
          SizedBox(height: compact ? 10 : 16),
          Text('FU FUT',
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: compact ? 15 : 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: 0.8)),
          const SizedBox(height: 5),
          Text('COFFEE · POS',
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.7),
                  letterSpacing: 2.4)),
          if (!compact) ...[
            const SizedBox(height: 16),
            Container(width: 36, height: 2, color: Colors.white.withValues(alpha: 0.25)),
            const SizedBox(height: 16),
            Text('Authentic Ethiopian Coffee\n& Restaurant Management',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 11.5,
                    height: 1.5,
                    color: Colors.white.withValues(alpha: 0.6))),
          ],
        ],
      ),
    );
  }

  // ── Form panel ──────────────────────────────────────────────────────────────

  Widget _formPanel() {
    final pal = Pal.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 26, 24, 20),
      child: Material(
        type: MaterialType.transparency,
        child: Form(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Welcome back',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: pal.heading)),
            const SizedBox(height: 3),
            Text('Sign in to your account',
                style:
                    TextStyle(fontFamily: kFontBody, fontSize: 12, color: pal.muted)),
            const SizedBox(height: 20),
            const _FieldLabel(icon: Icons.person_outline, text: 'Staff ID or Email'),
            const SizedBox(height: 5),
            TextField(
              controller: _account,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                  hintText: 'you@fufut.coffee', prefixIcon: null),
            ),
            const SizedBox(height: 12),
            const _FieldLabel(icon: Icons.lock_outline, text: 'Password'),
            const SizedBox(height: 5),
            TextField(
              controller: _password,
              obscureText: _obscure,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: 'Enter your password',
                suffixIcon: IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 17),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.error_outline, size: 15, color: pal.danger),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(_error!,
                        style: TextStyle(
                            fontFamily: kFontBody, fontSize: 11.5, color: pal.danger)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            SizedBox(
              height: 42,
              child: FilledButton.icon(
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: pal.primary,
                  disabledBackgroundColor: pal.primary.withValues(alpha: 0.7),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                icon: _busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.arrow_forward, size: 15),
                label: Text(
                    _busy ? 'Signing in...' : 'Sign In',
                    style: const TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 12),
            // The web form ends with the powered-by line under the button.
            Text('Powered by FU FUT COFFEE',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 10.5,
                    letterSpacing: 0.5,
                    color: pal.muted)),
            const SizedBox(height: 6),
            // Server override, out of the way but always reachable.
            ExpansionTile(
              initiallyExpanded: _advanced,
              onExpansionChanged: (v) => setState(() => _advanced = v),
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              iconColor: pal.muted,
              collapsedIconColor: pal.muted,
              title: Text('Server',
                  style: TextStyle(
                      fontFamily: kFontBody, fontSize: 12, color: pal.muted)),
              children: [
                TextField(
                  controller: _server,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                      hintText: 'https://fufut-api...workers.dev'),
                ),
                const SizedBox(height: 8),
              ],
            ),
            const SizedBox(height: 6),
            Text('Sessions last 30 days. Sign out from the sidebar when you '
                'leave the floor.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 10.5, color: pal.faint)),
          ],
        ),
        ),
      ),
    );
  }
}

/// The web's field label: tiny uppercase, weight 600, with a small gold icon.
class _FieldLabel extends StatelessWidget {
  final IconData icon;
  final String text;
  const _FieldLabel({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Row(
      children: [
        Icon(icon, size: 13, color: pal.gold),
        const SizedBox(width: 5),
        Text(text.toUpperCase(),
            style: TextStyle(
                fontFamily: kFontBody,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: pal.muted)),
      ],
    );
  }
}
