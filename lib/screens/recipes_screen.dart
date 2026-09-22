/// Recipes — the web `RecipesView.vue`: per-dish bills of materials with
/// versioning, cost & margin, "can we make it" capacity and history. Barista
/// sees drink recipes read-only (lib/drinks filter); manager + head-chef
/// create and revise.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/roles.dart';
import '../theme.dart';
import '../widgets/backoffice.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

class RecipesScreen extends StatefulWidget {
  const RecipesScreen({super.key});

  @override
  State<RecipesScreen> createState() => _RecipesScreenState();
}

class _RecipesScreenState extends State<RecipesScreen> {
  List<RecipeRow> _rows = [];
  List<MenuItem> _menu = [];
  List<InventoryItem> _stock = [];
  List<UnitRow> _units = [];
  bool _loading = true;
  Object? _error;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _role => context.read<AppState>().roleKey ?? '';
  bool get _isBarista => _role == 'barista';
  bool get _canWrite => _role == 'manager' || _role == 'head-chef';

  /// Barista scope: drink recipes only (category or name reads as a drink).
  bool _isDrinkName(String name) {
    final cat = _menu
        .where((m) => m.name == name)
        .map((m) => m.category)
        .firstOrNull ?? '';
    return nameIsDrink(cat, name);
  }

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final rowsF = app.api.recipes();
      final menuF = app.api.menu();
      final stockF = app.api.inventory();
      final unitsF = app.api.units();
      final rows = await rowsF;
      final menu = await menuF;
      final stock = await stockF;
      final units = await unitsF;
      if (!mounted) return;
      setState(() {
        _rows = rows; _menu = menu; _stock = stock; _units = units;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) { await app.sessionExpired(); return; }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  List<RecipeRow> get _filtered {
    var rows = _rows;
    if (_isBarista) rows = rows.where((r) => _isDrinkName(r.menuItemName)).toList();
    switch (_filter) {
      case 'provisional':
        return rows.where((r) => r.provisional).toList();
      case 'thin':
        return rows.where((r) => r.grossMarginPct < 40).toList();
      default:
        return rows;
    }
  }

  /// Menu items with no recipe at all — the coverage banner's list.
  List<MenuItem> get _uncovered {
    final covered = _rows.map((r) => r.menuItemId).toSet();
    var items = _menu;
    if (_isBarista) {
      items = items.where((m) => nameIsDrink(m.category, m.name)).toList();
    }
    return items.where((m) => !covered.contains(m.id)).toList();
  }

  double get _avgMargin {
    final priced = _filtered.where((r) => r.price > 0 && r.totalCost > 0);
    if (priced.isEmpty) return 0;
    return priced.map((r) => r.grossMarginPct).reduce((a, b) => a + b) /
        priced.length;
  }

  Future<void> _capacity(RecipeRow r) async {
    final app = context.read<AppState>();
    final pal = Pal.of(context);
    try {
      final cap = await app.api.recipeCapacity(r.id);
      if (!mounted) return;
      await showModalBottomSheet(
        context: context,
        backgroundColor: pal.surface,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (ctx) => Padding(
          // Bottom clears the edge-to-edge gesture nav bar on Android.
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, 16 + MediaQuery.paddingOf(ctx).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Can make — ${r.menuItemName}',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 14, fontWeight: FontWeight.w800, color: pal.heading)),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: KpiCard(label: 'Servings possible',
                        value: cap.servings.toStringAsFixed(0),
                        valueColor: pal.primary)),
                const SizedBox(width: 8),
                Expanded(
                    child: KpiCard(label: 'Limited by',
                        value: cap.limitingIngredient.isEmpty
                            ? '—' : cap.limitingIngredient,
                        icon: Icons.warning_amber_outlined)),
              ]),
              const SizedBox(height: 10),
              for (final line in cap.rows.take(10))
                ListRow(
                    head: line.name,
                    rest: line.isPackaging ? 'packaging' : 'ingredient',
                    trailing: '${_f(line.qty)} ${line.unit}'),
            ],
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showErrorOn(ScaffoldMessenger.of(context), e);
    }
  }

  Future<void> _history(RecipeRow r) async {
    final app = context.read<AppState>();
    final pal = Pal.of(context);
    try {
      final versions = await app.api.recipeVersions(r.id);
      if (!mounted) return;
      await showModalBottomSheet(
        context: context,
        backgroundColor: pal.surface,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (ctx) => Padding(
          // Bottom clears the edge-to-edge gesture nav bar on Android.
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, 16 + MediaQuery.paddingOf(ctx).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('History — ${r.menuItemName}',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 14, fontWeight: FontWeight.w800, color: pal.heading)),
              const SizedBox(height: 10),
              for (final v in versions.take(12))
                ListRow(
                    head: 'v${v.version}',
                    rest: '${v.status}${v.createdBy != null ? ' · ${v.createdBy}' : ''}'
                        '${v.createdAt != null ? ' · ${dayKey(v.createdAt)}' : ''}',
                    trailing: '${v.lines.length} lines'),
              if (versions.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                      child: Text('No versions recorded',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 11.5, color: pal.faint))),
                ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showErrorOn(ScaffoldMessenger.of(context), e);
    }
  }

  Future<void> _editor({RecipeRow? edit}) async {
    final messenger = ScaffoldMessenger.of(context);
    final app = context.read<AppState>();
    final items = _isBarista
        ? _menu.where((m) => nameIsDrink(m.category, m.name)).toList()
        : _menu;
    String menuItemId =
        edit?.menuItemId ?? (items.isNotEmpty ? items.first.id : '');
    final yieldC = TextEditingController(
        text: edit?.yieldQty.toStringAsFixed(0) ?? '1');
    final notesC = TextEditingController(text: edit?.notes ?? '');
    final lines = <_RecipeLineInput>[
      _RecipeLineInput(stock: _stock, units: _units),
    ];

    await showFormSheet(
      context,
      title: edit == null ? 'New recipe' : 'Revise ${edit.menuItemName}',
      saveLabel: edit == null ? 'Create' : 'Save as new version',
      body: () => StatefulBuilder(
        builder: (ctx, setSheet) => Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButton<String>(
                  value: menuItemId,
                  isExpanded: true,
                  underline: const SizedBox(),
                  dropdownColor: Pal.of(ctx).surface,
                  items: [
                    for (final m in items)
                      DropdownMenuItem(
                          value: m.id,
                          child: Text('${m.name} · ${money(m.price)}',
                              style: TextStyle(
                                  fontFamily: kFontBody,
                                  fontSize: 12, color: Pal.of(ctx).body))),
                  ],
                  onChanged: edit != null
                      ? null // the menu item is locked when editing
                      : (v) => setSheet(() => menuItemId = v ?? menuItemId),
                ),
                Text(edit != null ? 'Menu item is locked when revising'
                    : 'Pick the dish this recipe produces',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 10, color: Pal.of(ctx).faint)),
                const SizedBox(height: 8),
                TextF('Yield (servings per batch)', yieldC, numeric: true),
                TextF('Notes', notesC, multiline: true,
                    hint: 'method, plating, allergies…'),
                for (final l in lines) l.build(ctx),
                RowAction('+ Add ingredient line',
                    () => setSheet(() => lines.add(_RecipeLineInput(
                        stock: _stock, units: _units)))),
              ],
            ),
          ),
        ),
      ),
      onSave: () async {
        final payloadLines = <Map<String, dynamic>>[];
        for (final l in lines) {
          if (l.inventoryId.isEmpty || l.qty <= 0) continue;
          payloadLines.add({
            'inventoryId': l.inventoryId,
            'qty': l.qty,
            'unit': l.unit,
            'isPackaging': l.isPackaging,
          });
        }
        if (menuItemId.isEmpty || payloadLines.isEmpty) {
          showErrorOn(messenger,
              ApiError('Pick a dish and at least one ingredient line'));
          return;
        }
        final item = items.where((m) => m.id == menuItemId).firstOrNull;
        try {
          await app.api.postRecipe(
            menuItemId: menuItemId,
            name: item?.name ?? '',
            yieldQty: double.tryParse(yieldC.text) ?? 1,
            notes: notesC.text.trim(),
            lines: payloadLines,
          );
          showInfoOn(messenger, 'Recipe saved — stock will move with sales');
          await _load(quiet: true);
        } catch (e) {
          showErrorOn(messenger, e);
          rethrow;
        }
      },
    );
  }

  static String _f(double v) =>
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
    final uncovered = _uncovered;

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          if (uncovered.isNotEmpty && !_isBarista)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: pal.warningBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: pal.warningBorder),
              ),
              child: Text(
                '${uncovered.length} menu item${uncovered.length == 1 ? ' has' : 's have'} no recipe — stock will not move when they sell',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: pal.warning),
              ),
            ),
          if (_isBarista)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: pal.infoBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: pal.infoBorder),
              ),
              child: Text('Drink recipes — read only',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: pal.info)),
            ),
          Row(children: [
            Expanded(
                child: KpiCard(label: 'Recipes',
                    value: '${rows.length}', icon: Icons.menu_book_outlined)),
            const SizedBox(width: 8),
            Expanded(
                child: KpiCard(label: 'Avg margin',
                    value: '${_avgMargin.toStringAsFixed(0)}%',
                    valueColor: _avgMargin >= 60 ? pal.success : pal.warning,
                    icon: Icons.percent_outlined)),
          ]),
          const SizedBox(height: 10),
          ChipSelect(
            value: _filter,
            options: [('all', 'All'), ('provisional', 'Provisional'),
              ('thin', 'Thin margin')],
            onChanged: (v) => setState(() => _filter = v),
          ),
          const SizedBox(height: 10),
          if (_canWrite)
            SizedBox(
              height: 34,
              child: FilledButton.icon(
                onPressed: () => _editor(),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New recipe'),
              ),
            ),
          const SizedBox(height: 10),
          SectionCard(
            title: 'Bills of materials',
            children: [
              for (final r in rows.take(100))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Flexible(
                                child: Text(r.menuItemName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontFamily: kFontBody,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: pal.heading)),
                              ),
                              if (r.provisional) ...[
                                const SizedBox(width: 5),
                                Text('EST',
                                    style: TextStyle(
                                        fontFamily: kFontMono,
                                        fontSize: 8.5,
                                        fontWeight: FontWeight.w800,
                                        color: pal.warning)),
                              ],
                            ]),
                            Text(
                                'v${r.version} · ${r.lines.length} lines'
                                ' · cost ${moneyGroup(r.totalCost)}'
                                '${r.price > 0 ? ' · margin ${r.grossMarginPct.toStringAsFixed(0)}%' : ''}',
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 10.5, color: pal.faint)),
                          ],
                        ),
                      ),
                      RowAction('Can make', () => _capacity(r)),
                      const SizedBox(width: 4),
                      RowAction('History', () => _history(r)),
                      if (_canWrite) ...[
                        const SizedBox(width: 4),
                        RowAction('Revise', () => _editor(edit: r)),
                      ],
                    ],
                  ),
                ),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                      child: Text(
                          _isBarista
                              ? 'No drink recipes yet'
                              : 'No recipes yet — stock only moves on counted items',
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

/// One editable ingredient line in the recipe editor.
class _RecipeLineInput {
  final List<InventoryItem> stock;
  final List<UnitRow> units;
  String inventoryId = '';
  final qtyC = TextEditingController();
  String unit = '';
  bool isPackaging = false;

  _RecipeLineInput({required this.stock, required this.units});

  double get qty => double.tryParse(qtyC.text.replaceAll(',', '.')) ?? 0;

  /// Units the server allows for this item's dimension.
  List<String> get allowedUnits {
    final item = stock.where((s) => s.id == inventoryId).firstOrNull;
    if (item == null) return const ['kg', 'g', 'L', 'ml', 'pcs'];
    final dim = units
        .where((u) => u.unit == item.unit)
        .map((u) => u.dimension)
        .firstOrNull;
    if (dim == null || dim.isEmpty) return [item.unit];
    return units.where((u) => u.dimension == dim).map((u) => u.unit).toList();
  }

  Widget build(BuildContext ctx) {
    final pal = Pal.of(ctx);
    final unitOptions = allowedUnits;
    if (unit.isEmpty && unitOptions.isNotEmpty) unit = unitOptions.first;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: pal.sunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: pal.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButton<String>(
            value: inventoryId.isEmpty ? null : inventoryId,
            isExpanded: true,
            underline: const SizedBox(),
            dropdownColor: pal.surface,
            hint: Text('Pick an ingredient…',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 11.5, color: pal.faint)),
            items: [
              for (final s in stock)
                DropdownMenuItem(
                    value: s.id,
                    child: Text('${s.name} (${s.unit} in stock)',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11.5, color: pal.body))),
            ],
            onChanged: (v) {
              inventoryId = v ?? '';
              final item = stock.where((s) => s.id == inventoryId).firstOrNull;
              if (item != null) unit = item.unit;
              (ctx as Element).markNeedsBuild();
            },
          ),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: TextField(
                controller: qtyC,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 11.5, color: pal.body),
                decoration: const InputDecoration(
                    hintText: 'Qty', isDense: true),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 74,
              child: DropdownButton<String>(
                value: unitOptions.contains(unit) ? unit : unitOptions.first,
                isExpanded: true,
                underline: const SizedBox(),
                dropdownColor: pal.surface,
                items: [
                  for (final u in unitOptions)
                    DropdownMenuItem(
                        value: u,
                        child: Text(u,
                            style: TextStyle(
                                fontFamily: kFontMono,
                                fontSize: 11, color: pal.body))),
                ],
                onChanged: (v) {
                  unit = v ?? unit;
                  (ctx as Element).markNeedsBuild();
                },
              ),
            ),
            const SizedBox(width: 6),
            InkWell(
              onTap: () {
                isPackaging = !isPackaging;
                (ctx as Element).markNeedsBuild();
              },
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: isPackaging ? pal.gold.withValues(alpha: 0.15) : pal.surface,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: isPackaging ? pal.gold : pal.border),
                ),
                child: Text('Pkg',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: isPackaging ? pal.goldDark : pal.muted)),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
