/// Purchases — the web `PurchasesView.vue`: record goods received against a
/// supplier (ledger stock-in), pay supplier accounts, the per-line analyse
/// projection and the CSV export. Record/Pay = manager; head-chef and
/// accountant read + export.
library;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../utils/csv.dart';
import '../widgets/backoffice.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

class PurchasesScreen extends StatefulWidget {
  const PurchasesScreen({super.key});

  @override
  State<PurchasesScreen> createState() => _PurchasesScreenState();
}

class _PurchasesScreenState extends State<PurchasesScreen> {
  List<Purchase> _rows = [];
  List<Supplier> _suppliers = [];
  List<InventoryItem> _stock = [];
  bool _loading = true;
  Object? _error;
  bool _unpaidOnly = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _role => context.read<AppState>().roleKey ?? '';
  bool get _canWrite => _role == 'manager';

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final rowsF = app.api.purchases();
      final supF = app.api.suppliers();
      final stockF = app.api.inventory();
      final rows = await rowsF;
      final sups = await supF;
      final stock = await stockF;
      if (!mounted) return;
      setState(() {
        _rows = rows; _suppliers = sups; _stock = stock; _loading = false;
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

  List<Purchase> get _filtered =>
      _unpaidOnly ? _rows.where((p) => p.owing > 0.5).toList() : _rows;

  Future<void> _record() async {
    if (_suppliers.isEmpty) {
      showInfoOn(ScaffoldMessenger.of(context),
          'Add a supplier first — the purchase books against one');
      return;
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final app = context.read<AppState>();
    String supplierId = _suppliers.first.id;
    final dateC = TextEditingController(text: DateRangeRow.fmt(DateTime.now()));
    final totalC = TextEditingController();
    final paidC = TextEditingController(text: '0');
    String method = 'cash';
    final notesC = TextEditingController();
    final lines = <_LineInput>[_LineInput(stock: _stock)];

    await showFormSheet(
      context,
      title: 'Record purchase',
      saveLabel: 'Record',
      body: () => StatefulBuilder(
        builder: (ctx, setSheet) => Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectF(
                  label: 'Supplier',
                  value: supplierId,
                  options: _suppliers.map((s) => s.id).toList(),
                  onChanged: (v) => setSheet(() => supplierId = v),
                ),
                // id dropdowns render raw ids; show names via a builder row.
                Text(
                  'Supplier: ${_suppliers.where((s) => s.id == supplierId).firstOrNull?.name ?? '—'}',
                  style: TextStyle(
                      fontFamily: kFontBody, fontSize: 11, color: Pal.of(ctx).faint),
                ),
                TextF('Date (YYYY-MM-DD)', dateC),
                for (final l in lines) l.build(ctx, setSheet),
                RowAction('+ Add item line',
                    () => setSheet(() => lines.add(_LineInput(stock: _stock)))),
                TextF('Total (ETB)', totalC, numeric: true,
                    hint: 'Defaults to the line sum'),
                TextF('Paid now (ETB)', paidC, numeric: true),
                SelectF(
                    label: 'Payment method', value: method,
                    options: const ['cash', 'card', 'mobile', 'bank', 'credit'],
                    onChanged: (v) => setSheet(() => method = v)),
                TextF('Notes', notesC),
              ],
            ),
          ),
        ),
      ),
      onSave: () async {
        final items = <Map<String, dynamic>>[];
        var lineSum = 0.0;
        for (final l in lines) {
          if (l.inventoryId.isEmpty || l.qty <= 0) continue;
          final cost = l.totalCost;
          lineSum += cost;
          items.add({
            'inventoryId': l.inventoryId,
            'qty': l.qty,
            'unit': l.unit,
            'totalCost': cost,
          });
        }
        if (items.isEmpty) {
          showErrorOn(messenger, ApiError('At least one item line is required'));
          return;
        }
        final total = double.tryParse(totalC.text.replaceAll(',', '.')) ?? lineSum;
        final paid = double.tryParse(paidC.text.replaceAll(',', '.')) ?? 0;
        try {
          await app.api.postPurchase(
            supplierId: supplierId,
            date: dateC.text.trim(),
            items: items,
            total: total,
            paid: paid,
            paymentMethod: method,
            notes: notesC.text.trim(),
          );
          showInfoOn(messenger, 'Purchase recorded — stock updated');
          await _load(quiet: true);
        } catch (e) {
          showErrorOn(messenger, e);
          rethrow;
        }
      },
    );
  }

  Future<void> _pay(Purchase p) async {
    final owingC = TextEditingController(text: p.owing.toStringAsFixed(2));
    String method = 'cash';
    final messenger = ScaffoldMessenger.of(context);
    final app = context.read<AppState>();
    await showFormSheet(
      context,
      title: 'Pay ${p.supplierName}',
      saveLabel: 'Pay',
      body: () => StatefulBuilder(
        builder: (ctx, setSheet) => Column(
          children: [
            Text('Owing: ${money(p.owing)}',
                style: TextStyle(
                    fontFamily: kFontMono, fontSize: 12, color: Pal.of(ctx).warning)),
            const SizedBox(height: 8),
            TextF('Amount (ETB)', owingC, numeric: true),
            SelectF(
                label: 'Method', value: method,
                options: const ['cash', 'card', 'mobile', 'bank'],
                onChanged: (v) => setSheet(() => method = v)),
          ],
        ),
      ),
      onSave: () async {
        final amount = double.tryParse(owingC.text.replaceAll(',', '.')) ?? 0;
        if (amount <= 0) {
          showErrorOn(messenger, ApiError('An amount is required'));
          return;
        }
        try {
          await app.api.payPurchase(p.id, amount, method);
          showInfoOn(messenger, 'Payment recorded');
          await _load(quiet: true);
        } catch (e) {
          showErrorOn(messenger, e);
          rethrow;
        }
      },
    );
  }

  Future<void> _lines(Purchase p) async {
    if (p.lines.isNotEmpty) {
      await _showLines(p);
      return;
    }
    final app = context.read<AppState>();
    try {
      final detail = await app.api.purchaseDetail(p.id);
      if (!mounted) return;
      if (detail != null) _showLines(detail);
    } catch (e) {
      if (!mounted) return;
      showErrorOn(ScaffoldMessenger.of(context), e);
    }
  }

  Future<void> _showLines(Purchase p) async {
    final pal = Pal.of(context);
    await showModalBottomSheet(
      context: context,
      backgroundColor: pal.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Purchase lines — ${p.supplierName}',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 14, fontWeight: FontWeight.w800, color: pal.heading)),
            const SizedBox(height: 8),
            for (final l in p.lines)
              ListRow(
                  head: l.name,
                  rest: '${_fmtQty(l.qty)} ${l.unit}',
                  trailing: money(l.totalCost)),
            if (p.lines.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                    child: Text('No item lines recorded',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11.5, color: pal.faint))),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    final csv = toCsv(
        ['Date', 'Supplier', 'Item', 'Qty', 'Unit', 'Line ETB', 'Total',
         'Paid', 'Method', 'Notes'],
        purchaseRows(_filtered));
    final downloaded = await exportCsv(purchaseExportName(DateTime.now()), csv);
    showInfoOn(messenger,
        downloaded ? 'Purchases downloaded' : 'Copied to clipboard');
  }

  static String _fmtQty(double q) =>
      q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(1);

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
    final total = rows.fold<double>(0, (s, p) => s + p.total);
    final owing = rows.fold<double>(0, (s, p) => s + (p.owing > 0 ? p.owing : 0));

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: KpiCard(label: 'Purchases',
                    value: '${rows.length}',
                    icon: Icons.shopping_basket_outlined)),
            const SizedBox(width: 8),
            Expanded(
                child: KpiCard(label: 'Total', value: money(total),
                    icon: Icons.receipt_long_outlined)),
          ]),
          const SizedBox(height: 8),
          KpiCard(
              label: 'Still owing suppliers',
              value: money(owing),
              valueColor: owing > 0 ? pal.warning : pal.success,
              icon: Icons.account_balance_wallet_outlined),
          const SizedBox(height: 10),
          Row(children: [
            RowAction(
                _unpaidOnly ? 'All' : 'Not fully paid',
                () => setState(() => _unpaidOnly = !_unpaidOnly)),
            const Spacer(),
            RowAction(kIsWeb ? 'Export CSV' : 'Copy CSV', () => _export()),
            if (_canWrite) ...[
              const SizedBox(width: 6),
              FilledButton.icon(
                onPressed: _record,
                icon: const Icon(Icons.add, size: 15),
                label: const Text('Record purchase'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 34),
                    textStyle: const TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 11.5, fontWeight: FontWeight.w700)),
              ),
            ],
          ]),
          const SizedBox(height: 8),
          SectionCard(
            title: 'Goods received',
            children: [
              for (final p in rows.take(100))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(p.supplierName.isEmpty ? '—' : p.supplierName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: pal.heading)),
                            const SizedBox(height: 1),
                            Text(
                                '${dayKey(p.date)}'
                                ' · ${p.lines.isNotEmpty ? '${p.lines.length} lines' : '—'}'
                                ' · paid ${money(p.paid)}',
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 10.5, color: pal.faint)),
                          ],
                        ),
                      ),
                      Text(money(p.total),
                          style: TextStyle(
                              fontFamily: kFontMono,
                              fontSize: 12,
                              fontWeight: FontWeight.w700, color: pal.body)),
                      const SizedBox(width: 8),
                      RowAction('Lines', () => _lines(p)),
                      if (_canWrite && p.owing > 0.5) ...[
                        const SizedBox(width: 4),
                        RowAction('Pay', () => _pay(p), color: pal.primary),
                      ],
                    ],
                  ),
                ),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                      child: Text('No purchases recorded',
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

/// One editable purchase line inside the record sheet.
class _LineInput {
  final List<InventoryItem> stock;
  String inventoryId = '';
  final qtyC = TextEditingController();
  final costC = TextEditingController();

  _LineInput({required this.stock});

  double get qty => double.tryParse(qtyC.text.replaceAll(',', '.')) ?? 0;
  double get totalCost =>
      double.tryParse(costC.text.replaceAll(',', '.')) ?? 0;

  /// The item's own unit — the server fills the line's unit from the
  /// inventory row, so the form only carries the id and quantity.
  String get unit => stock
      .where((s) => s.id == inventoryId)
      .map((s) => s.unit)
      .firstOrNull ?? ''; 

  Widget build(BuildContext ctx, void Function(VoidCallback) setSheet) {
    final pal = Pal.of(ctx);
    final selected = stock.where((s) => s.id == inventoryId).firstOrNull;
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
            hint: Text('Pick a stock item…',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 11.5, color: pal.faint)),
            underline: const SizedBox(),
            dropdownColor: pal.surface,
            items: [
              for (final s in stock)
                DropdownMenuItem(
                    value: s.id,
                    child: Text('${s.name} (${s.unit})',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11.5, color: pal.body))),
            ],
            onChanged: (v) {
              setSheet(() {
                inventoryId = v ?? '';
                if (selected != null && qtyC.text.isEmpty) {
                  // default unit rides the item; cost stays manual
                }
              });
            },
          ),
          Row(children: [
            Expanded(
              child: TextField(
                controller: qtyC,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 11.5, color: pal.body),
                decoration: InputDecoration(
                    hintText: selected?.unit.isEmpty == false
                        ? 'Qty (${selected!.unit})'
                        : 'Qty',
                    isDense: true),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: costC,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 11.5, color: pal.body),
                decoration: const InputDecoration(
                    hintText: 'Line cost ETB', isDense: true),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
