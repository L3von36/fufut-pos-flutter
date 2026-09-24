/// Reservations — the web `ReservationsView.vue`: the booking book with
/// creation (live availability, clash handling), confirm → complete →
/// cancel transitions and no-show release. Granted to manager, head-waiter
/// and cashier — anyone holding the `reservations` grant.
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

class ReservationsScreen extends StatefulWidget {
  const ReservationsScreen({super.key});

  @override
  State<ReservationsScreen> createState() => _ReservationsScreenState();
}

class _ReservationsScreenState extends State<ReservationsScreen> {
  List<Reservation> _rows = [];
  List<CafeTable> _tables = [];
  bool _loading = true;
  Object? _error;
  String _status = 'all';
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
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait<dynamic>(
          [app.api.reservations(), app.api.tables()]);
      final rows = results[0] as List<Reservation>;
      final tables = results[1] as List<CafeTable>;
      if (!mounted) return;
      setState(() { _rows = rows; _tables = tables; _loading = false; });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) { await app.sessionExpired(); return; }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  List<Reservation> get _filtered {
    final q = _search.text.trim().toLowerCase();
    return _rows.where((r) {
      if (_status != 'all' && r.status != _status) return false;
      if (q.isNotEmpty && !r.name.toLowerCase().contains(q)) return false;
      return true;
    }).toList()
      ..sort((a, b) {
        final d = (a.date ?? '').compareTo(b.date ?? '');
        return d != 0 ? d : (a.time ?? '').compareTo(b.time ?? '');
      });
  }

  Future<void> _book() async {
    final messenger = ScaffoldMessenger.of(context);
    final app = context.read<AppState>();
    final nameC = TextEditingController();
    final guestsC = TextEditingController(text: '2');
    final phoneC = TextEditingController();
    final dateC = TextEditingController(text: DateRangeRow.fmt(DateTime.now()));
    final timeC = TextEditingController(text: '19:00');
    String tableNum = _tables.isNotEmpty ? _tables.first.number : '';
    String duration = '90';
    String clash = '';
    StateSetter? sheetSet;

    await showFormSheet(
      context,
      title: 'New reservation',
      saveLabel: 'Book',
      body: () => StatefulBuilder(
        builder: (ctx, setSheet) {
          sheetSet = setSheet;
          return Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextF('Guest name *', nameC),
                TextF('Party size', guestsC, numeric: true),
                TextF('Phone', phoneC),
                TextF('Date (YYYY-MM-DD)', dateC),
                TextF('Time (HH:MM)', timeC),
                SelectF(
                    label: 'Table',
                    value: tableNum,
                    options: _tables.map((t) => t.number).toList(),
                    onChanged: (v) => setSheet(() => tableNum = v)),
                SelectF(
                    label: 'Holds for',
                    value: duration,
                    options: const ['60', '90', '120', '180'],
                    onChanged: (v) => setSheet(() => duration = v)),
                if (clash.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Pal.of(ctx).dangerBg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Pal.of(ctx).dangerBorder),
                    ),
                    child: Text(clash,
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Pal.of(ctx).danger)),
                  ),
              ],
            ),
          ),
          );
        },
      ),
      onSave: () async {
        if (nameC.text.trim().isEmpty) {
          showErrorOn(messenger, ApiError('A guest name is required'));
          return;
        }
        clash = '';
        try {
          await app.api.postReservation(
            name: nameC.text,
            guests: int.tryParse(guestsC.text) ?? 2,
            date: dateC.text.trim(),
            time: timeC.text.trim(),
            tableNum: tableNum,
            phone: phoneC.text,
            durationMin: int.tryParse(duration) ?? 90,
          );
          showInfoOn(messenger, 'Table $tableNum booked for ${nameC.text.trim()}');
          await _load(quiet: true);
        } on ApiError catch (e) {
          // The 409 clash message is the sheet's inline error, not a toast.
          if (e.status == 409) {
            clash = e.message;
            sheetSet?.call(() {});
            return;
          }
          showErrorOn(messenger, e);
          rethrow;
        } catch (e) {
          showErrorOn(messenger, e);
          rethrow;
        }
      },
    );
  }

  Future<void> _setStatus(Reservation r, String status) async {
    final messenger = ScaffoldMessenger.of(context);
    final app = context.read<AppState>();
    try {
      await app.api.updateReservation(r.id, status);
      showInfoOn(messenger, '${r.name} → $status');
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Future<void> _release(Reservation r) async {
    final messenger = ScaffoldMessenger.of(context);
    final app = context.read<AppState>();
    try {
      await app.api.releaseReservation(r.id);
      showInfoOn(messenger, 'Hold on table ${r.tableNum ?? '—'} released');
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Color _statusColor(Pal pal, String status) {
    switch (status) {
      case 'confirmed':
        return pal.success;
      case 'completed':
        return pal.info;
      case 'cancelled':
        return pal.danger;
      default:
        return pal.warning; // new — awaiting confirmation
    }
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
    final rows = _filtered;
    final today = DateRangeRow.fmt(DateTime.now());
    final todays = _rows.where((r) => (r.date ?? '') == today).length;

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: KpiCard(label: 'Today',
                    value: '$todays', icon: Icons.calendar_today_outlined)),
            const SizedBox(width: 8),
            Expanded(
                child: KpiCard(label: 'All upcoming',
                    value: '${_rows.length}', icon: Icons.event_note_outlined)),
          ]),
          const SizedBox(height: 10),
          SearchField(
              controller: _search,
              hint: 'Search guests…',
              onChanged: (_) => setState(() {})),
          const SizedBox(height: 8),
          ChipSelect(
            value: _status,
            options: const [
              ('all', 'All'), ('new', 'New'), ('confirmed', 'Confirmed'),
              ('completed', 'Completed'), ('cancelled', 'Cancelled'),
            ],
            onChanged: (v) => setState(() => _status = v),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 34,
            child: FilledButton.icon(
              onPressed: _book,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New reservation'),
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'The book',
            children: [
              for (final r in rows.take(100))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(r.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: pal.heading)),
                            const SizedBox(height: 1),
                            Text(
                                '${dayKey(r.date)} ${r.time ?? ''}'
                                ' · ${r.guests}p'
                                '${r.tableNum != null ? ' · T${r.tableNum}' : ''}'
                                '${r.phone != null && r.phone!.isNotEmpty ? ' · ${r.phone}' : ''}',
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
                          color: _statusColor(pal, r.status).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(r.status.toUpperCase(),
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w800,
                                color: _statusColor(pal, r.status))),
                      ),
                      const SizedBox(width: 6),
                      ...[
                        if (r.status == 'new') ...[
                          AsyncRowAction('Confirm',
                              () => _setStatus(r, 'confirmed'),
                              color: pal.success),
                          const SizedBox(width: 4),
                        ],
                        if (r.status == 'confirmed') ...[
                          AsyncRowAction('Complete',
                              () => _setStatus(r, 'completed')),
                          const SizedBox(width: 4),
                          AsyncRowAction('No-show', () => _release(r),
                              color: pal.warning),
                          const SizedBox(width: 4),
                        ],
                        if (r.status != 'cancelled' && r.status != 'completed')
                          AsyncRowAction('Cancel',
                              () => _setStatus(r, 'cancelled'),
                              color: pal.danger),
                      ],
                    ],
                  ),
                ),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                      child: Text('No reservations in this filter',
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
