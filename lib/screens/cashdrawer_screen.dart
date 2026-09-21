/// Cash drawer — the cashier's home, from the web `CashDrawerView` +
/// dashboard's till card.
///
/// Today's takings by method (cash / card / Telebirr / CBE / bank), the count
/// of checks still to settle, and the paid orders the till has seen. The
/// drawer-management actions (float, paid-in/out, Z report) stay on the web
/// backoffice; this screen is the floor cashier's live picture.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/roles.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

class CashDrawerScreen extends StatefulWidget {
  final ValueChanged<NavKey>? onNavigate;

  const CashDrawerScreen({super.key, this.onNavigate});

  @override
  State<CashDrawerScreen> createState() => _CashDrawerScreenState();
}

class _CashDrawerScreenState extends State<CashDrawerScreen> {
  DashboardStats? _stats;
  List<FufutOrder> _orders = [];
  bool _loading = true;
  Object? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(minutes: 1), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        app.api.reportsDashboard(),
        app.api.orders(),
      ]);
      if (!mounted) return;
      setState(() {
        _stats = results[0] as DashboardStats;
        _orders = results[1] as List<FufutOrder>;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) {
        await app.sessionExpired();
        return;
      }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _stats == null) return const DashboardSkeleton();
    if (_error != null && _stats == null) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final s = _stats;
    final paid = _orders.where((o) => o.isPaid).toList();
    final openUnpaid = _orders.where((o) => !o.isClosed && !o.isPaid).length;
    final cash = _totalFor(s?.paymentMethods, 'cash');
    final card = _totalFor(s?.paymentMethods, 'card');
    final mobile = _totalFor(s?.paymentMethods, 'mobile') +
        _totalFor(s?.paymentMethods, 'telebirr') +
        _totalFor(s?.paymentMethods, 'cbe') +
        _totalFor(s?.paymentMethods, 'bank');

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: KpiCard(
                label: 'Cash today',
                value: money(cash),
                icon: Icons.payments,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                label: 'Card today',
                value: money(card),
                icon: Icons.credit_card,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: KpiCard(
                label: 'Mobile / Bank',
                value: money(mobile),
                icon: Icons.phone_android,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                label: 'To collect',
                value: '$openUnpaid',
                icon: Icons.hourglass_bottom,
                valueColor: openUnpaid > 0 ? Pal.of(context).warning : null,
                sub: 'open checks',
              ),
            ),
          ]),
          const SizedBox(height: 12),
          if (s != null && s.paymentMethods.isNotEmpty)
            SectionCard(
              title: 'Payment Mix',
              trailing: Text('${s.orders} orders',
                  style: TextStyle(
                      fontFamily: kFontMono,
                      fontSize: 10.5,
                      color: Pal.of(context).faint)),
              children: [
                for (final p in s.paymentMethods.take(6))
                  ListRow(
                    head: _methodLabel(p.method),
                    rest: '${p.count}×',
                    trailing: money(p.total),
                  ),
              ],
            ),
          const SizedBox(height: 10),
          SectionCard(
            title: 'Recent Payments',
            trailing: TextButton(
              onPressed: () => widget.onNavigate?.call(NavKey.openChecks),
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6)),
              child: const Text('Open checks'),
            ),
            children: [
              if (paid.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: Text('No payments recorded yet today',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11.5,
                            color: Pal.of(context).faint)),
                  ),
                )
              else
                for (final o in paid.take(6))
                  ListRow(
                    head: '${shortId(o.id)} · ${o.customer ?? 'Walk-in'}',
                    rest: o.payment,
                    trailing: money(o.total),
                    trailingColor: Pal.of(context).success,
                  ),
            ],
          ),
        ],
      ),
    );
  }

  static double _totalFor(List<PayMethod>? methods, String m) {
    if (methods == null) return 0;
    for (final p in methods) {
      if (p.method.toLowerCase() == m) return p.total;
    }
    return 0;
  }

  static String _methodLabel(String m) {
    switch (m.toLowerCase()) {
      case 'cash': return 'Cash';
      case 'card': return 'Card';
      case 'mobile': return 'Mobile';
      case 'telebirr': return 'Telebirr';
      case 'cbe': return 'CBE Birr';
      case 'bank': return 'Bank';
      default: return m.isEmpty ? 'Other' : m;
    }
  }
}
