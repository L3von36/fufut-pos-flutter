/// Shifts — the web `ShiftsView.vue`: the roster (who works when), staff
/// lookup joined client-side, manager-only add/edit/delete; everyone with
/// the grant reads.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/roles.dart' show roleTitle;
import '../theme.dart';
import '../widgets/backoffice.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

const kShiftTypes = ['morning', 'afternoon', 'evening'];

/// The roster plus the staff lookup it joins client-side — the web view
/// loads the same two reads together, so one record keeps them consistent.
final shiftsDataProvider = FutureProvider<
    ({List<ShiftRow> shifts, List<StaffMember> staff})>((ref) async {
  // Read, never watch: the fetch must not rebuild on its own session echo.
  final app = ref.read(appStateProvider);
  try {
    final results =
        await Future.wait<dynamic>([app.api.shifts(), app.api.staff()]);
    return (
      shifts: results[0] as List<ShiftRow>,
      staff: results[1] as List<StaffMember>,
    );
  } on ApiError catch (e) {
    if (e.isAuthError) await app.sessionExpired();
    rethrow;
  }
});

class ShiftsScreen extends ConsumerStatefulWidget {
  const ShiftsScreen({super.key});

  @override
  ConsumerState<ShiftsScreen> createState() => _ShiftsScreenState();
}

class _ShiftsScreenState extends ConsumerState<ShiftsScreen> {
  String _type = 'all';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _role => ref.read(appStateProvider).roleKey ?? '';
  bool get _canWrite => _role == 'manager';

  void _reload() => ref.invalidate(shiftsDataProvider);

  String _nameOf(ShiftRow s, List<StaffMember> staff) {
    if (s.staffName.isNotEmpty) return s.staffName;
    return staff.where((m) => m.id == s.staffId).map((m) => m.name).firstOrNull ?? 'Staff';
  }

  List<ShiftRow> _filtered(List<ShiftRow> all, List<StaffMember> staff) {
    final q = _search.text.trim().toLowerCase();
    return all.where((s) {
      if (_type != 'all' && s.shiftType != _type) return false;
      if (q.isNotEmpty && !_nameOf(s, staff).toLowerCase().contains(q)) return false;
      return true;
    }).toList()
      ..sort((a, b) => (b.date ?? '').compareTo(a.date ?? ''));
  }

  Future<void> _form({ShiftRow? edit, required List<StaffMember> staff}) async {
    if (staff.isEmpty) {
      showErrorOn(ScaffoldMessenger.of(context),
          ApiError('No staff roster available to schedule against'));
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final app = ref.read(appStateProvider);
    String staffId = edit?.staffId ?? staff.first.id;
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
              options: staff.map((s) => s.id).toList(),
              onChanged: (v) => setSheet(() => staffId = v),
            ),
            Text(staff.where((s) => s.id == staffId).map((s) => s.name).firstOrNull ?? '',
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
          _reload();
        } catch (e) {
          showErrorOn(messenger, e);
          rethrow;
        }
      },
    );
  }

  Future<void> _delete(ShiftRow s) async {
    final messenger = ScaffoldMessenger.of(context);
    final app = ref.read(appStateProvider);
    try {
      await app.api.deleteShift(s.id);
      showInfoOn(messenger, 'Shift removed');
      _reload();
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
    final dataAsync = ref.watch(shiftsDataProvider);
    final data = dataAsync.value;
    final all = data?.shifts ?? const <ShiftRow>[];
    final staff = data?.staff ?? const <StaffMember>[];
    if (dataAsync.isLoading && all.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (dataAsync.hasError && all.isEmpty) {
      return LoadError(error: dataAsync.error!, onRetry: _reload);
    }
    final pal = Pal.of(context);
    final rows = _filtered(all, staff);
    final today = DateRangeRow.fmt(DateTime.now());
    final onToday = all.where((s) => (s.date ?? '') == today).length;

    return RefreshIndicator(
      onRefresh: () async => _reload(),
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
                    value: '${all.length}', icon: Icons.calendar_month_outlined)),
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
                onPressed: () => _form(staff: staff),
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
                            Text(_nameOf(s, staff),
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
                        RowAction('Edit', () => _form(edit: s, staff: staff)),
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
