import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Session + server settings. Deliberately small: this is the tablet's
/// "who am I / where do I point" screen, not a management dashboard — all of
/// that stays on the web backoffice.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _server = TextEditingController();
  bool _editingServer = false;

  @override
  void initState() {
    super.initState();
    _server.text = context.read<AppState>().baseUrl;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pal = Pal.of(context);
    final user = app.user;
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        // ── Who is signed in ──────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: pal.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: pal.border, width: 1.5),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: pal.primary,
                child: Text(
                  user != null && user.displayName.isNotEmpty
                      ? user.displayName[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(user?.displayName ?? 'Signed out',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 14.0,
                            fontWeight: FontWeight.w700,
                            color: pal.heading)),
                    const SizedBox(height: 2),
                    Text(
                      user != null
                          ? '${user.role}${app.offlineIdentity ? ' · unverified (offline)' : ''}'
                          : '',
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 11.5,
                          color: pal.muted),
                    ),
                    if (user?.email != null && user!.email!.isNotEmpty)
                      Text(user.email!,
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 11.5,
                              color: pal.faint)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ── Server ────────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: pal.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: pal.border, width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('API server',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 13.0,
                      fontWeight: FontWeight.w600,
                      color: pal.heading)),
              const SizedBox(height: 4),
              Text(
                'The fufut-api Worker every request goes through.',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 11.5, color: pal.faint),
              ),
              const SizedBox(height: 10),
              if (_editingServer) ...[
                TextField(
                  controller: _server,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: () {
                        _server.text = app.baseUrl;
                        setState(() => _editingServer = false);
                      },
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () async {
                        await app.setBaseUrl(_server.text);
                        setState(() => _editingServer = false);
                        if (context.mounted) {
                          showInfo(context, 'Server saved');
                        }
                      },
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ] else
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        app.baseUrl,
                        style: T.mono.copyWith(
                            fontSize: 11.5, color: pal.primary),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() => _editingServer = true),
                      child: const Text('Change'),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ── About ─────────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: pal.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: pal.border, width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('FU FUT POS',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 13.0,
                      fontWeight: FontWeight.w600,
                      color: pal.heading)),
              const SizedBox(height: 4),
              Text(
                'Android & desktop point of sale for Fufut Coffee. '
                'Sessions last 30 days or until the server says otherwise. '
                'Works against the same API as the web till — the menu, '
                'the floor plan and every ticket are shared.',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 11.5,
                    height: 1.55,
                    color: pal.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // ── Sign out ──────────────────────────────────────────────────────
        if (app.isLoggedIn)
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: pal.danger,
              side: BorderSide(color: pal.dangerBorder),
              backgroundColor: pal.dangerBg,
              minimumSize: const Size.fromHeight(46),
            ),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Sign out?'),
                  content: const Text(
                      'The cart on this device is cleared for the next shift.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Stay')),
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Sign out')),
                  ],
                ),
              );
              if (ok == true && context.mounted) {
                await context.read<AppState>().logout();
              }
            },
            icon: const Icon(Icons.logout, size: 17),
            label: const Text('Sign out'),
          ),
      ],
    );
  }
}
