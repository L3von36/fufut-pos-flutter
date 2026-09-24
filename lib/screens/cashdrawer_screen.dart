/// Cash drawer — the cashier's home, from the web `CashDrawerView`, native.
///
/// The till's full shift lifecycle, not just a read-out:
///  * Open the drawer with a float (`POST /api/cashdrawer/open`).
///  * Live float card — opening float, cash sales, paid in/out, expected.
///  * Paid-in / paid-out with a reason, pop the drawer.
///  * Close with a blind denomination count (200/100/50/20/10/5 ETB), live
///    reconciliation and the same >20% variance guard the web shows.
///  * Z-report per closed drawer (`GET /api/cashdrawer/:id/z-report`).
///  * Shift audit log (`GET /api/cashdrawer/shift-log`).
///
/// Above the drawer itself sit the day's takings KPIs (cash / card / mobile)
/// and the payment mix — the floor cashier's live picture, unchanged.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/roles.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

class CashDrawerScreen extends ConsumerStatefulWidget {
  final ValueChanged<NavKey>? onNavigate;

  const CashDrawerScreen({super.key, this.onNavigate});

  @override
  ConsumerState<CashDrawerScreen> createState() => _CashDrawerScreenState();
}

class _CashDrawerScreenState extends ConsumerState<CashDrawerScreen> {
  DashboardStats? _stats;
  CashDrawerState? _drawer;
  List<DrawerSession> _history = [];
  List<ShiftLogEntry> _shiftLog = [];
  bool _loading = true;
  bool _showHistory = false;
  Object? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 45), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final app = ref.read(appStateProvider);
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        app.api.reportsDashboard(),
        app.api.cashdrawer(),
        app.api.cashdrawerHistory(),
        app.api.cashdrawerShiftLog(),
      ]);
      if (!mounted) return;
      setState(() {
        _stats = results[0] as DashboardStats;
        _drawer = results[1] as CashDrawerState;
        _history = results[2] as List<DrawerSession>;
        _shiftLog = results[3] as List<ShiftLogEntry>;
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

  // ── Drawer operations ─────────────────────────────────────────────────────

  Future<void> _openDrawerFlow() async {
    final amount = await _promptOpenDrawer();
    if (amount == null || !mounted) return;
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.openDrawer(amount);
      showInfoOn(messenger, 'Drawer opened with ${money(amount)} float');
      app.refreshTill(); // the whole app's service gates flip with the till
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Future<void> _closeDrawerFlow(DrawerSession active) async {
    final result = await _promptCloseDrawer(active);
    if (result == null || !mounted) return;
    final (closingBal, denoms) = result;
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.closeDrawer(active.id, closingBal, denoms);
      final variance = closingBal - active.expected;
      showInfoOn(messenger,
          'Drawer closed — counted ${money(closingBal)}, variance ${money(variance)}');
      app.refreshTill(); // ordering and settlement gates close with it
      // Z-report right after close, like the web's flow.
      await _showZReport(active.id);
      await _load(quiet: true);
    } on ApiError catch (e) {
      if (e.isAuthError && mounted) {
        await app.sessionExpired();
        return;
      }
      showErrorOn(messenger, e);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Future<void> _paidInOutFlow() async {
    final result = await _promptPaidInOut();
    if (result == null || !mounted) return;
    final (kind, amount, reason) = result;
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (kind == 'in') {
        await app.api.paidIn(amount, reason);
      } else {
        await app.api.paidOut(amount, reason);
      }
      showInfoOn(messenger,
          '${kind == 'in' ? 'Paid in' : 'Paid out'} ${money(amount)} — $reason');
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Future<void> _popFlow() async {
    final reason = await _promptPop();
    if (reason == null || !mounted) return;
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.popDrawer(reason);
      showInfoOn(messenger, 'Drawer popped');
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Future<void> _showZReport(String drawerId) async {
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final z = await app.api.zReport(drawerId);
      if (!mounted) return;
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Pal.of(context).surface,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        constraints: BoxConstraints(
            maxWidth: 680,
            maxHeight: MediaQuery.sizeOf(context).height * 0.9),
        builder: (_) => _ZReportSheet(z: z),
      );
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  // ── Prompts ───────────────────────────────────────────────────────────────

  Future<double?> _promptOpenDrawer() {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    return showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Pal.of(context).surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SheetHandle(),
                  const SizedBox(height: 8),
                  Text('Open Drawer',
                      style: T.screenTitle.copyWith(
                          color: Pal.of(ctx).heading)),
                  const SizedBox(height: 2),
                  Text('Count the opening float into the till.',
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 11.5,
                          color: Pal.of(ctx).muted)),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                          RegExp(r'^\d*\.?\d{0,2}')),
                    ],
                    decoration: InputDecoration(
                      labelText: 'Opening float (ETB)',
                      prefixText: 'ETB ',
                      labelStyle: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 12,
                          color: Pal.of(ctx).muted),
                    ),
                    style: TextStyle(
                        fontFamily: kFontMono,
                        fontSize: 15,
                        color: Pal.of(ctx).heading),
                    validator: (v) =>
                        (double.tryParse(v ?? '') ?? -1) < 0
                            ? 'Enter the float amount'
                            : null,
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final q in const [500.0, 1000.0, 1500.0, 2000.0])
                        ActionChip(
                          label: Text(money(q),
                              style: TextStyle(
                                  fontFamily: kFontMono,
                                  fontSize: 11,
                                  color: Pal.of(ctx).body)),
                          onPressed: () =>
                              controller.text = q.toStringAsFixed(0),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 40,
                    child: FilledButton.icon(
                      onPressed: () {
                        if (formKey.currentState!.validate()) {
                          Navigator.pop(ctx, double.parse(controller.text));
                        }
                      },
                      icon: const Icon(Icons.lock_open, size: 17),
                      label: const Text('Open Drawer'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The blind Z-count: six note denominations, counted total recalculated
  /// live, expected vs variance preview, >20% guard.
  Future<(double, Map<String, int>)?> _promptCloseDrawer(
      DrawerSession active) {
    final controllers = {
      for (final d in const [200, 100, 50, 20, 10, 5])
        d: TextEditingController(),
    };
    final formKey = GlobalKey<FormState>();
    final pal0 = Pal.of(context);

    return showModalBottomSheet<(double, Map<String, int>)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: pal0.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          int notesOf(int d) =>
              int.tryParse(controllers[d]!.text) ?? 0;
          double counted() =>
              controllers.keys
                  .fold(0.0, (s, d) => s + (notesOf(d) * d).toDouble());
          final variance = counted() - active.expected;
          final pct = active.expected > 0
              ? (variance.abs() / active.expected * 100)
              : 0.0;
          final bigVariance = pct > 20;

          return Padding(
            padding:
                EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Form(
                  key: formKey,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SheetHandle(),
                        const SizedBox(height: 8),
                        Text('Count Cash & Close',
                            style: T.screenTitle.copyWith(
                                color: Pal.of(ctx).heading)),
                        const SizedBox(height: 2),
                        Text(
                            'Blind count: count the notes, the app does the math.',
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 11.5,
                                color: Pal.of(ctx).muted)),
                        const SizedBox(height: 14),
                        // Denomination grid — note value left, count field right.
                        for (final d in controllers.keys)
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 64,
                                  child: Text('$d ETB',
                                      style: TextStyle(
                                          fontFamily: kFontMono,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          color: Pal.of(ctx).heading)),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: TextFormField(
                                    controller: controllers[d],
                                    autofocus: d == 200,
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [
                                      FilteringTextInputFormatter
                                          .digitsOnly,
                                    ],
                                    onChanged: (_) => setSheet(() {}),
                                    decoration: InputDecoration(
                                      hintText: '0 notes',
                                      isDense: true,
                                      labelStyle: TextStyle(
                                          fontFamily: kFontBody,
                                          fontSize: 11,
                                          color: Pal.of(ctx).muted),
                                    ),
                                    style: TextStyle(
                                        fontFamily: kFontMono,
                                        fontSize: 14,
                                        color: Pal.of(ctx).heading),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                SizedBox(
                                  width: 88,
                                  child: Text(
                                    money((notesOf(d) * d).toDouble()),
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                        fontFamily: kFontMono,
                                        fontSize: 12,
                                        color: Pal.of(ctx).muted),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const Divider(height: 18),
                        _reconRow(ctx, 'Counted', counted(),
                            bold: true),
                        _reconRow(ctx, 'Opening float', active.openingBal),
                        _reconRow(ctx, 'Cash sales', active.cashSales),
                        if (active.paidIn > 0)
                          _reconRow(ctx, 'Paid in', active.paidIn),
                        if (active.paidOut > 0)
                          _reconRow(ctx, 'Paid out', -active.paidOut),
                        _reconRow(ctx, 'Expected', active.expected, bold: true),
                        const Divider(height: 18),
                        _reconRow(ctx, 'Net variance', variance,
                            bold: true,
                            color: variance == 0
                                ? Pal.of(ctx).success
                                : (variance > 0
                                    ? Pal.of(ctx).info
                                    : Pal.of(ctx).danger)),
                        if (bigVariance)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Pal.of(ctx).dangerBg,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: Pal.of(ctx).dangerBorder),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.warning_amber_rounded,
                                      size: 16, color: Pal.of(ctx).danger),
                                  const SizedBox(width: 7),
                                  Expanded(
                                    child: Text(
                                        'Variance is ${pct.toStringAsFixed(0)}% of expected — recount before closing.',
                                        style: TextStyle(
                                            fontFamily: kFontBody,
                                            fontSize: 11,
                                            color: Pal.of(ctx).danger)),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(height: 14),
                        SizedBox(
                          height: 40,
                          child: FilledButton.icon(
                            onPressed: () {
                              if (counted() <= 0) {
                                showError(
                                    ctx, ApiError('Count at least one note'));
                                return;
                              }
                              Navigator.pop(
                                  ctx,
                                  (
                                    counted(),
                                    {
                                      for (final e in controllers.entries)
                                        '${e.key}': int.tryParse(e.value.text) ?? 0,
                                    }
                                  ));
                            },
                            icon: const Icon(Icons.lock, size: 17),
                            label: const Text('Close Drawer (Z-Count)'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _reconRow(BuildContext ctx, String label, double value,
      {bool bold = false, Color? color}) {
    final pal = Pal.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label,
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 12,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                  color: pal.muted)),
          const Spacer(),
          Text(money(value),
              style: T.mono.copyWith(
                  fontSize: bold ? 13.5 : 12,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                  color: color ?? pal.body)),
        ],
      ),
    );
  }

  Future<(String, double, String)?> _promptPaidInOut() {
    final amount = TextEditingController();
    final reason = TextEditingController();
    String kind = 'in';
    final formKey = GlobalKey<FormState>();
    final pal0 = Pal.of(context);

    return showModalBottomSheet<(String, double, String)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: pal0.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SheetHandle(),
                    const SizedBox(height: 8),
                    Text('Paid In / Out',
                        style: T.screenTitle.copyWith(
                            color: Pal.of(ctx).heading)),
                    const SizedBox(height: 12),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'in', label: Text('Paid In')),
                        ButtonSegment(value: 'out', label: Text('Paid Out')),
                      ],
                      selected: {kind},
                      onSelectionChanged: (s) => setSheet(() => kind = s.first),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: amount,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'^\d*\.?\d{0,2}')),
                      ],
                      decoration: const InputDecoration(
                          labelText: 'Amount (ETB)', prefixText: 'ETB '),
                      style: TextStyle(
                          fontFamily: kFontMono,
                          fontSize: 15,
                          color: Pal.of(ctx).heading),
                      validator: (v) =>
                          (double.tryParse(v ?? '') ?? 0) <= 0
                              ? 'Enter an amount'
                              : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: reason,
                      decoration: const InputDecoration(
                          labelText: 'Reason (required)'),
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 13,
                          color: Pal.of(ctx).heading),
                      validator: (v) => (v ?? '').trim().isEmpty
                          ? 'Say why the drawer moves'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 40,
                      child: FilledButton.icon(
                        onPressed: () {
                          if (formKey.currentState!.validate()) {
                            Navigator.pop(
                                ctx,
                                (
                                  kind,
                                  double.parse(amount.text),
                                  reason.text.trim()
                                ));
                          }
                        },
                        icon: Icon(kind == 'in'
                            ? Icons.add_card
                            : Icons.remove_circle_outline),
                        label: Text(kind == 'in'
                            ? 'Record Paid In'
                            : 'Record Paid Out'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<String?> _promptPop() {
    final reason = TextEditingController();
    final pal0 = Pal.of(context);
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: pal0.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SheetHandle(),
                const SizedBox(height: 8),
                Text('Pop Drawer',
                    style:
                        T.screenTitle.copyWith(color: Pal.of(ctx).heading)),
                const SizedBox(height: 2),
                Text('Open the physical drawer for change or a tip-out.',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 11.5,
                        color: Pal.of(ctx).muted)),
                const SizedBox(height: 12),
                TextField(
                  controller: reason,
                  autofocus: true,
                  decoration:
                      const InputDecoration(labelText: 'Reason (required)'),
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 13,
                      color: Pal.of(ctx).heading),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  height: 40,
                  child: FilledButton.icon(
                    onPressed: () {
                      if (reason.text.trim().isNotEmpty) {
                        Navigator.pop(ctx, reason.text.trim());
                      }
                    },
                    icon: const Icon(Icons.door_sliding_outlined),
                    label: const Text('Pop Drawer'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading && _stats == null) return const DashboardSkeleton();
    if (_error != null && _stats == null) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final s = _stats;
    final pal = Pal.of(context);
    final active = _drawer?.active;

    final cash = _totalFor(s?.paymentMethods, 'cash');
    final card = _totalFor(s?.paymentMethods, 'card');
    final mobile = _totalFor(s?.paymentMethods, 'mobile') +
        _totalFor(s?.paymentMethods, 'telebirr') +
        _totalFor(s?.paymentMethods, 'cbe') +
        _totalFor(s?.paymentMethods, 'bank');

    final todaysDrawers = _drawer?.drawers ?? const <DrawerSession>[];
    final closedToday = todaysDrawers
        .where((d) => d.status == 'closed' && (d.closed ?? '').startsWith(
            DateTime.now().toString().substring(0, 10)))
        .toList();
    final closedCash = closedToday.fold<double>(0, (s, d) => s + d.cashSales);
    final closedVar = closedToday.fold<double>(0, (s, d) => s + d.variance);

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          // ── Action row — the shift lifecycle ────────────────────────────
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (active == null)
                SizedBox(
                  height: 34,
                  child: FilledButton.icon(
                    onPressed: _openDrawerFlow,
                    icon: const Icon(Icons.lock_open, size: 16),
                    label: const Text('Open Drawer',
                        style: TextStyle(fontSize: 12)),
                  ),
                )
              else ...[
                SizedBox(
                  height: 34,
                  child: FilledButton.icon(
                    onPressed: () => _closeDrawerFlow(active),
                    style: FilledButton.styleFrom(backgroundColor: pal.danger),
                    icon: const Icon(Icons.lock, size: 16),
                    label: const Text('Close (Z-Count)',
                        style: TextStyle(fontSize: 12)),
                  ),
                ),
                SizedBox(
                  height: 34,
                  child: OutlinedButton.icon(
                    onPressed: _paidInOutFlow,
                    icon: const Icon(Icons.swap_vert, size: 16),
                    label: const Text('Paid In / Out',
                        style: TextStyle(fontSize: 12)),
                  ),
                ),
                SizedBox(
                  height: 34,
                  child: OutlinedButton.icon(
                    onPressed: _popFlow,
                    icon: const Icon(Icons.door_sliding_outlined, size: 16),
                    label: const Text('Pop Drawer',
                        style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          // ── Active drawer card ──────────────────────────────────────────
          _activeDrawerCard(active),
          const SizedBox(height: 12),
          // ── Day takings KPIs ────────────────────────────────────────────
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
                value: '${_drawer?.drawers.length ?? 0}',
                icon: Icons.hourglass_bottom,
                sub: 'drawer sessions today',
              ),
            ),
          ]),
          const SizedBox(height: 12),
          // ── Drawers: today / history tabs ───────────────────────────────
          SectionCard(
            title: _showHistory ? 'Drawer History' : "Today's Drawers",
            trailing: TextButton(
              onPressed: () => setState(() => _showHistory = !_showHistory),
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6)),
              child: Text(_showHistory ? 'Today' : 'History'),
            ),
            children: [
              if (!_showHistory) ...[
                Row(children: [
                  Expanded(
                    child: KpiCard(
                        label: 'Closed shifts',
                        value: '${closedToday.length}',
                        icon: Icons.point_of_sale),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: KpiCard(
                        label: 'Cash banked',
                        value: money(closedCash),
                        icon: Icons.savings_outlined),
                  ),
                ]),
                const SizedBox(height: 8),
                KpiCard(
                  label: 'Variance across closed shifts',
                  value: money(closedVar),
                  icon: Icons.balance,
                  valueColor: closedVar == 0
                      ? pal.success
                      : (closedVar > 0 ? pal.info : pal.danger),
                ),
                const SizedBox(height: 4),
                _drawerTable(todaysDrawers, showVariance: true),
              ] else
                _drawerTable(_history, showVariance: true),
            ],
          ),
          const SizedBox(height: 10),
          // ── Shift audit ─────────────────────────────────────────────────
          if (_shiftLog.isNotEmpty) _shiftLogCard(),
          const SizedBox(height: 10),
          if (s != null && s.paymentMethods.isNotEmpty) _paymentMix(s),
          const SizedBox(height: 10),
          _recentPayments(),
        ],
      ),
    );
  }

  Widget _activeDrawerCard(DrawerSession? active) {
    final pal = Pal.of(context);
    final open = active != null;
    return SectionCard(
      title: 'Active Drawer',
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: open ? pal.success : pal.faint),
        ),
        const SizedBox(width: 5),
        Text(open ? 'OPEN' : 'CLOSED',
            style: TextStyle(
                fontFamily: kFontMono,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: open ? pal.success : pal.faint,
                letterSpacing: 0.6)),
      ]),
      children: [
        if (!open)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(
              children: [
                Icon(Icons.lock_outline, size: 26, color: pal.faint),
                const SizedBox(height: 8),
                Text('No drawer open — count a float to start the shift',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 11.5,
                        color: pal.muted)),
              ],
            ),
          )
        else ...[
          Row(children: [
            Expanded(
              child: KpiCard(
                label: 'Opening Float',
                value: money(active.openingBal),
                icon: Icons.account_balance_wallet_outlined,
                sub: 'opened ${_hhmm(active.opened)}',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                label: 'Cash Sales',
                value: money(active.cashSales),
                icon: Icons.point_of_sale,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: KpiCard(
                label: 'Paid In / Out',
                value:
                    '${money(active.paidIn)} / ${money(active.paidOut)}',
                icon: Icons.swap_vert,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: KpiCard(
                label: 'Expected',
                value: money(active.expected),
                icon: Icons.fact_check_outlined,
                valueColor: pal.primary,
                sub: 'float + sales + in − out',
              ),
            ),
          ]),
        ],
      ],
    );
  }

  Widget _drawerTable(List<DrawerSession> rows, {bool showVariance = false}) {
    final pal = Pal.of(context);
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: Text('No drawer sessions yet',
              style: TextStyle(
                  fontFamily: kFontBody, fontSize: 11.5, color: pal.faint)),
        ),
      );
    }
    return Column(
      children: [
        for (final d in rows.take(12))
          Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              border:
                  Border(bottom: BorderSide(color: pal.border, width: 0.5)),
            ),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: d.status == 'open' ? pal.success : pal.faint),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Drawer ${shortId(d.id)} · ${_hhmm(d.opened)}–${d.status == 'open' ? 'now' : _hhmm(d.closed)}',
                        style: TextStyle(
                            fontFamily: kFontMono,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: pal.heading),
                      ),
                      Text(
                        'float ${money(d.openingBal)} · sales ${money(d.cashSales)} · counted ${money(d.closingBal)}',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 10.5,
                            color: pal.muted),
                      ),
                    ],
                  ),
                ),
                if (showVariance)
                  Text(
                    d.status == 'open' ? 'open' : money(d.variance),
                    style: TextStyle(
                        fontFamily: kFontMono,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: d.status == 'open'
                            ? pal.success
                            : (d.variance == 0
                                ? pal.success
                                : (d.variance > 0 ? pal.info : pal.danger))),
                  ),
                if (d.status == 'closed') ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 28,
                    child: OutlinedButton(
                      onPressed: () => _showZReport(d.id),
                      style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          textStyle: const TextStyle(fontSize: 10.5)),
                      child: const Text('Z'),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _shiftLogCard() {
    final pal = Pal.of(context);
    return SectionCard(
      title: 'Shift Activity',
      trailing: Icon(Icons.history, size: 15, color: pal.faint),
      children: [
        for (final e in _shiftLog.take(8))
          ListRow(
            head: e.action,
            rest: [if (e.reason.isNotEmpty) e.reason, e.actorName]
                .where((p) => p.isNotEmpty)
                .join(' · '),
            trailing: _hhmm(e.at),
          ),
      ],
    );
  }

  Widget _paymentMix(DashboardStats? s) {
    if (s == null || s.paymentMethods.isEmpty) return const SizedBox.shrink();
    return SectionCard(
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
    );
  }

  Widget _recentPayments() {
    final pal = Pal.of(context);
    final app = ref.read(appStateProvider);
    final paid = app.roleKey == 'cashier' || app.roleKey == 'manager';
    if (!paid) return const SizedBox.shrink();
    return FutureBuilder<List<FufutOrder>>(
      future: app.api.orders(),
      builder: (context, snap) {
        final paidOrders =
            (snap.data ?? const <FufutOrder>[]).where((o) => o.isPaid).toList();
        return SectionCard(
          title: 'Recent Payments',
          trailing: TextButton(
            onPressed: () => widget.onNavigate?.call(NavKey.openChecks),
            style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6)),
            child: const Text('Open checks'),
          ),
          children: [
            if (snap.connectionState != ConnectionState.done)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              )
            else if (paidOrders.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: Text('No payments recorded yet today',
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 11.5,
                          color: pal.faint)),
                ),
              )
            else
              for (final o in paidOrders.take(6))
                ListRow(
                  head: '${shortId(o.id)} · ${o.customer ?? 'Walk-in'}',
                  rest: o.payment,
                  trailing: money(o.total),
                  trailingColor: pal.success,
                ),
          ],
        );
      },
    );
  }

  static String _hhmm(String? stamp) {
    if (stamp == null || stamp.isEmpty) return '—';
    final t = DateTime.tryParse(stamp);
    if (t == null) return stamp.length > 5 ? stamp.substring(0, 5) : stamp;
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${two(t.hour)}:${two(t.minute)}';
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

// ─────────────────────────────────────────────────────────────────────────────
// Z-report sheet — the fiscal close-out of one drawer session.
// ─────────────────────────────────────────────────────────────────────────────

class _ZReportSheet extends StatelessWidget {
  final ZReport z;
  const _ZReportSheet({required this.z});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                      z.zNumber.isEmpty ? 'Z-Report' : 'Z-Report ${z.zNumber}',
                      style: T.screenTitle.copyWith(color: pal.heading)),
                ),
                StatusBadge(status: z.status),
              ],
            ),
            Text(
              'Drawer ${z.drawerId.isEmpty ? '—' : shortId(z.drawerId)}'
              '  ·  ${z.openedAt ?? '—'} → ${z.closedAt ?? '—'}',
              style: TextStyle(
                  fontFamily: kFontMono, fontSize: 11, color: pal.muted),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _block(context, 'Cash Reconciliation', [
                      _row(context, 'Opening float', z.cash.openingFloat),
                      _row(context, 'Cash sales', z.cash.cashSales),
                      if (z.cash.paidIn > 0)
                        _row(context, 'Paid in', z.cash.paidIn),
                      if (z.cash.paidOut > 0)
                        _row(context, 'Paid out', -z.cash.paidOut),
                      _row(context, 'Expected', z.cash.expected),
                      _row(context, 'Counted', z.cash.counted),
                      _row(context, 'Variance', z.cash.variance,
                          color: z.cash.variance == 0
                              ? pal.success
                              : (z.cash.variance > 0 ? pal.info : pal.danger)),
                    ]),
                    if (z.payments.isNotEmpty)
                      _block(context, 'Payments', [
                        for (final p in z.payments)
                          _row(context, _methodLabel(p.method), p.total,
                              rest: '${p.count}×'),
                      ]),
                    _block(context, 'Totals', [
                      _row(context, 'Tips', z.tips),
                      if (z.serviceCharge > 0)
                        _row(context, 'Service charge', z.serviceCharge),
                      if (z.zCount > 0)
                        _rowPlain(context, 'Z count', '${z.zCount}'),
                      if (z.cumulativeCashSales > 0)
                        _row(context, 'Cumulative cash sales',
                            z.cumulativeCashSales),
                    ]),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _block(
      BuildContext context, String title, List<Widget> rows) {
    final pal = Pal.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: pal.sunken.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: pal.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(),
              style: TextStyle(
                  fontFamily: kFontBody,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: pal.muted)),
          const SizedBox(height: 6),
          ...rows,
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, double value,
      {Color? color, String? rest}) {
    final pal = Pal.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(rest == null ? label : '$label ($rest)',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 12, color: pal.body)),
          ),
          Text(money(value),
              style: T.mono.copyWith(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: color ?? pal.heading)),
        ],
      ),
    );
  }

  Widget _rowPlain(BuildContext context, String label, String value) {
    final pal = Pal.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 12, color: pal.body)),
          ),
          Text(value,
              style: T.mono.copyWith(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: pal.heading)),
        ],
      ),
    );
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
