import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// The one screen an account carrying a manager-issued password may visit.
///
/// The web guard puts it plainly (router/guard.js): "An account carrying a
/// manager-issued password can go exactly one place. The server enforces this
/// too — it refuses every other endpoint — so this guard exists to explain
/// rather than to protect." RootGate routes here while `mustChangePassword`
/// holds; the shell releases the account the moment the server accepts the
/// replacement.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _problem;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String? get _validationProblem {
    if (_current.text.isEmpty) return 'Enter the temporary password.';
    if (_next.text.length < 6) return 'The new password needs 6+ characters.';
    if (_next.text != _confirm.text) return 'The two new passwords differ.';
    if (_next.text == _current.text) {
      return 'Pick a password you have not used here.';
    }
    return null;
  }

  Future<void> _submit() async {
    final problem = _validationProblem;
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.changePassword(_current.text.trim(), _next.text);
      // The flag cleared — RootGate moves into the shell on its own.
      showInfoOn(messenger, 'Password updated — welcome aboard');
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _problem = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _problem = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.lock_reset_rounded,
                      size: 30, color: pal.primary),
                  const SizedBox(height: 10),
                  Text(
                    'Set your own password',
                    textAlign: TextAlign.center,
                    style: T.screenTitle.copyWith(color: pal.heading),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'A manager issued this account a temporary password. '
                    'The server refuses everything else until you replace '
                    'it — pick a new one and the app opens up.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 12.5,
                        height: 1.45,
                        color: pal.body),
                  ),
                  const SizedBox(height: 18),
                  _field(_current, 'Temporary password', pal,
                      autofill: AutofillHints.password),
                  const SizedBox(height: 8),
                  _field(_next, 'New password', pal,
                      autofill: AutofillHints.newPassword),
                  const SizedBox(height: 8),
                  _field(_confirm, 'Repeat new password', pal,
                      autofill: AutofillHints.newPassword,
                      onSubmitted: _submit),
                  if (_problem != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: pal.danger.withValues(alpha: 0.09),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: pal.danger.withValues(alpha: 0.35)),
                      ),
                      child: Row(children: [
                        Icon(Icons.error_outline,
                            size: 14, color: pal.danger),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(_problem!,
                              style: TextStyle(
                                  fontFamily: kFontBody,
                                  fontSize: 12,
                                  color: pal.danger)),
                        ),
                      ]),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(42)),
                    icon: _busy
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.check_rounded, size: 17),
                    label: Text(_busy ? 'Saving…' : 'Save password'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    Pal pal, {
    String? autofill,
    VoidCallback? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      obscureText: _obscure,
      autofillHints: autofill == null ? null : [autofill],
      onSubmitted: (_) => onSubmitted?.call(),
      onChanged: (_) {
        if (_problem != null) setState(() => _problem = null);
      },
      style: TextStyle(fontFamily: kFontBody, fontSize: 13.5, color: pal.body),
      decoration: InputDecoration(
        labelText: label,
        labelStyle:
            TextStyle(fontFamily: kFontBody, fontSize: 12, color: pal.muted),
        filled: true,
        fillColor: pal.sunken,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: BorderSide(color: pal.border)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(9),
            borderSide: BorderSide(color: pal.border)),
        suffixIcon: IconButton(
          onPressed: () => setState(() => _obscure = !_obscure),
          icon: Icon(
              _obscure
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 17,
              color: pal.muted),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}
