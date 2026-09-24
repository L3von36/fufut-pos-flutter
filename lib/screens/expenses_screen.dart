/// Expenses — the manager / accountant ledger, from the web
/// `ExpensesView.vue`: category + date-range filters, category summary
/// cards, full CRUD (the accountant's only write grant server-side) and a
/// printable record.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../utils/csv.dart';
import '../widgets/backoffice.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

const kExpenseCategories = [
  'Utilities', 'Rent', 'Salaries', 'Supplies', 'Maintenance', 'Marketing',
  'Transport', 'Taxes & Fees', 'Misc',
];

/// The whole ledger. The category / date-range / search filters are applied
/// client-side (the endpoint takes none), so one unparameterized fetch
/// serves every view of the screen.
final expensesProvider = FutureProvider<List<Expense>>((ref) async {
  // Read, never watch: the fetch must not rebuild on its own session echo.
  final app = ref.read(appStateProvider);
  try {
    return await app.api.expenses();
  } on ApiError catch (e) {
    if (e.isAuthError) await app.sessionExpired();
    rethrow;
  }
});

class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key});

  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends ConsumerState<ExpensesScreen> {
  String _category = 'All';
  String _from = '';
  String _to = '';
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateRangeRow.fmt(now.add(const Duration(days: -30)));
    _to = DateRangeRow.fmt(now);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _canWrite =>
      const {'manager', 'accountant'}.contains(
          ref.read(appStateProvider).roleKey);

  void _reload() => ref.invalidate(expensesProvider);

  List<Expense> _filtered(List<Expense> all) {
    final q = _search.text.trim().toLowerCase();
    return all.where((e) {
      if (_category != 'All' && e.category != _category) return false;
      final d = dayKey(e.date);
      if (_from.isNotEmpty && d.isNotEmpty && d.compareTo(_from) < 0) return false;
      if (_to.isNotEmpty && d.isNotEmpty && d.compareTo(_to) > 0) return false;
      if (q.isNotEmpty &&
          !e.description.toLowerCase().contains(q) &&
          !e.category.toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) => (b.date ?? '').compareTo(a.date ?? ''));
  }

  Map<String, double> _byCategory(List<Expense> filtered) {
    final map = <String, double>{};
    for (final e in filtered) {
      map[e.category] = (map[e.category] ?? 0) + e.amount;
    }
    final entries = map.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Map.fromEntries(entries);
  }

  Future<void> _form({Expense? edit}) async {
    final catC = TextEditingController(text: edit?.category ?? kExpenseCategories.first);
    final descC = TextEditingController(text: edit?.description ?? '');
    final amountC = TextEditingController(
        text: edit != null && edit.amount > 0 ? edit.amount.toStringAsFixed(2) : '');
    final dateC = TextEditingController(text: dayKey(edit?.date).isEmpty
        ? DateRangeRow.fmt(DateTime.now())
        : dayKey(edit?.date));
    final messenger = ScaffoldMessenger.of(context);
    final app = ref.read(appStateProvider);
    await showFormSheet(
      context,
      title: edit == null ? 'Add expense' : 'Edit expense',
      body: () => Column(
        children: [
          SelectF(
              label: 'Category',
              value: catC.text,
              options: kExpenseCategories,
              onChanged: (v) => catC.text = v),
          TextF('Description', descC, hint: 'What was bought / paid for'),
          TextF('Amount (ETB)', amountC, numeric: true),
          TextF('Date (YYYY-MM-DD)', dateC),
        ],
      ),
      onSave: () async {
        final amount = double.tryParse(amountC.text.replaceAll(',', '.')) ?? 0;
        if (amount <= 0) {
          showErrorOn(messenger, ApiError('Amount must be greater than zero'));
          return;
        }
        try {
          if (edit == null) {
            await app.api.postExpense(
                category: catC.text,
                description: descC.text,
                amount: amount,
                date: dateC.text.trim());
          } else {
            await app.api.updateExpense(edit.id, {
              'category': catC.text,
              'description': descC.text.trim(),
              'amount': amount,
              'date': dateC.text.trim(),
            });
          }
          showInfoOn(messenger, edit == null ? 'Expense recorded' : 'Expense updated');
          _reload();
        } catch (e) {
          showErrorOn(messenger, e);
          rethrow;
        }
      },
    );
  }

  Future<void> _delete(Expense e) async {
    final messenger = ScaffoldMessenger.of(context);
    final app = ref.read(appStateProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete expense?'),
        content: Text('${e.category} — ${money(e.amount)}\nThis cannot be undone.'),
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
      await app.api.deleteExpense(e.id);
      showInfoOn(messenger, 'Expense deleted');
      _reload();
    } catch (err) {
      showErrorOn(messenger, err);
    }
  }

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    final rows = _filtered(
            ref.read(expensesProvider).value ?? const <Expense>[])
        .map((e) => [dayKey(e.date), e.category,
            e.description, e.amount.toStringAsFixed(2)])
        .toList();
    final csv = toCsv(['Date', 'Category', 'Description', 'ETB'], rows);
    final downloaded = await exportCsv('expenses.csv', csv);
    showInfoOn(messenger,
        downloaded ? 'expenses.csv downloaded' : 'Copied to clipboard');
  }

  @override
  Widget build(BuildContext context) {
    final rowsAsync = ref.watch(expensesProvider);
    final all = rowsAsync.value ?? const <Expense>[];
    if (rowsAsync.isLoading && all.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rowsAsync.hasError && all.isEmpty) {
      return LoadError(error: rowsAsync.error!, onRetry: _reload);
    }
    final pal = Pal.of(context);
    final rows = _filtered(all);
    final total = rows.fold<double>(0, (s, e) => s + e.amount);
    final byCat = _byCategory(rows);

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
                  label: 'Total (range)', value: money(total),
                  icon: Icons.account_balance_wallet_outlined),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                  label: 'Entries', value: '${rows.length}',
                  icon: Icons.receipt_long_outlined),
            ),
          ]),
          const SizedBox(height: 10),
          SearchField(
              controller: _search,
              hint: 'Search description…',
              onChanged: (_) => setState(() {})),
          const SizedBox(height: 8),
          ChipSelect(
            value: _category,
            options: [('All', 'All categories'),
              ...kExpenseCategories.map((c) => (c, c))],
            onChanged: (v) => setState(() => _category = v),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: DateRangeRow(
                  from: _from, to: _to,
                  onFrom: (v) => setState(() => _from = v),
                  onTo: (v) => setState(() => _to = v)),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            if (_canWrite)
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: FilledButton.icon(
                    onPressed: () => _form(),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add expense'),
                  ),
                ),
              ),
            if (_canWrite) const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 34,
                child: OutlinedButton.icon(
                  onPressed: _export,
                  icon: const Icon(Icons.download_outlined, size: 16),
                  label: const Text('Export CSV'),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          if (byCat.isNotEmpty)
            SectionCard(
              title: 'By category',
              children: [
                for (final e in byCat.entries.take(6))
                  ListRow(
                      head: e.key,
                      trailing: money(e.value),
                      trailingColor: pal.warning),
              ],
            ),
          const SizedBox(height: 10),
          SectionCard(
            title: 'Ledger',
            trailing: Text('${rows.length}',
                style: TextStyle(
                    fontFamily: kFontMono, fontSize: 10.5, color: pal.faint)),
            children: [
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: Text('No expenses in this range',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11.5, color: pal.faint)),
                  ),
                )
              else
                for (final e in rows.take(100))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e.description.isEmpty ? e.category : e.description,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontFamily: kFontBody,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: pal.heading)),
                              const SizedBox(height: 1),
                              Text(
                                  '${e.category} · ${dayKey(e.date).isEmpty ? '—' : dayKey(e.date)}'
                                  '${e.createdBy != null ? ' · ${e.createdBy}' : ''}',
                                  style: TextStyle(
                                      fontFamily: kFontBody,
                                      fontSize: 10.5, color: pal.faint)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(money(e.amount),
                            style: TextStyle(
                                fontFamily: kFontMono,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: pal.warning)),
                        if (_canWrite) ...[
                          const SizedBox(width: 8),
                          RowAction('Edit', () => _form(edit: e)),
                          const SizedBox(width: 4),
                          AsyncRowAction('Del', () => _delete(e),
                              color: pal.danger),
                        ],
                      ],
                    ),
                  ),
            ],
          ),
        ],
      ),
    );
  }
}
