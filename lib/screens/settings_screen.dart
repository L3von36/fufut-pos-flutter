import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
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
    final user = app.user;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Who is signed in ──────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: const Color(0xFF0F7B78),
                    child: Text(
                      user != null && user.displayName.isNotEmpty
                          ? user.displayName[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user?.displayName ?? 'Signed out',
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(
                          user != null
                              ? '${user.role}${app.offlineIdentity ? ' · unverified (offline)' : ''}'
                              : '',
                          style: const TextStyle(
                              fontSize: 13, color: Colors.white54),
                        ),
                        if (user?.email != null &&
                            user!.email!.isNotEmpty)
                          Text(user.email!,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.white38)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Server ────────────────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('API server',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  const Text(
                    'The fufut-api Worker every request goes through.',
                    style: TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                  const SizedBox(height: 10),
                  if (_editingServer) ...[
                    TextField(
                      controller: _server,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.dns_outlined)),
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
                            style: const TextStyle(
                                fontSize: 13, color: Color(0xFF7FD1CE)),
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              setState(() => _editingServer = true),
                          child: const Text('Change'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── About ─────────────────────────────────────────────────────────
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Fufut POS',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  SizedBox(height: 4),
                  Text(
                    'Android & desktop point of sale for Fufut Coffee. '
                    'Sessions last 30 days or until the server says otherwise. '
                    'Works against the same API as the web till — the menu, '
                    'the floor plan and every ticket are shared.',
                    style: TextStyle(fontSize: 13, color: Colors.white54),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // ── Sign out ──────────────────────────────────────────────────────
          if (app.isLoggedIn)
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFF8A80),
                side: const BorderSide(color: Color(0xFF5A3A38)),
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
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
            ),
        ],
      ),
    );
  }
}
