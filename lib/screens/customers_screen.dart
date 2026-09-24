/// Customers — the web `CustomersView.vue` (route-only there, a manager tool
/// here): loyalty profiles with points, visits, lifetime spend; add
/// customer and adjust-points flows.
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

class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  List<Customer> _rows = [];
  bool _loading = true;
  Object? _error;
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

  Future<void> _load({bool quiet = false}) async {
    final app = ref.read(appStateProvider);
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final rows = await app.api.customers(query: _search.text.trim());
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

  Future<void> _add() async {
    final messenger = ScaffoldMessenger.of(context);
    final app = ref.read(appStateProvider);
    final nameC = TextEditingController();
    final phoneC = TextEditingController();
    final emailC = TextEditingController();
    final notesC = TextEditingController();
    await showFormSheet(
      context,
      title: 'Add customer',
      body: () => Column(
        children: [
          TextF('Name *', nameC),
          TextF('Phone', phoneC),
          TextF('Email', emailC),
          TextF('Notes', notesC, multiline: true),
        ],
      ),
      onSave: () async {
        if (nameC.text.trim().isEmpty) {
          showErrorOn(messenger, ApiError('A name is required'));
          return;
        }
        try {
          await app.api.postCustomer(
              name: nameC.text, phone: phoneC.text,
              email: emailC.text, notes: notesC.text);
          showInfoOn(messenger, 'Customer added');
          await _load(quiet: true);
        } catch (e) {
          showErrorOn(messenger, e);
          rethrow;
        }
      },
    );
  }

  Future<void> _adjustPoints(Customer c) async {
    final messenger = ScaffoldMessenger.of(context);
    final app = ref.read(appStateProvider);
    final pointsC = TextEditingController();
    final reasonC = TextEditingController();
    await showFormSheet(
      context,
      title: 'Adjust points — ${c.name}',
      saveLabel: 'Apply',
      body: () => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Balance: ${c.points} pts',
              style: TextStyle(
                  fontFamily: kFontMono, fontSize: 12, color: Pal.of(context).muted)),
          const SizedBox(height: 8),
          TextF('Points (+ or −)', pointsC, numeric: true, hint: 'e.g. 50 or -20'),
          TextF('Reason (audited)', reasonC),
        ],
      ),
      onSave: () async {
        final pts = int.tryParse(pointsC.text.trim());
        if (pts == null || pts == 0 || reasonC.text.trim().isEmpty) {
          showErrorOn(messenger,
              ApiError('A non-zero point value and a reason are required'));
          return;
        }
        try {
          final balance = await app.api.adjustCustomerPoints(
              c.id, pts, reasonC.text);
          showInfoOn(messenger, balance != null
              ? 'New balance: $balance pts' : 'Points adjusted');
          await _load(quiet: true);
        } catch (e) {
          showErrorOn(messenger, e);
          rethrow;
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _rows.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _rows.isEmpty) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final pal = Pal.of(context);

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: KpiCard(label: 'Customers',
                    value: '${_rows.length}', icon: Icons.group_outlined)),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                  label: 'Points out',
                  value: '${_rows.fold<int>(0, (s, c) => s + c.points)}',
                  icon: Icons.stars_outlined),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: SearchField(
                  controller: _search,
                  hint: 'Search name or phone, then Enter…',
                  onChanged: (_) {},
                  onSubmitted: () => _load(quiet: true)),
            ),
            const SizedBox(width: 8),
            RowAction('+ Add', () => _add()),
          ]),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Directory',
            children: [
              for (final c in _rows.take(200))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: pal.heading)),
                            const SizedBox(height: 1),
                            Text(
                                '${c.phone.isNotEmpty ? c.phone : 'no phone'}'
                                ' · ${c.visits} visits'
                                '${c.totalSpent > 0 ? ' · ${money(c.totalSpent)} spent' : ''}',
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
                          color: pal.gold.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('${c.points} pts',
                            style: TextStyle(
                                fontFamily: kFontMono,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: pal.goldDark)),
                      ),
                      const SizedBox(width: 6),
                      RowAction('Points', () => _adjustPoints(c)),
                    ],
                  ),
                ),
              if (_rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                      child: Text('No customer profiles yet',
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
