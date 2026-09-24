/// Menu management — the web `MenuMgmtView.vue`. Two faces:
///  * manager — full catalogue CRUD (add/edit/delete, cost & margin columns)
///  * head-chef — the dish-86 toggle only (the API only accepts the
///    availability flag from the kitchen; add/edit/delete hide)
///
/// Tier-2: the list rides the SHARED menuProvider (register, boards and
/// analytics watch the same catalogue) — every create/update/delete/86
/// toggle invalidates it, and the shared copy refetches everywhere.
/// Search and the category filter are client-side.
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

const kMenuCategories = [
  'Coffee', 'Tea', 'Juices & Smoothies', 'Bakery & Pastry', 'Breakfast',
  'Starters', 'Mains', 'Desserts', 'Sandwiches & Burgers', 'Other',
];

class MenuMgmtScreen extends ConsumerStatefulWidget {
  const MenuMgmtScreen({super.key});

  @override
  ConsumerState<MenuMgmtScreen> createState() => _MenuMgmtScreenState();
}

class _MenuMgmtScreenState extends ConsumerState<MenuMgmtScreen> {
  String _category = 'All';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _role => ref.read(appStateProvider).roleKey ?? '';
  bool get _canCrud => _role == 'manager';

  void _reload() => ref.invalidate(menuProvider);

  /// Categories actually on the menu + the defaults, merged per the web.
  List<String> _categories(List<MenuItem> rows) {
    final set = <String>{...kMenuCategories};
    for (final m in rows) {
      if (m.category.isNotEmpty) set.add(m.category);
    }
    return set.toList();
  }

  List<MenuItem> _filtered(List<MenuItem> all) {
    final q = _search.text.trim().toLowerCase();
    return all.where((m) {
      if (_category != 'All' && m.category != _category) return false;
      if (q.isNotEmpty && !m.name.toLowerCase().contains(q)) return false;
      return true;
    }).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> _toggle(MenuItem m) async {
    final messenger = ScaffoldMessenger.of(context);
    final app = ref.read(appStateProvider);
    try {
      await app.api.setAvailability(m.id, !m.available);
      showInfoOn(messenger,
          !m.available ? '${m.name} is back on' : '${m.name} marked 86');
      _reload();
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Future<void> _form({MenuItem? edit}) async {
    final menu = ref.read(menuProvider).value ?? const <MenuItem>[];
    final cats = _categories(menu);
    final nameC = TextEditingController(text: edit?.name ?? '');
    String cat = edit?.category ?? cats.first;
    final priceC = TextEditingController(
        text: edit != null && edit.price > 0 ? edit.price.toStringAsFixed(2) : '');
    final costC = TextEditingController();
    final descC = TextEditingController(text: edit?.description ?? '');
    final modsC = TextEditingController(
        text: edit?.modifiers.map((m) => m.name).join(', ') ?? '');
    bool available = edit?.available ?? true;
    final messenger = ScaffoldMessenger.of(context);
    final app = ref.read(appStateProvider);
    await showFormSheet(
      context,
      title: edit == null ? 'Add menu item' : 'Edit ${edit.name}',
      body: () => StatefulBuilder(
        builder: (ctx, setSheet) => Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextF('Name *', nameC),
                SelectF(
                    label: 'Category', value: cat,
                    options: cats,
                    onChanged: (v) => setSheet(() => cat = v)),
                TextF('Price (ETB)', priceC, numeric: true),
                TextF('Cost (ETB, for margin)', costC, numeric: true),
                TextF('Description', descC, multiline: true),
                TextF('Modifiers (comma-separated)', modsC,
                    hint: 'Oat milk, Extra shot…'),
                Row(children: [
                  Text('Available',
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 12, color: Pal.of(ctx).body)),
                  const Spacer(),
                  Switch(
                      value: available,
                      activeThumbColor: Pal.of(ctx).primary,
                      onChanged: (v) => setSheet(() => available = v)),
                ]),
              ],
            ),
          ),
        ),
      ),
      onSave: () async {
        final price = double.tryParse(priceC.text.replaceAll(',', '.')) ?? 0;
        if (nameC.text.trim().isEmpty || price <= 0) {
          showErrorOn(messenger, ApiError('A name and a price are required'));
          return;
        }
        final payload = {
          'name': nameC.text.trim(),
          'category': cat,
          'price': price,
          'description': descC.text.trim(),
          'available': available,
          'modifiers': modsC.text
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .map((s) => {'name': s, 'priceDelta': 0})
              .toList(),
        };
        try {
          if (edit == null) {
            await app.api.postMenu(payload);
          } else {
            await app.api.updateMenu(edit.id, payload);
          }
          showInfoOn(messenger, edit == null ? 'Item added' : 'Item updated');
          _reload();
        } catch (e) {
          showErrorOn(messenger, e);
          rethrow;
        }
      },
    );
  }

  Future<void> _delete(MenuItem m) async {
    final messenger = ScaffoldMessenger.of(context);
    final app = ref.read(appStateProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete item?'),
        content: Text('${m.name} leaves the menu. This cannot be undone.'),
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
      await app.api.deleteMenu(m.id);
      showInfoOn(messenger, 'Item deleted');
      _reload();
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rowsAsync = ref.watch(menuProvider);
    final all = rowsAsync.value ?? const <MenuItem>[];
    if (rowsAsync.isLoading && all.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rowsAsync.hasError && all.isEmpty) {
      return LoadError(error: rowsAsync.error!, onRetry: _reload);
    }
    final pal = Pal.of(context);
    final rows = _filtered(all);
    final out = all.where((m) => !m.available).length;

    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          if (!_canCrud)
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: pal.infoBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: pal.infoBorder),
              ),
              child: Text(
                'Kitchen view — you can mark dishes 86 (sold out) and bring them back; catalogue edits stay with the manager.',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 11.5, color: pal.info),
              ),
            ),
          Row(children: [
            Expanded(
                child: KpiCard(label: 'Menu items',
                    value: '${all.length}', icon: Icons.restaurant_menu_outlined)),
            const SizedBox(width: 8),
            Expanded(
                child: KpiCard(label: 'Marked 86',
                    value: '$out',
                    valueColor: out > 0 ? pal.warning : pal.success,
                    icon: Icons.block_outlined)),
          ]),
          const SizedBox(height: 10),
          SearchField(
              controller: _search,
              hint: 'Search the menu…',
              onChanged: (_) => setState(() {})),
          const SizedBox(height: 8),
          ChipSelect(
            value: _category,
            options: [('All', 'All'), ..._categories(all).map((c) => (c, c))],
            onChanged: (v) => setState(() => _category = v),
          ),
          const SizedBox(height: 10),
          if (_canCrud)
            SizedBox(
              height: 34,
              child: FilledButton.icon(
                onPressed: () => _form(),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add item'),
              ),
            ),
          const SizedBox(height: 10),
          SectionCard(
            title: 'Catalogue',
            trailing: Text(_canCrud ? 'cost & margin shown' : '86 toggle only',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 9.5, color: pal.faint)),
            children: [
              for (final m in rows.take(200))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(m.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: pal.heading)),
                            const SizedBox(height: 1),
                            Text(
                                '${m.category} · ${money(m.price)}'
                                '${m.modifiers.isNotEmpty ? ' · ${m.modifiers.length} mods' : ''}',
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 10.5, color: pal.faint)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => _toggle(m),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: m.available ? pal.successBg : pal.dangerBg,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                                color: m.available
                                    ? pal.successBorder
                                    : pal.dangerBorder),
                          ),
                          child: Text(
                              m.available ? 'AVAILABLE' : '86 · SOLD OUT',
                              style: TextStyle(
                                  fontFamily: kFontBody,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  color: m.available ? pal.success : pal.danger)),
                        ),
                      ),
                      if (_canCrud) ...[
                        const SizedBox(width: 6),
                        RowAction('Edit', () => _form(edit: m)),
                        const SizedBox(width: 4),
                        AsyncRowAction('Del', () => _delete(m), color: pal.danger),
                      ],
                    ],
                  ),
                ),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                      child: Text('Nothing in this category',
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
