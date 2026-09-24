/// Inventory — the web `InventoryView.vue`: the stock catalogue with
/// ledger-based adjustments. Stock never changes directly — the ± button and
/// the edit sheet both land as audited `POST /inventory/:id/adjust` entries,
/// and the server refuses quantity writes on the catalogue PUT.
///
/// Manager + head-chef add/edit/adjust; delete is manager-only; everyone
/// else with the grant reads.
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

const kInventoryUnits = ['kg', 'g', 'L', 'ml', 'pcs', 'bag', 'box', 'bottle'];
const kInventoryCategories = [
  'Coffee & Tea', 'Dairy', 'Bakery', 'Produce', 'Meat', 'Dry Goods',
  'Beverages', 'Packaging', 'Cleaning', 'Other',
];

class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  List<InventoryItem> _rows = [];
  bool _loading = true;
  Object? _error;
  bool _lowOnly = false;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _role => ref.read(appStateProvider).roleKey ?? '';
  bool get _canWrite => _role == 'manager' || _role == 'head-chef';
  bool get _canDelete => _role == 'manager';

  Future<void> _load({bool quiet = false}) async {
    final app = ref.read(appStateProvider);
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final rows = await app.api.inventory();
      if (!mounted) return;
      setState(() { _rows = rows; _loading = false; });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) { await app.sessionExpired(); return; }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  List<InventoryItem> get _filtered {
    final q = _search.text.trim().toLowerCase();
    final rows = _rows.where((i) {
      if (_lowOnly && !i.isLow) return false;
      if (q.isNotEmpty &&
          !i.name.toLowerCase().contains(q) &&
          !i.category.toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return rows;
  }

  Future<void> _form({InventoryItem? edit}) async {
    final nameC = TextEditingController(text: edit?.name ?? '');
    String cat = edit?.category.isEmpty == false ? edit!.category : kInventoryCategories.first;
    String unit = edit?.unit.isEmpty == false ? edit!.unit : 'kg';
    final minC = TextEditingController(
        text: edit != null && edit.minLevel > 0 ? edit.minLevel.toString() : '');
    final costC = TextEditingController(
        text: edit != null && edit.cost > 0 ? edit.cost.toStringAsFixed(2) : '');
    final messenger = ScaffoldMessenger.of(context);
    final app = ref.read(appStateProvider);
    await showFormSheet(
      context,
      title: edit == null ? 'Add stock item' : 'Edit ${edit.name}',
      body: () => StatefulBuilder(
        builder: (ctx, setSheet) => Column(
          children: [
            TextF('Name', nameC, hint: 'e.g. Milk 1L'),
            SelectF(
                label: 'Category', value: cat,
                options: kInventoryCategories,
                onChanged: (v) => setSheet(() => cat = v)),
            SelectF(
                label: 'Unit', value: unit,
                options: kInventoryUnits,
                onChanged: (v) => setSheet(() => unit = v)),
            TextF('Low-stock alert level', minC, numeric: true,
                hint: 'Reorder point'),
            TextF('Unit cost (ETB)', costC, numeric: true),
          ],
        ),
      ),
      onSave: () async {
        if (nameC.text.trim().isEmpty) {
          showErrorOn(messenger, ApiError('A name is required'));
          return;
        }
        try {
          if (edit == null) {
            await app.api.postInventory(
              name: nameC.text,
              category: cat,
              unit: unit,
              quantity: 0, // stock arrives via purchase/adjust, not the catalogue
              minLevel: double.tryParse(minC.text) ?? 0,
              cost: double.tryParse(costC.text.replaceAll(',', '.')) ?? 0,
            );
          } else {
            await app.api.updateInventory(edit.id, {
              'name': nameC.text.trim(),
              'category': cat,
              'unit': unit,
              'minLevel': double.tryParse(minC.text) ?? 0,
              'cost': double.tryParse(costC.text.replaceAll(',', '.')) ?? 0,
            });
          }
          showInfoOn(messenger, edit == null ? 'Item added' : 'Item updated');
          await _load(quiet: true);
        } catch (e) {
          showErrorOn(messenger, e);
          rethrow;
        }
      },
    );
  }

  Future<void> _adjust(InventoryItem item) async {
    final targetC = TextEditingController(text: item.stock.toStringAsFixed(0));
    final reasonC = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    final app = ref.read(appStateProvider);
    await showFormSheet(
      context,
      title: 'Adjust ${item.name}',
      saveLabel: 'Adjust',
      body: () => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Now: ${_fmt(item.stock)}${item.unit}',
              style: TextStyle(
                  fontFamily: kFontMono, fontSize: 12, color: Pal.of(context).muted)),
          const SizedBox(height: 8),
          TextF('Counted stock (${item.unit})', targetC, numeric: true,
              hint: 'What you actually have'),
          TextF('Reason (required, audited)', reasonC,
              hint: 'delivery, spoilage, recount…'),
        ],
      ),
      onSave: () async {
        final target = double.tryParse(targetC.text.replaceAll(',', '.'));
        if (target == null || reasonC.text.trim().isEmpty) {
          showErrorOn(messenger, ApiError('A counted level and a reason are required'));
          return;
        }
        try {
          await app.api.adjustInventory(item.id, target, reasonC.text);
          showInfoOn(messenger, 'Stock adjusted');
          await _load(quiet: true);
        } catch (e) {
          showErrorOn(messenger, e);
          rethrow;
        }
      },
    );
  }

  Future<void> _delete(InventoryItem item) async {
    final messenger = ScaffoldMessenger.of(context);
    final app = ref.read(appStateProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete item?'),
        content: Text('${item.name} leaves the catalogue. This cannot be undone.'),
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
      await app.api.deleteInventory(item.id);
      showInfoOn(messenger, 'Item deleted');
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    if (_loading && _rows.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _rows.isEmpty) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final pal = Pal.of(context);
    final rows = _filtered;
    final lowCount = _rows.where((i) => i.isLow).length;

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          if (lowCount > 0)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: pal.warningBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: pal.warningBorder),
              ),
              child: Row(children: [
                Icon(Icons.warning_amber_outlined, size: 16, color: pal.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$lowCount item${lowCount == 1 ? '' : 's'} at or below the reorder point',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: pal.warning),
                  ),
                ),
                RowAction('Show', () => setState(() => _lowOnly = !_lowOnly)),
              ]),
            ),
          Row(children: [
            Expanded(
              child: SearchField(
                  controller: _search,
                  hint: 'Search items…',
                  onChanged: (_) => setState(() {})),
            ),
            const SizedBox(width: 8),
            RowAction(
                _lowOnly ? 'All' : 'Low only',
                () => setState(() => _lowOnly = !_lowOnly)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Text('${rows.length} items',
                  style: TextStyle(
                      fontFamily: kFontMono, fontSize: 10.5, color: pal.faint)),
            ),
            if (_canWrite)
              RowAction('+ Add item', () => _form()),
          ]),
          const SizedBox(height: 8),
          SectionCard(
            title: 'Catalogue',
            children: [
              for (final i in rows.take(200))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(i.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: pal.heading)),
                            const SizedBox(height: 1),
                            Text(
                                '${i.category} · min ${_fmt(i.minLevel)}${i.unit}'
                                '${i.cost > 0 ? ' · ${money(i.cost)}/${i.unit}' : ''}',
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 10.5, color: pal.faint)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: i.isLow ? pal.warningBg : pal.tintBg,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: i.isLow ? pal.warningBorder : pal.tintBorder),
                        ),
                        child: Text('${_fmt(i.stock)} ${i.unit}',
                            style: TextStyle(
                                fontFamily: kFontMono,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: i.isLow ? pal.warning : pal.primary)),
                      ),
                      if (_canWrite) ...[
                        const SizedBox(width: 6),
                        RowAction('±', () => _adjust(i)),
                        const SizedBox(width: 4),
                        RowAction('Edit', () => _form(edit: i)),
                        if (_canDelete) ...[
                          const SizedBox(width: 4),
                          AsyncRowAction('Del', () => _delete(i), color: pal.danger),
                        ],
                      ],
                    ],
                  ),
                ),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                      child: Text('Nothing in the catalogue',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 11.5, color: pal.faint))),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
