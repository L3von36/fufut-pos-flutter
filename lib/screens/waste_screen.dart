/// Waste log — the cleaner's / barista's screen, from the web
/// `WasteView.vue`. Two ways to log: pick a stock item (the server deducts
/// it from inventory through the ledger) or free-text what is in your hands.
/// Category summary cards like the web; delete is manager-only.
///
/// Tier-2: the log rides the SHARED wasteLogProvider (the cleaner's
/// dashboard watches the same feed); the stock list for the picker is its
/// own screen-scoped provider (a refused catalogue read degrades to the
/// free-text path — `inventory()` turns 403 into an empty list). The
/// session is READ inside the providers, never watched.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/catalog_providers.dart';
import '../theme.dart';
import '../widgets/backoffice.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

const kWasteReasons = ['spoiled', 'overproduction', 'quality', 'damaged', 'other'];
const kWasteCategories = [
  'Coffee & Tea', 'Dairy', 'Bakery', 'Produce', 'Meat', 'Dry Goods',
  'Beverages', 'Packaging', 'Other',
];

/// The stock list behind the picker — logging waste against an item is how
/// the ledger deducts it, so the picker needs the current catalogue levels.
final wasteStockProvider = FutureProvider<List<InventoryItem>>((ref) async {
  final app = ref.read(appStateProvider);
  try {
    return await app.api.inventory();
  } on ApiError catch (e) {
    if (e.isAuthError) await app.sessionExpired();
    rethrow;
  }
});

class WasteScreen extends ConsumerStatefulWidget {
  const WasteScreen({super.key});

  @override
  ConsumerState<WasteScreen> createState() => _WasteScreenState();
}

class _WasteScreenState extends ConsumerState<WasteScreen> {
  String _category = 'All';

  String get _role => ref.read(appStateProvider).roleKey ?? '';
  bool get _canDelete => _role == 'manager';

  /// Logging and deleting both move the ledger — refresh the log and the
  /// stock levels the picker shows.
  void _reload() {
    ref.invalidate(wasteLogProvider);
    ref.invalidate(wasteStockProvider);
  }

  bool _isToday(WasteEntry w) {
    final d = w.date;
    if (d == null || d.length < 10) return false;
    final now = DateTime.now();
    String pad(int v) => v.toString().padLeft(2, '0');
    final today = '${now.year}-${pad(now.month)}-${pad(now.day)}';
    return d.substring(0, 10) == today;
  }

  List<WasteEntry> _filtered(List<WasteEntry> entries) {
    if (_category == 'All') return entries;
    return entries
        .where((w) => w.item.toLowerCase().contains(_category.toLowerCase()))
        .toList();
  }

  Map<String, double> _todayByCategory(List<WasteEntry> entries) {
    final map = <String, double>{};
    for (final w in entries.where(_isToday)) {
      map[w.item] = (map[w.item] ?? 0) + w.cost;
    }
    return Map.fromEntries(
        (map.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
            .take(6));
  }

  Future<void> _logForm(List<InventoryItem> stock) async {
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
            if (stock.isNotEmpty) ...[
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
                  for (final s in stock.take(100))
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
            : stock.where((s) => s.id == inventoryId).map((s) => s.name).firstOrNull ?? '';
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
          _reload();
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
      _reload();
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  static String _fmtQty(double q) =>
      q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toString();

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(wasteLogProvider);
    final stockAsync = ref.watch(wasteStockProvider);
    final entries = entriesAsync.value ?? const <WasteEntry>[];
    final stock = stockAsync.value ?? const <InventoryItem>[];
    if (entriesAsync.isLoading && entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (entriesAsync.hasError && entries.isEmpty) {
      return LoadError(error: entriesAsync.error!, onRetry: _reload);
    }
    final pal = Pal.of(context);
    final today = entries.where(_isToday).toList();
    final todayCost = today.fold<double>(0, (s, w) => s + w.cost);
    final rows = _filtered(entries);
    final byCat = _todayByCategory(entries);

    return RefreshIndicator(
      onRefresh: () async => _reload(),
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
              onPressed: () => _logForm(stock),
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
