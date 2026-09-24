/// My Payslips — the web `MyPayslipsView.vue`, native.
///
/// The signed-in staff member's own payroll: current contract card, the
/// provisional-run banner, and the payslip history with the Ethiopian PAYE
/// line items — base, overtime, bonuses, deductions, income tax, pension,
/// net pay, tips earned. Everything is server-scoped to the session; you
/// only ever see your own money.
///
/// Tier-2: one screen-scoped FutureProvider — the payload is server-scoped
/// to the session, so there is no filter key. The session is READ inside
/// the provider, never watched (the fetch must not rebuild on its own
/// echo).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/dashboard.dart';

final payrollMeProvider = FutureProvider<PayrollMe>((ref) async {
  final app = ref.read(appStateProvider);
  try {
    return await app.api.payrollMe();
  } on ApiError catch (e) {
    if (e.isAuthError) await app.sessionExpired();
    rethrow;
  }
});

class MyPayslipsScreen extends ConsumerStatefulWidget {
  const MyPayslipsScreen({super.key});

  @override
  ConsumerState<MyPayslipsScreen> createState() => _MyPayslipsScreenState();
}

class _MyPayslipsScreenState extends ConsumerState<MyPayslipsScreen> {
  void _reload() => ref.invalidate(payrollMeProvider);

  @override
  Widget build(BuildContext context) {
    final payrollAsync = ref.watch(payrollMeProvider);
    if (payrollAsync.isLoading && payrollAsync.value == null) {
      return const DashboardSkeleton();
    }
    if (payrollAsync.hasError && payrollAsync.value == null) {
      return LoadError(error: payrollAsync.error!, onRetry: _reload);
    }
    final pal = Pal.of(context);
    final p = payrollAsync.value!;

    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          // ── Current contract ────────────────────────────────────────────
          SectionCard(
            title: 'My Pay',
            trailing: p.employmentType.isNotEmpty
                ? Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: pal.tintBg,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(p.employmentType,
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: pal.primary)),
                  )
                : null,
            children: [
              Text(
                money(p.baseSalary),
                style: TextStyle(
                    fontFamily: kFontMono,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: pal.heading),
              ),
              const SizedBox(height: 2),
              Text(
                p.salaryPeriod.isEmpty
                    ? 'base salary'
                    : 'base salary · ${p.salaryPeriod}',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 11.5,
                    color: pal.muted),
              ),
            ],
          ),
          // ── Provisional banner ──────────────────────────────────────────
          if (p.hasProvisional) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: pal.warningBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: pal.warningBorder),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: pal.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        'Some payslips below are provisional — figures can still change before the run is paid.',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11,
                            color: pal.warning)),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          // ── Payslip history ─────────────────────────────────────────────
          SectionCard(
            title: 'Payslip History',
            trailing: Icon(Icons.request_quote_outlined,
                size: 15, color: pal.faint),
            children: [
              if (p.payslips.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                    child: Text('No payslips issued yet',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11.5,
                            color: pal.faint)),
                  ),
                )
              else
                for (final s in p.payslips)
                  _payslipCard(context, s),
            ],
          ),
          const SizedBox(height: 12),
          // ── Standing notes, same as the web ────────────────────────────
          _noteCard(
            context,
            Icons.verified_outlined,
            'Tips are reported here for transparency — they are paid out '
            'per shift policy, not with the payroll run.',
          ),
          const SizedBox(height: 8),
          _noteCard(
            context,
            Icons.lock_outline,
            'This page shows only your own payroll data. Managers edit '
            'salaries on the web backoffice.',
          ),
        ],
      ),
    );
  }

  Widget _payslipCard(BuildContext context, Payslip s) {
    final pal = Pal.of(context);
    final paid = s.runStatus.toLowerCase() == 'paid';
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
          Row(
            children: [
              Expanded(
                child: Text(
                  '${s.periodStart.isEmpty ? '?' : s.periodStart} → ${s.periodEnd.isEmpty ? '?' : s.periodEnd}',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: pal.heading),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: paid ? pal.successBg : pal.warningBg,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(s.runStatus.isEmpty ? 'pending' : s.runStatus,
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        color: paid ? pal.success : pal.warning)),
              ),
              if (s.provisional) ...[
                const SizedBox(width: 5),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: pal.infoBg,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text('provisional',
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: pal.info)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          _row(context, 'Base salary', s.baseSalary),
          if (s.overtimePay > 0)
            _row(context, 'Overtime', s.overtimePay),
          if (s.bonuses > 0) _row(context, 'Bonuses', s.bonuses),
          if (s.deductions > 0)
            _row(context, 'Deductions', -s.deductions),
          if (s.incomeTax > 0)
            _row(context, 'Income tax (PAYE)', -s.incomeTax),
          if (s.pensionEmployee > 0)
            _row(context, 'Pension (7%)', -s.pensionEmployee),
          if (s.tipsEarned > 0)
            _row(context, 'Tips earned (reported)', s.tipsEarned),
          const Divider(height: 12),
          Row(
            children: [
              Text('NET PAY',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: pal.muted)),
              const Spacer(),
              Text(money(s.netPay),
                  style: TextStyle(
                      fontFamily: kFontMono,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: pal.heading)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, double value) {
    final pal = Pal.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 11.5, color: pal.muted)),
          ),
          Text(money(value),
              style: T.mono.copyWith(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: value < 0 ? pal.danger : pal.body)),
        ],
      ),
    );
  }

  Widget _noteCard(BuildContext context, IconData icon, String text) {
    final pal = Pal.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: pal.sunken.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: pal.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: pal.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 11,
                    height: 1.4,
                    color: pal.muted)),
          ),
        ],
      ),
    );
  }
}
