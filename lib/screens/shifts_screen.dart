/// Shifts — the web `ShiftsView.vue`: the roster (who works when), staff
/// lookup joined client-side, manager-only add/edit/delete; everyone with
/// the grant reads.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/roles.dart' show roleTitle;
import '../theme.dart';
import '../widgets/backoffice.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

const kShiftTypes = ['morning', 'afternoon', 'evening'];

class ShiftsScreen extends StatefulWidget {
  const ShiftsScreen({super.key});

  @override
  State<ShiftsScreen> createState() => _ShiftsScreenState();
}

class _ShiftsScreenState extends State<ShiftsScreen> {
  List<ShiftRow> _rows = [];
  List<StaffMember> _staff = [];
  bool _loading = true;
  Object? _error;
  String _type = 'all';
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

  String get _role => context.read<AppState>().roleKey ?? '';
  bool get _canWrite => _role == 'manager';

  Future<void> _load({bool quiet = false}) async {
    final app = context.read<AppState>();
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait<dynamic>(
          [app.api.shifts(), app.api.staff()]);
      final rows = results[0] as List<ShiftRow>;
      final staff = results[1] as List<StaffMember>;
      if (!mounted) return;
      setState(() { _rows = rows; _staff = staff; _loading = false; });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.isAuthError) { await app.sessionExpired(); return; }
      setState(() { _loading = false; _error = e; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e; });
    }
  }

  String _nameOf(ShiftRow s) {
    if (s.staffName.isNotEmpty) return s.staffName;
    return _staff.where((m) => m.id == s.staffId).map((m) => m.name).firstOrNull ?? 'Staff';
  }

  List<ShiftRow> get _filtered {
    final q = _search.text.trim().toLowerCase();
    return _rows.where((s) {
      if (_type != 'all' && s.shiftType != _type) return false;
      if (q.isNotEmpty && !_nameOf(s).toLowerCase().contains(q)) return false;
      return true;
    }).toList()
      ..sort((a, b) => (b.date ?? '').compareTo(a.date ?? ''));
  }

  Future<void> _form({ShiftRow? edit}) async {
    if (_staff.isEmpty) {
      showErrorOn(ScaffoldMessenger.of(context),
          ApiError('No staff roster available to schedule against'));
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final app = context.read<AppState>();
    String staffId = edit?.staffId ?? _staff.first.id;
    String type = edit?.shiftType.isEmpty == false ? edit!.shiftType : 'morning';
    final dateC = TextEditingController(
        text: edit?.date ?? DateRangeRow.fmt(DateTime.now()));
    final startC = TextEditingController(text: edit?.start ?? '08:00');
    final endC = TextEditingController(text: edit?.end ?? '16:00');

    await showFormSheet(
      context,
      title: edit == null ? 'Add shift' : 'Edit shift',
      body: () => StatefulBuilder(
        builder: (ctx, setSheet) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectF(
              label: 'Staff',
              value: staffId,
              options: _staff.map((s) => s.id).toList(),
              onChanged: (v) => setSheet(() => staffId = v),
            ),
            Text(_staff.where((s) => s.id == staffId).map((s) => s.name).firstOrNull ?? '',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 11, color: Pal.of(ctx).faint)),
            SelectF(
                label: 'Shift', value: type,
                options: kShiftTypes,
                onChanged: (v) => setSheet(() => type = v)),
            TextF('Date (YYYY-MM-DD)', dateC),
            Row(children: [
              Expanded(child: TextF('Start (HH:MM)', startC)),
              const SizedBox(width: 8),
              Expanded(child: TextF('End (HH:MM)', endC)),
            ]),
          ],
        ),
      ),
      onSave: () async {
        try {
          if (edit == null) {
            await app.api.postShift(
                staffId: staffId, shiftType: type,
                date: dateC.text.trim(),
                start: startC.text.trim(), end: endC.text.trim());
          } else {
            await app.api.updateShift(edit.id, {
              'staffId': staffId, 'shiftType': type,
              'date': dateC.text.trim(),
              'start': startC.text.trim(), 'end': endC.text.trim(),
            });
          }
          showInfoOn(messenger, edit == null ? 'Shift added' : 'Shift updated');
          await _load(quiet: true);
        } catch (e) {
          showErrorOn(messenger, e);
          rethrow;
        }
      },
    );
  }

  Future<void> _delete(ShiftRow s) async {
    final messenger = ScaffoldMessenger.of(context);
    final app = context.read<AppState>();
    try {
      await app.api.deleteShift(s.id);
      showInfoOn(messenger, 'Shift removed');
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Color _typeColor(Pal pal, String t) {
    switch (t) {
      case 'morning':
        return pal.warning;
      case 'afternoon':
        return pal.info;
      default:
        return pal.primary;
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
    final onToday = _rows.where((s) => (s.date ?? '') == today).length;

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: KpiCard(label: 'Scheduled today',
                    value: '$onToday', icon: Icons.badge_outlined)),
            const SizedBox(width: 8),
            Expanded(
                child: KpiCard(label: 'Roster entries',
                    value: '${_rows.length}', icon: Icons.calendar_month_outlined)),
          ]),
          const SizedBox(height: 10),
          SearchField(
              controller: _search,
              hint: 'Search staff…',
              onChanged: (_) => setState(() {})),
          const SizedBox(height: 8),
          ChipSelect(
            value: _type,
            options: [('all', 'All shifts'), ...kShiftTypes.map((t) => (t, t))],
            onChanged: (v) => setState(() => _type = v),
          ),
          const SizedBox(height: 10),
          if (_canWrite)
            SizedBox(
              height: 34,
              child: FilledButton.icon(
                onPressed: () => _form(),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add shift'),
              ),
            ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Roster',
            trailing: Text(_canWrite ? '' : 'view only',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 9.5, color: pal.faint)),
            children: [
              for (final s in rows.take(100))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_nameOf(s),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontFamily: kFontBody,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: pal.heading)),
                            const SizedBox(height: 1),
                            Text(
                                '${dayKey(s.date)} · ${s.start ?? '—'}–${s.end ?? '—'}'
                                '${s.role.isNotEmpty ? ' · ${roleTitle(s.role)}' : ''}',
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
                          color: _typeColor(pal, s.shiftType).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(s.shiftType.toUpperCase(),
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 8.5,
                                fontWeight: FontWeight.w800,
                                color: _typeColor(pal, s.shiftType))),
                      ),
                      if (_canWrite) ...[
                        const SizedBox(width: 6),
                        RowAction('Edit', () => _form(edit: s)),
                        const SizedBox(width: 4),
                        AsyncRowAction('Del', () => _delete(s), color: pal.danger),
                      ],
                    ],
                  ),
                ),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                      child: Text('No shifts scheduled',
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
