/// Customers — the web `CustomersView.vue` (route-only there, a manager tool
/// here): loyalty profiles with points, visits, lifetime spend; add
/// customer and adjust-points flows.
///
/// The Tier-2 pattern, as done here: the screen's fetch lives in a
/// screen-scoped FutureProvider keyed by its filter (the search text);
/// mutations and pull-to-refresh invalidate; the session is READ inside the
/// provider, never watched (the fetch must not rebuild on its own session
/// echo — see the Riverpod migration notes in worklog).
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

final customersProvider =
    FutureProvider.family<List<Customer>, String>((ref, query) async {
  final app = ref.read(appStateProvider);
  try {
    return await app.api.customers(query: query);
  } on ApiError catch (e) {
    if (e.isAuthError) await app.sessionExpired();
    rethrow;
  }
});

class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _reload() => ref.invalidate(customersProvider(_search.text.trim()));

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
          _reload();
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
          _reload();
        } catch (e) {
          showErrorOn(messenger, e);
          rethrow;
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final rowsAsync = ref.watch(customersProvider(_search.text.trim()));
    final rows = rowsAsync.value ?? const <Customer>[];
    if (rowsAsync.isLoading && rows.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rowsAsync.hasError && rows.isEmpty) {
      return LoadError(error: rowsAsync.error!, onRetry: _reload);
    }
    final pal = Pal.of(context);

    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: KpiCard(label: 'Customers',
                    value: '${rows.length}', icon: Icons.group_outlined)),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                  label: 'Points out',
                  value: '${rows.fold<int>(0, (s, c) => s + c.points)}',
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
                  onSubmitted: () => _reload()),
            ),
            const SizedBox(width: 8),
            RowAction('+ Add', () => _add()),
          ]),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Directory',
            children: [
              for (final c in rows.take(200))
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
              if (rows.isEmpty)
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
