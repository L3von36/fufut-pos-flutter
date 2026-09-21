/// Stock Control — the web `StockControlView.vue` six tabs: reorder, variance,
/// point-in-time snapshot, forecast, production capacity and the physical
/// count sheet. Manager + head-chef only (the web grant).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/backoffice.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

const kCountReasons = [
  'Recount correction', 'Breakage', 'Spoilage', 'Theft / loss',
  'Delivery not recorded', 'Transfer', 'Other',
];

class StockControlScreen extends StatefulWidget {
  const StockControlScreen({super.key});

  @override
  State<StockControlScreen> createState() => _StockControlScreenState();
}

class _StockControlScreenState extends State<StockControlScreen> {
  int _tab = 0;
  bool _loading = true;
  Object? _error;
  String _from = '';
  String _to = '';
  String _snapshotDate = '';

  // Per-tab payloads, loaded on demand and cached.
  List<ReorderRow> _reorder = [];
  List<VarianceRow> _variance = [];
  List<SnapshotRow> _snapshot = [];
  List<ForecastRow> _forecast = [];
  List<CapacityRow> _capacity = [];
  List<InventoryItem> _countSheet = [];
  final Map<String, TextEditingController> _countCtrl = {};

  static const _tabs = [
    ('Reorder', Icons.shopping_cart_outlined),
    ('Variance', Icons.rule_outlined),
    ('As Of', Icons.history_outlined),
    ('Forecast', Icons.trending_down_outlined),
    ('Can Make', Icons.restaurant_outlined),
    ('Count', Icons.fact_check_outlined),
  ];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateRangeRow.fmt(now.add(const Duration(days: -6)));
    _to = DateRangeRow.fmt(now);
    _snapshotDate = DateRangeRow.fmt(now.add(const Duration(days: -1)));
    _loadTab(0);
  }

  @override
  void dispose() {
    for (final c in _countCtrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  String get _fromIso => '${_from}T00:00:00.000Z';
  String get _toIso => '${_to}T23:59:59.999Z';

  Future<void> _loadTab(int tab, {bool quiet = false}) async {
    final app = context.read<AppState>();
    setState(() {
      _tab = tab;
      if (!quiet) { _loading = true; _error = null; }
    });
    try {
      switch (tab) {
        case 0:
          _reorder = await app.api.inventoryReorder();
          break;
        case 1:
          _variance = await app.api.inventoryVariance(_fromIso, _toIso);
          break;
        case 2:
          _snapshot = await app.api.inventorySnapshot(_snapshotDate);
          break;
        case 3:
          _forecast = await app.api.inventoryForecast(_fromIso, _toIso);
          break;
        case 4:
          _capacity = await app.api.inventoryCapacity();
          break;
        case 5:
          _countSheet = await app.api.inventory();
          for (final i in _countSheet) {
            _countCtrl.putIfAbsent(i.id, () => TextEditingController());
          }
          break;
      }
      if (!mounted) return;
      setState(() => _loading = false);
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) { await app.sessionExpired(); return; }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  Future<void> _postCount() async {
    final messenger = ScaffoldMessenger.of(context);
    final app = context.read<AppState>();
    final items = <Map<String, dynamic>>[];
    for (final i in _countSheet) {
      final raw = _countCtrl[i.id]?.text.trim() ?? '';
      if (raw.isEmpty) continue; // blank rows are never treated as zero
      final counted = double.tryParse(raw.replaceAll(',', '.'));
      if (counted == null) continue;
      items.add({'inventoryId': i.id, 'countedQty': counted});
    }
    if (items.isEmpty) {
      showErrorOn(messenger, ApiError('Nothing counted yet — enter at least one item'));
      return;
    }
    final entered = items.length;
    try {
      await app.api.postInventoryCount(items, 'Counted $entered of ${_countSheet.length}');
      showInfoOn(messenger, 'Count posted — stock adjusted');
      await _loadTab(5, quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Column(
      children: [
        // Tab strip — scrollable so all six fit a phone.
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            children: [
              for (var i = 0; i < _tabs.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: InkWell(
                    onTap: () => _loadTab(i),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _tab == i ? pal.primary : pal.surface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: _tab == i ? pal.primary : pal.border),
                      ),
                      child: Row(children: [
                        Icon(_tabs[i].$2,
                            size: 12,
                            color: _tab == i ? Colors.white : pal.muted),
                        const SizedBox(width: 5),
                        Text(_tabs[i].$1,
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: _tab == i ? Colors.white : pal.body)),
                      ]),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? LoadError(error: _error!, onRetry: () => _loadTab(_tab))
                  : RefreshIndicator(
                      onRefresh: () => _loadTab(_tab, quiet: true),
                      child: _body(pal),
                    ),
        ),
      ],
    );
  }

  Widget _body(Pal pal) {
    switch (_tab) {
      case 0:
        return _reorderTab(pal);
      case 1:
        return _varianceTab(pal);
      case 2:
        return _snapshotTab(pal);
      case 3:
        return _forecastTab(pal);
      case 4:
        return _capacityTab(pal);
      default:
        return _countTab(pal);
    }
  }

  Widget _frame({required Widget child, List<Widget> header = const []}) =>
      ListView(
        padding: const EdgeInsets.all(14),
        children: [
          ...header,
          const SizedBox(height: 10),
          child,
        ],
      );

  // ── Tab 1: Reorder ───────────────────────────────────────────────────────

  Widget _reorderTab(Pal pal) {
    final est = _reorder.fold<double>(0, (s, r) => s + r.estCost);
    return _frame(
      header: [
        KpiCard(
            label: 'Estimated restock',
            value: money(est),
            valueColor: pal.warning,
            icon: Icons.shopping_cart_outlined,
            sub: '${_reorder.length} items below their reorder point'),
      ],
      child: SectionCard(
        title: 'The buying list',
        children: [
          for (final r in _reorder.take(150))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.name,
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: pal.heading)),
                        const SizedBox(height: 1),
                        Text(
                            'in stock ${_f(r.stock)} ${r.unit} · reorder at ${_f(r.reorderPoint)}'
                            '${r.preferredSupplier.isNotEmpty ? ' · ${r.preferredSupplier}' : ''}',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 10.5, color: pal.faint)),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: _urgencyColor(pal, r.urgency).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(r.urgency.toUpperCase(),
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: _urgencyColor(pal, r.urgency))),
                  ),
                  const SizedBox(width: 8),
                  Text('buy ${_f(r.suggestedQty)}',
                      style: TextStyle(
                          fontFamily: kFontMono,
                          fontSize: 11,
                          fontWeight: FontWeight.w700, color: pal.body)),
                ],
              ),
            ),
          if (_reorder.isEmpty)
            _empty('Nothing to reorder — stock is above its lines', pal),
        ],
      ),
    );
  }

  Color _urgencyColor(Pal pal, String urgency) {
    switch (urgency.toLowerCase()) {
      case 'now':
      case 'critical':
        return pal.danger;
      case 'soon':
      case 'warning':
        return pal.warning;
      default:
        return pal.success;
    }
  }

  // ── Tab 2: Variance ──────────────────────────────────────────────────────

  Widget _varianceTab(Pal pal) {
    return _frame(
      header: [
        DateRangeRow(
            from: _from, to: _to,
            onFrom: (v) { _from = v; _loadTab(1); },
            onTo: (v) { _to = v; _loadTab(1); }),
      ],
      child: SectionCard(
        title: 'Expected vs actual',
        trailing: Text('a question, not a finding',
            style: TextStyle(
                fontFamily: kFontBody, fontSize: 9.5, color: pal.faint)),
        children: [
          for (final r in _variance.take(150))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.name,
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: pal.heading)),
                        const SizedBox(height: 1),
                        Text(
                            'expected ${_f(r.expected)} → actual ${_f(r.actual)} ${r.unit}'
                            '${r.wasted > 0 ? ' · wasted ${_f(r.wasted)}' : ''}',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 10.5, color: pal.faint)),
                      ],
                    ),
                  ),
                  Text(
                    '${r.variancePct >= 0 ? '+' : ''}${r.variancePct.toStringAsFixed(1)}%',
                    style: TextStyle(
                        fontFamily: kFontMono,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: r.variancePct.abs() > 5
                            ? pal.danger : pal.body),
                  ),
                ],
              ),
            ),
          if (_variance.isEmpty) _empty('No variance data in this range', pal),
        ],
      ),
    );
  }

  // ── Tab 3: Snapshot ──────────────────────────────────────────────────────

  Widget _snapshotTab(Pal pal) {
    return _frame(
      header: [
        Row(children: [
          Text('Stock as of end of day:',
              style: TextStyle(
                  fontFamily: kFontBody, fontSize: 11.5, color: pal.muted)),
          const SizedBox(width: 8),
          DateRangeRow(
              from: _snapshotDate, to: _snapshotDate,
              onFrom: (v) { _snapshotDate = v; _loadTab(2); },
              onTo: (_) {}),
        ]),
      ],
      child: SectionCard(
        title: 'Point-in-time snapshot',
        children: [
          for (final r in _snapshot.take(150))
            ListRow(
                head: r.name,
                rest:
                    '${_f(r.stockThen)} ${r.unit} ${r.basis} · now ${_f(r.stockNow)}'
                    ' · +${_f(r.bought)} −${_f(r.consumed)} (w ${_f(r.wasted)})',
                trailing: r.basis),
          if (_snapshot.isEmpty) _empty('Nothing recorded for that day', pal),
        ],
      ),
    );
  }

  // ── Tab 4: Forecast ──────────────────────────────────────────────────────

  Widget _forecastTab(Pal pal) {
    return _frame(
      header: [
        DateRangeRow(
            from: _from, to: _to,
            onFrom: (v) { _from = v; _loadTab(3); },
            onTo: (v) { _to = v; _loadTab(3); }),
      ],
      child: SectionCard(
        title: 'Days of stock left',
        children: [
          for (final r in _forecast.take(150))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.name,
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: pal.heading)),
                        const SizedBox(height: 1),
                        Text(
                            'uses ${_f(r.dailyUsage)} ${r.unit}/day · ${_f(r.stock)} left'
                            '${(r.stockoutDate ?? '').isNotEmpty ? ' · out ~${r.stockoutDate!.substring(0, 10)}' : ''}',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 10.5, color: pal.faint)),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: r.daysLeft <= 2
                          ? pal.dangerBg
                          : r.daysLeft <= 5 ? pal.warningBg : pal.successBg,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${_f(r.daysLeft)}d',
                      style: TextStyle(
                          fontFamily: kFontMono,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: r.daysLeft <= 2
                              ? pal.danger
                              : r.daysLeft <= 5 ? pal.warning : pal.success),
                    ),
                  ),
                ],
              ),
            ),
          if (_forecast.isEmpty) _empty('Not enough usage history to forecast', pal),
        ],
      ),
    );
  }

  // ── Tab 5: Capacity ──────────────────────────────────────────────────────

  Widget _capacityTab(Pal pal) {
    return _frame(
      child: SectionCard(
        title: 'What can we make right now',
        children: [
          for (final r in _capacity.take(150))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.name,
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: pal.heading)),
                        if (r.limiting.isNotEmpty)
                          Text('limited by ${r.limiting}',
                              style: TextStyle(
                                  fontFamily: kFontBody,
                                  fontSize: 10.5, color: pal.faint)),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: pal.tintBg,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: pal.tintBorder),
                    ),
                    child: Text('${_f(r.servings)} servings',
                        style: TextStyle(
                            fontFamily: kFontMono,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: pal.primary)),
                  ),
                ],
              ),
            ),
          if (_capacity.isEmpty) _empty('No recipe capacity data', pal),
        ],
      ),
    );
  }

  // ── Tab 6: Count sheet ───────────────────────────────────────────────────

  Widget _countTab(Pal pal) {
    final entered = _countSheet
        .where((i) => (_countCtrl[i.id]?.text.trim() ?? '').isNotEmpty)
        .length;
    return _frame(
      header: [
        Row(children: [
          Expanded(
            child: Text('$entered of ${_countSheet.length} entered',
                style: TextStyle(
                    fontFamily: kFontMono, fontSize: 11.5, color: pal.muted)),
          ),
          FilledButton.icon(
            onPressed: _postCount,
            icon: const Icon(Icons.check, size: 15),
            label: const Text('Post count'),
            style: FilledButton.styleFrom(
                minimumSize: const Size(0, 34),
                textStyle: const TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 11.5, fontWeight: FontWeight.w700)),
          ),
        ]),
      ],
      child: SectionCard(
        title: 'Physical count sheet',
        trailing: Text('blank ≠ zero',
            style: TextStyle(
                fontFamily: kFontBody, fontSize: 9.5, color: pal.faint)),
        children: [
          for (final i in _countSheet.take(200))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
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
                        Text('system: ${_f(i.stock)} ${i.unit}',
                            style: TextStyle(
                                fontFamily: kFontMono,
                                fontSize: 10, color: pal.faint)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 92,
                    child: TextField(
                      controller: _countCtrl[i.id],
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      style: TextStyle(
                          fontFamily: kFontMono,
                          fontSize: 12, color: pal.heading),
                      decoration: InputDecoration(
                          hintText: 'counted',
                          isDense: true,
                          filled: true,
                          fillColor: pal.sunken,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 8)),
                    ),
                  ),
                ],
              ),
            ),
          if (_countSheet.isEmpty) _empty('Catalogue is empty', pal),
        ],
      ),
    );
  }

  static Widget _empty(String msg, Pal pal) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
            child: Text(msg,
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 11.5, color: pal.faint))),
      );

  static String _f(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}
