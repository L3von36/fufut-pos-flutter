/// Waste log — the cleaner's / barista's own screen, from the web
/// `WasteView.vue`.
///
/// Today's entries at the top, the full log under it, and a compact inline
/// form to record what was thrown away: item name, quantity, reason, and an
/// optional estimated cost. A record that cannot say *why* it happened is
/// refused by the server, so the form asks for the reason up front.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

class WasteScreen extends StatefulWidget {
  const WasteScreen({super.key});

  @override
  State<WasteScreen> createState() => _WasteScreenState();
}

class _WasteScreenState extends State<WasteScreen> {
  List<WasteEntry> _entries = [];
  bool _loading = true;
  Object? _error;
  bool _formOpen = false;

  final _name = TextEditingController();
  final _qty = TextEditingController(text: '1');
  final _cost = TextEditingController();
  final _reason = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _qty.dispose();
    _cost.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final entries = await app.api.wasteLog();
      if (!mounted) return;
      setState(() { _entries = entries; _loading = false; });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) {
        await app.sessionExpired();
        return;
      }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  bool _isToday(WasteEntry w) {
    final d = w.date;
    if (d == null || d.length < 10) return false;
    final now = DateTime.now();
    String pad(int v) => v.toString().padLeft(2, '0');
    final today = '${now.year}-${pad(now.month)}-${pad(now.day)}';
    return d.substring(0, 10) == today;
  }

  Future<void> _submit() async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final name = _name.text.trim();
    final qty = double.tryParse(_qty.text.replaceAll(',', '.')) ?? 0;
    final reason = _reason.text.trim();
    final cost = double.tryParse(_cost.text.replaceAll(',', '.')) ?? 0;
    if (name.isEmpty) {
      showErrorOn(messenger, ApiError('What was thrown away?'));
      return;
    }
    if (qty <= 0) {
      showErrorOn(messenger, ApiError('Quantity must be greater than zero'));
      return;
    }
    if (reason.isEmpty) {
      showErrorOn(messenger, ApiError('A reason is required'));
      return;
    }
    try {
      await app.api.postWaste(name: name, qty: qty, reason: reason, cost: cost);
      showInfoOn(messenger, 'Waste recorded');
      _name.clear();
      _qty.text = '1';
      _cost.clear();
      _reason.clear();
      if (mounted) setState(() => _formOpen = false);
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _entries.isEmpty) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final pal = Pal.of(context);
    final today = _entries.where(_isToday).toList();
    final todayCost =
        today.fold<double>(0, (s, w) => s + w.cost);

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: KpiCard(
                label: 'Logged today',
                value: '${today.length}',
                icon: Icons.delete_outline,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                label: 'Est. cost',
                value: money(todayCost),
                icon: Icons.savings_outlined,
              ),
            ),
          ]),
          const SizedBox(height: 10),
          // Log it while it is in your hands — one tap opens the form.
          SizedBox(
            height: 34,
            child: FilledButton.icon(
              onPressed: () => setState(() => _formOpen = !_formOpen),
              icon: Icon(_formOpen ? Icons.close : Icons.add, size: 16),
              label: Text(_formOpen ? 'Close form' : 'Record waste'),
            ),
          ),
          if (_formOpen) ...[
            const SizedBox(height: 10),
            _buildForm(pal),
          ],
          const SizedBox(height: 12),
          SectionCard(
            title: 'Log',
            trailing: Text('${_entries.length} entries',
                style: TextStyle(
                    fontFamily: kFontMono,
                    fontSize: 10.5,
                    color: pal.faint)),
            children: [
              if (_entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: Text('Nothing recorded yet',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11.5,
                            color: pal.faint)),
                  ),
                )
              else
                for (final w in _entries.take(20))
                  ListRow(
                    head: w.item,
                    rest:
                        '${_fmtQty(w.qty)}${w.unit ?? ''} · ${w.reason.isEmpty ? '—' : w.reason}${w.loggedBy != null ? ' · ${w.loggedBy}' : ''}',
                    trailing: w.cost > 0 ? money(w.cost) : '',
                  ),
            ],
          ),
        ],
      ),
    );
  }

  static String _fmtQty(double q) =>
      q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toString();

  Widget _buildForm(Pal pal) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: pal.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('What was thrown away?',
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: pal.heading)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              flex: 3,
              child: TextFormField(
                controller: _name,
                decoration: const InputDecoration(
                    hintText: 'Item (e.g. Milk 1L)'),
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                controller: _qty,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(hintText: 'Qty'),
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                controller: _cost,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(hintText: 'ETB cost'),
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          TextFormField(
            controller: _reason,
            decoration: const InputDecoration(
                hintText: 'Reason (spoiled, dropped, expired…)'),
            style: const TextStyle(fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 34,
            child: FilledButton(
              onPressed: _submit,
              style: FilledButton.styleFrom(
                  textStyle: const TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
              child: const Text('Save entry'),
            ),
          ),
        ],
      ),
    );
  }
}
