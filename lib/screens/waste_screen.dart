/// Waste log — the cleaner's / barista's screen, from the web
/// `WasteView.vue`. Two ways to log: pick a stock item (the server deducts
/// it from inventory through the ledger) or free-text what is in your hands.
/// Category summary cards like the web; delete is manager-only.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/backoffice.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

const kWasteReasons = ['spoiled', 'overproduction', 'quality', 'damaged', 'other'];
const kWasteCategories = [
  'Coffee & Tea', 'Dairy', 'Bakery', 'Produce', 'Meat', 'Dry Goods',
  'Beverages', 'Packaging', 'Other',
];

class WasteScreen extends ConsumerStatefulWidget {
  const WasteScreen({super.key});

  @override
  ConsumerState<WasteScreen> createState() => _WasteScreenState();
}

class _WasteScreenState extends ConsumerState<WasteScreen> {
  List<WasteEntry> _entries = [];
  List<InventoryItem> _stock = [];
  bool _loading = true;
  Object? _error;
  String _category = 'All';

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _role => ref.read(appStateProvider).roleKey ?? '';
  bool get _canDelete => _role == 'manager';

  Future<void> _load({bool quiet = false}) async {
    final app = ref.read(appStateProvider);
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      // Future.wait: every request keeps a listener even when a sibling
      // fails first — sequential awaits used to strand the losers as
      // unhandled async errors.
      final results = await Future.wait<dynamic>(
          [app.api.wasteLog(), app.api.inventory()]);
      final entries = results[0] as List<WasteEntry>;
      final stock = results[1] as List<InventoryItem>; // may 403 for cleaner → free-text path
      if (!mounted) return;
      setState(() { _entries = entries; _stock = stock; _loading = false; });
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

  List<WasteEntry> get _filtered {
    if (_category == 'All') return _entries;
    return _entries
        .where((w) => w.item.toLowerCase().contains(_category.toLowerCase()))
        .toList();
  }

  Map<String, double> get _todayByCategory {
    final map = <String, double>{};
    for (final w in _entries.where(_isToday)) {
      map[w.item] = (map[w.item] ?? 0) + w.cost;
    }
    return Map.fromEntries(
        (map.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
            .take(6));
  }

  Future<void> _logForm() async {
    final messenger = ScaffoldMessenger.of(context);
    final app = ref.read(appStateProvider);
    String? inventoryId; // null = free-text path
    final nameC = TextEditingController();
    final qtyC = TextEditingController(text: '1');
    final costC = TextEditingController();
    String reason = kWasteReasons.first;
    String category = kWasteCategories.last;

    await showFormSheet(
      context,
      title: 'Record waste',
      body: () => StatefulBuilder(
        builder: (ctx, setSheet) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_stock.isNotEmpty) ...[
              DropdownButton<String?>(
                value: inventoryId,
                isExpanded: true,
                underline: const SizedBox(),
                dropdownColor: Pal.of(ctx).surface,
                hint: Text('Stock item (deducted from inventory)…',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 11.5, color: Pal.of(ctx).faint)),
                items: [
                  const DropdownMenuItem<String?>(
                      value: '__free__', child: Text('Free-text item')),
                  for (final s in _stock.take(100))
                    DropdownMenuItem<String?>(
                        value: s.id,
                        child: Text('${s.name} (${s.stock.toStringAsFixed(0)} ${s.unit} left)',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 11.5, color: Pal.of(ctx).body))),
                ],
                onChanged: (v) => setSheet(() =>
                    inventoryId = (v == '__free__' || v == null) ? null : v),
              ),
              const SizedBox(height: 8),
            ],
            if (inventoryId == null)
              TextF('What was thrown away?', nameC, hint: 'e.g. Milk 1L')
            else
              Text('Free-text disabled while a stock item is picked',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 10.5, color: Pal.of(ctx).faint)),
            SelectF(
                label: 'Category', value: category,
                options: kWasteCategories,
                onChanged: (v) => setSheet(() => category = v)),
            TextF('Quantity', qtyC, numeric: true),
            SelectF(
                label: 'Reason (required)', value: reason,
                options: kWasteReasons,
                onChanged: (v) => setSheet(() => reason = v)),
            TextF('Estimated cost (ETB)', costC, numeric: true),
          ],
        ),
      ),
      onSave: () async {
        final qty = double.tryParse(qtyC.text.replaceAll(',', '.')) ?? 0;
        final cost = double.tryParse(costC.text.replaceAll(',', '.')) ?? 0;
        if (qty <= 0) {
          showErrorOn(messenger, ApiError('Quantity must be greater than zero'));
          return;
        }
        final name = inventoryId == null
            ? nameC.text.trim()
            : _stock.where((s) => s.id == inventoryId).map((s) => s.name).firstOrNull ?? '';
        if (name.isEmpty) {
          showErrorOn(messenger, ApiError('What was thrown away?'));
          return;
        }
        try {
          await app.api.postWaste(
            name: name,
            qty: qty,
            reason: reason,
            cost: cost,
            inventoryId: inventoryId,
          );
          showInfoOn(messenger,
              inventoryId != null ? 'Waste recorded — stock deducted' : 'Waste recorded');
          await _load(quiet: true);
        } catch (e) {
          showErrorOn(messenger, e);
          rethrow;
        }
      },
    );
  }

  Future<void> _delete(WasteEntry w) async {
    final messenger = ScaffoldMessenger.of(context);
    final app = ref.read(appStateProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete waste entry?'),
        content: Text('${w.item} — ${money(w.cost)}. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Pal.of(ctx).danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await app.api.deleteWaste(w.id);
      showInfoOn(messenger, 'Entry deleted');
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  static String _fmtQty(double q) =>
      q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toString();

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
    final todayCost = today.fold<double>(0, (s, w) => s + w.cost);
    final rows = _filtered;
    final byCat = _todayByCategory;

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
                  label: 'Logged today', value: '${today.length}',
                  icon: Icons.delete_outline),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                  label: 'Est. cost', value: money(todayCost),
                  icon: Icons.savings_outlined),
            ),
          ]),
          const SizedBox(height: 10),
          // Log it while it is in your hands — one tap opens the form.
          SizedBox(
            height: 34,
            child: FilledButton.icon(
              onPressed: _logForm,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Record waste'),
            ),
          ),
          const SizedBox(height: 10),
          ChipSelect(
            value: _category,
            options: [('All', 'All items'), ...kWasteCategories.map((c) => (c, c))],
            onChanged: (v) => setState(() => _category = v),
          ),
          if (byCat.isNotEmpty) ...[
            const SizedBox(height: 10),
            SectionCard(
              title: "Today's waste by item",
              children: [
                for (final e in byCat.entries)
                  ListRow(head: e.key, trailing: money(e.value)),
              ],
            ),
          ],
          const SizedBox(height: 10),
          SectionCard(
            title: 'Log',
            trailing: Text('${rows.length} entries',
                style: TextStyle(
                    fontFamily: kFontMono,
                    fontSize: 10.5,
                    color: pal.faint)),
            children: [
              if (rows.isEmpty)
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
                for (final w in rows.take(30))
                  ListRow(
                    head: w.item,
                    rest:
                        '${_fmtQty(w.qty)}${w.unit ?? ''} · ${w.reason.isEmpty ? '—' : w.reason}${w.loggedBy != null ? ' · ${w.loggedBy}' : ''}',
                    trailing: w.cost > 0 ? money(w.cost) : '',
                    trailingColor: w.cost > 0 ? pal.warning : null,
                  ),
            ],
          ),
          if (_canDelete && rows.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: Text('Long-press an entry below to remove it (manager)',
                    style: TextStyle(
                        fontFamily: kFontBody, fontSize: 10, color: pal.faint)),
              ),
            ),
          if (_canDelete)
            for (final w in rows.take(10))
              InkWell(
                onLongPress: () => _delete(w),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Icon(Icons.delete_outline, size: 12, color: pal.faint),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                          '${dayKey(w.date)} · ${w.item} · ${money(w.cost)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 10.5, color: pal.muted)),
                    ),
                  ]),
                ),
              ),
        ],
      ),
    );
  }
}
