import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Staff sign-in.
///
/// One field takes either a staff id (e.g. `MGR-01`) or an email — the API
/// disambiguates by the `@`. The server URL sits behind a collapsed
/// "Advanced" tile so a deployment move is fixable from the tablet itself.
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
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),
                  Container(
                    width: 72,
                    height: 72,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: kBrandTeal,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Icon(Icons.local_cafe,
                        size: 36, color: Colors.white),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Fufut Coffee',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 26, fontWeight: FontWeight.w700),
                  ),
                  const Text(
                    'Point of Sale',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 15, color: Colors.white54),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _account,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      hintText: 'Staff ID or email',
                      prefixIcon: Icon(Icons.badge_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: _obscure,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      hintText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(_obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined),
                        onPressed: () =>
                            setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                            color: Color(0xFFFF8A80), fontSize: 13),
                      ),
                    ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Sign in'),
                  ),
                  const SizedBox(height: 12),
                  ExpansionTile(
                    initiallyExpanded: _advanced,
                    onExpansionChanged: (v) => setState(() => _advanced = v),
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    title: const Text('Server',
                        style: TextStyle(fontSize: 13, color: Colors.white54)),
                    children: [
                      TextField(
                        controller: _server,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          hintText: 'https://fufut-api...workers.dev',
                          prefixIcon: Icon(Icons.dns_outlined),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Sessions last 30 days. Sign out from Settings when you '
                    'leave the floor.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
