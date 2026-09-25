/// Team — how good each of us is doing, per craft.
///
/// The owner's brief (2026-09-25): "analytics that shows how good each of
/// them are doing — how many orders they did in a day, how much money they
/// make, how many customers they served — different for every role, and how
/// long they take to get the order, make the order, pick up the order, in
/// graphs and pies."
///
/// The screen answers per craft, and the craft decides what a viewer sees:
///
///   * **Floor** (head-waiter, + every money role) — per waiter: orders
///     taken, money brought in, tips, guests served (est.), the take→serve
///     pace, and the day's order share as a donut.
///   * **Kitchen / Bar** (chefs / barista) — the station's ticket flow and
///     clock legs from the order stamps (in New, make, pass), plus — since
///     the audit trail records stage taps (fufut-api d89ed50) — per person:
///     tickets bumped to preparing, fired ready, and their make pace.
///   * **Till** (cashier, + the money roles) — per operator: payments
///     taken, money collected, transfers verified, and the day's money by
///     method as a donut.
///
/// The manager and the accountant see every section; each staff role sees
/// its own craft and the day at a glance. One day at a time — the picker
/// keeps Today, Yesterday and a picked date apart, the same rule the Order
/// Log follows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../services/team_stats.dart';
import '../state/app_state.dart';
import '../state/order_scope.dart' show localTodayKey;
import '../theme.dart';
import '../widgets/backoffice.dart';
import '../widgets/charts.dart';
import '../widgets/dashboard.dart';

/// One build of the day — everything the sections need, fetched once.
class _TeamData {
  final List<FufutOrder> orders;
  final Map<String, CafeTable> tablesByNumber;
  final List<FufutPayment> payments;
  final List<AuditEntry> statusRows;
  const _TeamData(this.orders, this.tablesByNumber, this.payments, this.statusRows);
}

/// The day's rows for [dayKey] (`YYYY-MM-DD`, device-local). Fetches read,
/// never watch: the feeds' push bells are not wired here — a performance
/// day is a settled thing, and the pull-to-refresh + day switch are the
/// refresh paths that matter.
final _teamDataProvider =
    FutureProvider.family<_TeamData, String>((ref, dayKey) async {
  final app = ref.read(appStateProvider);
  final role = app.roleKey ?? '';
  final isMoney =
      role == 'manager' || role == 'accountant' || role == 'cashier';
  final fullTrail = role == 'manager' || role == 'accountant';

  // The audit's `at` is UTC ISO; the day window converts so the string
  // compare lands on the venue's calendar, not the server's.
  final dayStart = DateTime.parse('${dayKey}T00:00:00').toUtc();
  final fromIso = dayStart.toIso8601String();
  final toIso = dayStart.add(const Duration(days: 1)).toIso8601String();

  final results = await Future.wait([
    app.api.orders(from: dayKey, to: dayKey),
    // Party sizes for the guest estimate — best-effort, the same fallback
    // the Order Log rides: a role without a tables read just loses the
    // party numbers, not the section.
    app.api.tables().catchError((_) => const <CafeTable>[]),
    // The till ledger — money roles only; everyone else's 403 is the
    // expected shape, not an error.
    isMoney
        ? app.api.recentPayments().catchError((_) => const <FufutPayment>[])
        : Future.value(const <FufutPayment>[]),
    // The stage trail. The manager reads the whole room; a staff role reads
    // its own rows (the server's self-scoped carve-out demands actor_id=self,
    // and refuses the request without it).
    fullTrail
        ? app.api.auditFiltered(
            entity: 'orders', action: 'status',
            from: fromIso, to: toIso, limit: 500)
        : app.api.auditFiltered(
            entity: 'orders', action: 'status', actorId: app.user?.id,
            from: fromIso, to: toIso, limit: 500)
            .catchError((_) => const <AuditEntry>[]),
  ]);

  final rows = results[0] as List<FufutOrder>;
  final tables = results[1] as List<CafeTable>;
  return _TeamData(
    rows,
    {for (final t in tables) t.number.toString(): t},
    results[2] as List<FufutPayment>,
    results[3] as List<AuditEntry>,
  );
});

class TeamScreen extends ConsumerStatefulWidget {
  const TeamScreen({super.key});

  @override
  ConsumerState<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends ConsumerState<TeamScreen> {
  String _day = localTodayKey();

  void _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse('${_day}T00:00:00') ?? DateTime.now(),
      firstDate: DateTime.now().add(const Duration(days: -90)),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      String two(int v) => v.toString().padLeft(2, '0');
      setState(() => _day = '${picked.year}-${two(picked.month)}-${two(picked.day)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final app = ref.watch(appStateProvider);
    final role = app.roleKey ?? '';
    final dataAsync = ref.watch(_teamDataProvider(_day));

    // What this role's screen carries — the craft decides the sections.
    final showFloor = ['manager', 'accountant', 'head-waiter', 'cashier'].contains(role);
    final showKitchen =
        ['manager', 'accountant', 'head-chef', 'assistant-chef'].contains(role);
    final showBar = ['manager', 'accountant', 'barista'].contains(role);
    final showTill = ['manager', 'accountant', 'cashier'].contains(role);
    final staffViewer = !(role == 'manager' || role == 'accountant');

    final data = dataAsync.value ?? const _TeamData([], {}, [], []);
    final stats = computeTeamDay(
      dayKey: _day,
      orders: data.orders,
      tablesByNumber: data.tablesByNumber,
      payments: data.payments,
      statusRows: data.statusRows,
      catByName: app.catByName,
    );

    final body = dataAsync.isLoading && data.orders.isEmpty
        ? const Center(child: CircularProgressIndicator())
        : dataAsync.hasError && data.orders.isEmpty
            ? LoadError(
                error: dataAsync.error!,
                onRetry: () => ref.invalidate(_teamDataProvider(_day)))
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(_teamDataProvider(_day)),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                  children: [
                    _DayHeader(day: _day, onPick: _pickDay, onReload: () {
                      ref.invalidate(_teamDataProvider(_day));
                    }),
                    const SizedBox(height: 8),
                    ChipSelect(
                      value: _day == localTodayKey()
                          ? 'today'
                          : _day == localTodayKey(DateTime.now()
                                  .add(const Duration(days: -1)))
                              ? 'yday'
                              : 'pick',
                      options: const [
                        ('today', 'Today'),
                        ('yday', 'Yesterday'),
                        ('pick', 'Pick a day'),
                      ],
                      onChanged: (v) {
                        if (v == 'today') {
                          setState(() => _day = localTodayKey());
                        } else if (v == 'yday') {
                          setState(() => _day = localTodayKey(
                              DateTime.now().add(const Duration(days: -1))));
                        } else {
                          _pickDay();
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    _GlanceStrip(stats: stats, showTill: showTill),
                    const SizedBox(height: 4),
                    if (showFloor) ...[
                      _FloorSection(staff: stats.floor),
                      const SizedBox(height: 10),
                    ],
                    if (showKitchen) ...[
                      _StationSection(
                          station: stats.kitchen,
                          staffViewer: staffViewer,
                          unit: 'tickets'),
                      const SizedBox(height: 10),
                    ],
                    if (showBar) ...[
                      _StationSection(
                          station: stats.bar,
                          staffViewer: staffViewer,
                          unit: 'tickets'),
                      const SizedBox(height: 10),
                    ],
                    if (showTill) ...[
                      _TillSection(stats: stats),
                      const SizedBox(height: 10),
                    ],
                  ],
                ),
              );

    return Scaffold(backgroundColor: pal.bg, body: SafeArea(child: body));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sections
// ─────────────────────────────────────────────────────────────────────────────

class _DayHeader extends StatelessWidget {
  final String day;
  final VoidCallback onPick;
  final VoidCallback onReload;
  const _DayHeader({required this.day, required this.onPick, required this.onReload});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final today = localTodayKey();
    final yday = localTodayKey(DateTime.now().add(const Duration(days: -1)));
    final label = day == today
        ? 'Today'
        : day == yday
            ? 'Yesterday'
            : '${day.substring(8, 10)}/${day.substring(5, 7)}';
    return Row(
      children: [
        Text('Team — $label',
            style: T.screenTitle.copyWith(color: pal.heading)),
        const SizedBox(width: 8),
        IconButton(
          onPressed: onPick,
          icon: const Icon(Icons.calendar_month_outlined, size: 19),
          tooltip: 'Pick a day',
        ),
        const Spacer(),
        IconButton(
          onPressed: onReload,
          icon: const Icon(Icons.refresh_rounded, size: 20),
          tooltip: 'Reload',
        ),
      ],
    );
  }
}

/// The day at a glance — one strip, every role.
class _GlanceStrip extends StatelessWidget {
  final TeamDayStats stats;
  final bool showTill;
  const _GlanceStrip({required this.stats, required this.showTill});

  @override
  Widget build(BuildContext context) {
    final cards = <Widget>[
      _MiniKpi('${stats.ordersCount}', 'orders'),
      _MiniKpi(money(stats.revenue), 'revenue'),
      _MiniKpi('${stats.guests}', 'guests (est.)'),
      if (stats.tips > 0) _MiniKpi(money(stats.tips), 'tips'),
      if (stats.avgServeMin != null)
        _MiniKpi(_fmtMin(stats.avgServeMin!), 'avg take→serve'),
      if (showTill && stats.transfersPending > 0)
        _MiniKpi('${stats.transfersPending}', 'transfers to verify',
            highlight: true),
    ];
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: cards.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) => cards[i],
      ),
    );
  }
}

class _MiniKpi extends StatelessWidget {
  final String value;
  final String label;
  final bool highlight;
  const _MiniKpi(this.value, this.label, {this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      width: 118,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: highlight ? pal.tintBg : pal.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: highlight ? pal.primary : pal.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: T.mono.copyWith(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w800,
                  color: highlight ? pal.primary : pal.heading)),
          const SizedBox(height: 2),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontFamily: kFontBody, fontSize: 9.5, color: pal.muted)),
        ],
      ),
    );
  }
}

/// The floor: who took what, brought what, served whom, how fast.
class _FloorSection extends StatelessWidget {
  final List<FloorStaffDay> staff;
  const _FloorSection({required this.staff});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return SectionCard(
      title: 'The floor — waiters',
      children: [
        if (staff.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text('No orders this day.',
                style: TextStyle(fontFamily: kFontBody, fontSize: 11.5, color: Colors.grey)),
          )
        else ...[
          const _LegendRow(['orders', 'money', 'guests (est.)', 'pace']),
          const SizedBox(height: 8),
          HBarChart(
            bars: [for (final p in staff) HBar(p.name, p.orders.toDouble())],
            valueLabel: (v) => v.toStringAsFixed(0),
          ),
          const SizedBox(height: 10),
          HBarChart(
            bars: [for (final p in staff) HBar(p.name, p.sales, color: const Color(0xFF6366F1))],
            valueLabel: (v) => money(v),
          ),
          const SizedBox(height: 10),
          HBarChart(
            bars: [
              for (final p in staff)
                HBar(p.name, p.guests.toDouble(), color: pal.gold)
            ],
            valueLabel: (v) => v.toStringAsFixed(0),
          ),
          const SizedBox(height: 10),
          _PaceChart(staff: staff),
          const SizedBox(height: 12),
          DonutChart(
            slices: [
              for (final p in staff) DonutSlice(p.name, p.orders.toDouble()),
            ],
            centerLabel: 'Orders',
            centerValue: '${staff.fold<int>(0, (s, p) => s + p.orders)}',
          ),
        ],
      ],
    );
  }
}

/// Take→serve pace per person; people without a completed serve sit out.
class _PaceChart extends StatelessWidget {
  final List<FloorStaffDay> staff;
  const _PaceChart({required this.staff});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final withPace = staff.where((p) => p.avgServeMin != null).toList()
      ..sort((a, b) => a.avgServeMin!.compareTo(b.avgServeMin!));
    if (withPace.isEmpty) {
      return Text('No completed serves yet — the pace appears once tickets are served.',
          style: TextStyle(fontFamily: kFontBody, fontSize: 10.5, color: pal.faint));
    }
    return HBarChart(
      bars: [
        for (final p in withPace)
          HBar(p.name, p.avgServeMin!, color: pal.success),
      ],
      valueLabel: (v) => _fmtMin(v),
    );
  }
}

/// Kitchen / Bar: the station's clock from the order stamps, the people
/// from the audit trail.
class _StationSection extends StatelessWidget {
  final StationDay station;
  final bool staffViewer;
  final String unit;
  const _StationSection({
    required this.station,
    required this.staffViewer,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final people = station.peopleSorted;
    return SectionCard(
      title: '${station.name} — ${station.tickets} $unit · ${station.items} items',
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            if (station.avgNewMin != null) _Leg('in New', station.avgNewMin!),
            if (station.avgMakeMin != null) _Leg('make', station.avgMakeMin!),
            if (station.avgPassMin != null) _Leg('pass', station.avgPassMin!),
            if (station.avgNewMin == null &&
                station.avgMakeMin == null &&
                station.avgPassMin == null)
              Text('No stage stamps yet this day.',
                  style: TextStyle(
                      fontFamily: kFontBody, fontSize: 10.5, color: pal.faint)),
          ],
        ),
        const SizedBox(height: 12),
        if (people.isEmpty)
          Text(
            staffViewer
                ? 'Your stage taps will appear here as you work the board.'
                : 'The per-person picture starts once the boards work this day (stage taps are recorded from 2026-09-25).',
            style: TextStyle(fontFamily: kFontBody, fontSize: 10.5, color: pal.faint),
          )
        else ...[
          HBarChart(
            bars: [
              for (final p in people)
                HBar(p.name, p.touches.toDouble(), color: pal.warning),
            ],
            valueLabel: (v) => '${v.toStringAsFixed(0)} taps',
          ),
          const SizedBox(height: 8),
          ...[
            for (final p in people)
              if (p.avgMakeMin != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Expanded(
                        child: Text(p.name,
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 11,
                                color: pal.body))),
                    Text('${p.bumped} prepared · ${p.readied} readied · avg make ${_fmtMin(p.avgMakeMin!)}',
                        style: TextStyle(
                            fontFamily: kFontMono,
                            fontSize: 10.5,
                            color: pal.muted)),
                  ]),
                ),
          ],
        ],
      ],
    );
  }
}

class _Leg extends StatelessWidget {
  final String label;
  final double mins;
  const _Leg(this.label, this.mins);

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: pal.sunken,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text('$label ${_fmtMin(mins)}',
          style: TextStyle(
              fontFamily: kFontMono,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: pal.body)),
    );
  }
}

/// The till: who took the money, by which method, and the verify queue.
class _TillSection extends StatelessWidget {
  final TeamDayStats stats;
  const _TillSection({required this.stats});

  static const _methodLabels = {
    'cash': 'Cash',
    'telebirr': 'Telebirr',
    'cbe': 'CBE',
    'bank': 'Bank',
    'card': 'Card',
    'other': 'Other',
  };

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final methods = stats.moneyByMethod.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return SectionCard(
      title: 'The till — money taken',
      children: [
        if (stats.till.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text('No money taken this day.',
                style: TextStyle(fontFamily: kFontBody, fontSize: 11.5, color: Colors.grey)),
          )
        else ...[
          DonutChart(
            slices: [
              for (final m in methods)
                DonutSlice(_methodLabels[m.key] ?? m.key, m.value),
            ],
            centerLabel: 'Collected',
            centerValue: money(methods.fold<double>(0, (s, m) => s + m.value)),
          ),
          const SizedBox(height: 12),
          HBarChart(
            bars: [
              for (final p in stats.till)
                HBar(p.name, p.collected, color: pal.success),
            ],
            valueLabel: (v) => money(v),
          ),
          const SizedBox(height: 6),
          for (final p in stats.till)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Expanded(
                    child: Text(p.name,
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11,
                            color: pal.body))),
                Text(
                  '${p.payments} taken'
                  '${p.transfersVerified > 0 ? ' · ${p.transfersVerified} transfers verified' : ''}',
                  style: TextStyle(
                      fontFamily: kFontMono, fontSize: 10.5, color: pal.muted),
                ),
              ]),
            ),
          if (stats.transfersPending > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${stats.transfersPending} transfer(s) still to verify — the till has recorded them, the money is not confirmed yet.',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 10.5, color: pal.gold),
              ),
            ),
        ],
      ],
    );
  }
}

class _LegendRow extends StatelessWidget {
  final List<String> labels;
  const _LegendRow(this.labels);

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Text(labels.join('   ·   '),
        style: TextStyle(
            fontFamily: kFontBody, fontSize: 9.5, color: pal.faint,
            letterSpacing: 0.4));
  }
}

String _fmtMin(double mins) {
  final m = mins.round();
  if (m < 60) return '${m}m';
  return '${m ~/ 60}h${m % 60}m';
}
