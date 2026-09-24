/// Suppliers — the web `SuppliersView.vue`: the vendor directory with
/// purchase totals / balances, statements, and manager-only create/edit.
/// Everyone else with the grant reads (head-chef, accountant).
///
/// Tier-2: the directory fetch lives in a screen-scoped FutureProvider; the
/// filter chips below are client-side. The session is READ inside the
/// provider, never watched (the fetch must not rebuild on its own echo).
/// Screen-scoped for now — the purchases screen still pulls its own
/// suppliers copy; a shared provider can dedupe the two later.
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

const kSupplierCategories = [
  'Coffee', 'Produce', 'Dairy', 'Meat', 'Bakery', 'Beverages',
  'Packaging', 'Equipment', 'Cleaning', 'Other',
];

final suppliersProvider = FutureProvider<List<Supplier>>((ref) async {
  final app = ref.read(appStateProvider);
  try {
    return await app.api.suppliers();
  } on ApiError catch (e) {
    if (e.isAuthError) await app.sessionExpired();
    rethrow;
  }
});

class SuppliersScreen extends ConsumerStatefulWidget {
  const SuppliersScreen({super.key});

  @override
  ConsumerState<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends ConsumerState<SuppliersScreen> {
  String _filter = 'all';

  String get _role => ref.read(appStateProvider).roleKey ?? '';
  bool get _canWrite => _role == 'manager';

  void _reload() => ref.invalidate(suppliersProvider);

  List<Supplier> _filtered(List<Supplier> all) {
    switch (_filter) {
      case 'owe':
        return all.where((s) => s.balance > 0.5).toList();
      case 'coffee':
        return all.where((s) => s.category == 'Coffee').toList();
      default:
        return all;
    }
  }

  Future<void> _form({Supplier? edit}) async {
    final nameC = TextEditingController(text: edit?.name ?? '');
    String cat = edit?.category.isEmpty == false
        ? edit!.category
        : kSupplierCategories.first;
    final contactC = TextEditingController(text: edit?.contact ?? '');
    final phoneC = TextEditingController(text: edit?.phone ?? '');
    final emailC = TextEditingController(text: edit?.email ?? '');
    final addressC = TextEditingController(text: edit?.address ?? '');
    final suppliesC = TextEditingController(text: edit?.supplies ?? '');
    final messenger = ScaffoldMessenger.of(context);
    final app = ref.read(appStateProvider);
    await showFormSheet(
      context,
      title: edit == null ? 'Add supplier' : 'Edit ${edit.name}',
      body: () => StatefulBuilder(
        builder: (ctx, setSheet) => Column(
          children: [
            TextF('Name *', nameC),
            SelectF(
                label: 'Category', value: cat,
                options: kSupplierCategories,
                onChanged: (v) => setSheet(() => cat = v)),
            TextF('Contact person', contactC),
            TextF('Phone', phoneC),
            TextF('Email', emailC),
            TextF('Address', addressC),
            TextF('Supplies', suppliesC, hint: 'beans, milk, packaging…'),
          ],
        ),
      ),
      onSave: () async {
        if (nameC.text.trim().isEmpty) {
          showErrorOn(messenger, ApiError('A name is required'));
          return;
        }
        final payload = {
          'name': nameC.text.trim(),
          'category': cat,
          'contact': contactC.text.trim(),
          'phone': phoneC.text.trim(),
          'email': emailC.text.trim(),
          'address': addressC.text.trim(),
          'supplies': suppliesC.text.trim(),
        };
        try {
          if (edit == null) {
            await app.api.postSupplier(payload);
          } else {
            await app.api.updateSupplier(edit.id, payload);
          }
          showInfoOn(messenger, edit == null ? 'Supplier added' : 'Supplier updated');
          _reload();
        } catch (e) {
          showErrorOn(messenger, e);
          rethrow;
        }
      },
    );
  }

  Future<void> _statement(Supplier s) async {
    final app = ref.read(appStateProvider);
    final pal = Pal.of(context);
    try {
      final data = await app.api.supplierStatement(s.id);
      if (!mounted) return;
      final totals = (data?['totals'] as Map?) ?? const {};
      final purchases = (data?['purchases'] as List?) ?? const [];
      await showModalBottomSheet(
        context: context,
        backgroundColor: pal.surface,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (ctx) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (ctx, scroll) => Padding(
            // Bottom clears the edge-to-edge gesture nav bar on Android.
            padding: EdgeInsets.fromLTRB(
                16, 16, 16, 16 + MediaQuery.paddingOf(ctx).bottom),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Statement — ${s.name}',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: pal.heading)),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                      child: KpiCard(label: 'Purchases',
                          value: '${totals['count'] ?? purchases.length}')),
                  const SizedBox(width: 8),
                  Expanded(
                      child: KpiCard(label: 'Total',
                          value: money(_asD(totals['total'])))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: KpiCard(label: 'Owing',
                          value: money(_asD(totals['owing'])),
                          valueColor: _asD(totals['owing']) > 0
                              ? pal.warning : pal.success)),
                ]),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView(
                    controller: scroll,
                    children: [
                      for (final p in purchases)
                        Builder(builder: (ctx) {
                          final row = p is Map
                              ? Map<String, dynamic>.from(p)
                              : <String, dynamic>{};
                          return ListRow(
                            head: dayKey(row['date']?.toString()),
                            rest: '${row['items'] ?? ''} items',
                            trailing: money(_asD(row['total'])),
                          );
                        }),
                      if (purchases.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                              child: Text('No purchases on record',
                                  style: TextStyle(
                                      fontFamily: kFontBody,
                                      fontSize: 11.5, color: pal.faint))),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showErrorOn(ScaffoldMessenger.of(context), e);
    }
  }

  static double _asD(dynamic v) =>
      v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

  @override
  Widget build(BuildContext context) {
    final rowsAsync = ref.watch(suppliersProvider);
    final all = rowsAsync.value ?? const <Supplier>[];
    if (rowsAsync.isLoading && all.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rowsAsync.hasError && all.isEmpty) {
      return LoadError(error: rowsAsync.error!, onRetry: _reload);
    }
    final pal = Pal.of(context);
    final rows = _filtered(all);
    final outstanding = all.fold<double>(0, (s, x) => s + (x.balance > 0 ? x.balance : 0));

    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: KpiCard(label: 'Suppliers',
                    value: '${all.length}', icon: Icons.local_shipping_outlined)),
            const SizedBox(width: 8),
            Expanded(
                child: KpiCard(label: 'Outstanding',
                    value: money(outstanding),
                    valueColor: outstanding > 0 ? pal.warning : pal.success,
                    icon: Icons.account_balance_wallet_outlined)),
          ]),
          const SizedBox(height: 10),
          ChipSelect(
            value: _filter,
            options: [('all', 'All'), ('owe', 'We owe money'),
              ('coffee', 'Coffee')],
            onChanged: (v) => setState(() => _filter = v),
          ),
          const SizedBox(height: 10),
          Row(children: [
            const Expanded(child: SizedBox()),
            if (_canWrite) RowAction('+ Add supplier', () => _form()),
          ]),
          const SizedBox(height: 8),
          SectionCard(
            title: 'Directory',
            children: [
              for (final s in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: pal.heading)),
                            const SizedBox(height: 1),
                            Text(
                                '${s.category}${s.contact.isNotEmpty ? ' · ${s.contact}' : ''}'
                                '${s.phone.isNotEmpty ? ' · ${s.phone}' : ''}',
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 10.5, color: pal.faint)),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(money(s.total),
                              style: TextStyle(
                                  fontFamily: kFontMono,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: pal.body)),
                          if (s.balance > 0.5)
                            Text('owes ${money(s.balance)}',
                                style: TextStyle(
                                    fontFamily: kFontMono,
                                    fontSize: 9.5,
                                    color: pal.warning)),
                        ],
                      ),
                      const SizedBox(width: 8),
                      RowAction('Statement', () => _statement(s)),
                      if (_canWrite) ...[
                        const SizedBox(width: 4),
                        RowAction('Edit', () => _form(edit: s)),
                      ],
                    ],
                  ),
                ),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                      child: Text('No suppliers',
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
