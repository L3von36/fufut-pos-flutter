/// Time Clock — the web `TimeClockView.vue`, native.
///
/// Punch in and out, take breaks, leave a shift handover for the next person,
/// and see your recent shifts. The team roster loads only when the server
/// grants it (floor roles get a silent 403, same as the web).
///
/// Clock-out is refused by the server while checks are still open — the
/// error names them, and a manager can override with `{force:true}`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dashboard.dart';

class TimeClockScreen extends ConsumerStatefulWidget {
  const TimeClockScreen({super.key});

  @override
  ConsumerState<TimeClockScreen> createState() => _TimeClockScreenState();
}

class _TimeClockScreenState extends ConsumerState<TimeClockScreen> {
  TimeclockMe? _me;
  List<TimeclockEntry> _history = [];
  List<TimeclockEntry> _roster = [];
  Map<String, String> _staffNames = {};
  Handover? _lastHandover;
  bool _loading = true;
  bool _rosterVisible = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool quiet = false}) async {
    final app = ref.read(appStateProvider);
    if (!quiet) setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        app.api.timeclockMe(),
        app.api.timeclockHistory(),
        app.api.timeclockRoster(),
        app.api.staff(),
        app.api.latestHandover(),
      ]);
      if (!mounted) return;
      final roster = results[2] as List<TimeclockEntry>;
      final staff = results[3] as List<StaffMember>;
      setState(() {
        _me = results[0] as TimeclockMe;
        _history = results[1] as List<TimeclockEntry>;
        _roster = roster;
        _staffNames = {for (final s in staff) s.id: s.name};
        _rosterVisible = roster.isNotEmpty;
        _lastHandover = results[4] as Handover?;
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

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _clockIn() async {
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.clockIn();
      HapticFeedback.mediumImpact();
      showInfoOn(messenger, 'Clocked in — good shift!');
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Future<void> _clockOut({bool force = false}) async {
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await app.api.clockOut(force: force);
      HapticFeedback.mediumImpact();
      showInfoOn(messenger, force
          ? 'Clocked out — manager override applied'
          : 'Clocked out — see you next shift');
      await _load(quiet: true);
    } on ApiError catch (e) {
      // Refused: open checks. A manager gets the override button.
      if (e.isAuthError) {
        await app.sessionExpired();
        return;
      }
      if (force) {
        showErrorOn(messenger, e);
        return;
      }
      final isManager = app.roleKey == 'manager';
      if (mounted) _showBlockedDialog(e.message, isManager);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  void _showBlockedDialog(String message, bool canOverride) {
    final pal = Pal.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Clock-out blocked',
            style: TextStyle(
                fontFamily: kFontBody,
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: pal.heading)),
        content: Text(message,
            style: TextStyle(
                fontFamily: kFontBody, fontSize: 12.5, color: pal.body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Go settle checks'),
          ),
          if (canOverride)
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _clockOut(force: true);
              },
              style: FilledButton.styleFrom(backgroundColor: pal.danger),
              child: const Text('Override and clock out'),
            ),
        ],
      ),
    );
  }

  Future<void> _break(bool start) async {
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (start) {
        await app.api.breakStart();
        showInfoOn(messenger, 'Break started');
      } else {
        final mins = await app.api.breakEnd();
        showInfoOn(messenger,
            mins == null ? 'Break ended' : 'Break ended — $mins min');
      }
      await _load(quiet: true);
    } catch (e) {
      showErrorOn(messenger, e);
    }
  }

  Future<void> _handoverFlow() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Pal.of(context).surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: MediaQuery.sizeOf(context).height * 0.92),
      builder: (_) => const _HandoverSheet(),
    );
    if (saved == true && mounted) await _load(quiet: true);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading && _me == null) return const DashboardSkeleton();
    if (_error != null && _me == null) {
      return LoadError(error: _error!, onRetry: () => _load());
    }
    final pal = Pal.of(context);
    final me = _me;
    final onShift = me?.clockedIn ?? false;

    return RefreshIndicator(
      onRefresh: () => _load(quiet: true),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const GreetingHeader(),
          const SizedBox(height: 12),
          // ── Status card ─────────────────────────────────────────────────
          SectionCard(
            title: 'My Shift',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: onShift ? pal.success : pal.faint),
              ),
              const SizedBox(width: 5),
              Text(onShift ? 'ON SHIFT' : 'OFF SHIFT',
                  style: TextStyle(
                      fontFamily: kFontMono,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: onShift ? pal.success : pal.faint)),
            ]),
            children: [
              Text(
                onShift
                    ? 'On shift since ${me?.entry?.clockIn ?? '—'}'
                    : 'Not clocked in',
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: pal.heading),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: SizedBox(
                    height: 38,
                    child: onShift
                        ? AsyncButton(
                            onPressed: () => _clockOut(),
                            background: pal.danger,
                            icon: Icons.logout,
                            label: 'Clock Out',
                          )
                        : AsyncButton(
                            onPressed: _clockIn,
                            icon: Icons.login,
                            label: 'Clock In',
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 38,
                    child: OutlinedButton.icon(
                      onPressed:
                          onShift ? () => _break(!_inBreak) : null,
                      icon: Icon(_inBreak
                          ? Icons.timer
                          : Icons.free_breakfast_outlined),
                      label: Text(_inBreak ? 'End Break' : 'Start Break'),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              SizedBox(
                height: 34,
                child: OutlinedButton.icon(
                  onPressed: _handoverFlow,
                  icon: const Icon(Icons.swap_horiz, size: 16),
                  label: const Text('Shift Handover',
                      style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // ── Last handover ───────────────────────────────────────────────
          if (_lastHandover != null)
            _handoverCard(_lastHandover!),
          // ── My recent shifts ────────────────────────────────────────────
          const SizedBox(height: 10),
          _myShiftsCard(),
          // ── Roster (permitted roles only) ───────────────────────────────
          if (_rosterVisible) ...[
            const SizedBox(height: 10),
            _rosterCard(),
          ],
        ],
      ),
    );
  }

  /// Break state — the server stamps it on the open entry when one is live.
  bool get _inBreak => _me?.entry?.onBreak ?? false;

  Widget _handoverCard(Handover h) {
    final pal = Pal.of(context);
    return SectionCard(
      title: 'Last Handover',
      trailing: Text(h.staffName,
          style: TextStyle(
              fontFamily: kFontBody,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: pal.muted)),
      children: [
        for (final row in [
          ('Pending orders', h.pendingOrders),
          ('Pending tasks', h.pendingTasks),
          ('Cash info', h.cashInfo),
          ('Problems', h.problems),
          ('Customer issues', h.customerIssues),
          ('Important notes', h.importantNotes),
        ])
          if (row.$2.trim().isNotEmpty)
            ListRow(head: row.$1, rest: row.$2, trailing: ''),
      ],
    );
  }

  Widget _myShiftsCard() {
    final pal = Pal.of(context);
    return SectionCard(
      title: 'My Recent Shifts',
      trailing: Icon(Icons.schedule, size: 15, color: pal.faint),
      children: [
        if (_history.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text('No punches recorded yet',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 11.5,
                      color: pal.faint)),
            ),
          )
        else
          for (final e in _history.take(8))
            ListRow(
              head: e.date ?? (e.created ?? '').split(' ').first,
              rest: '${e.clockIn ?? '—'} → ${e.clockOut ?? 'on shift'}',
              trailing: _duration(e),
              trailingColor: e.clockOut == null ? pal.primary : null,
            ),
      ],
    );
  }

  String _duration(TimeclockEntry e) {
    if (e.clockOut == null) return 'active';
    final inParts = (e.clockIn ?? '').split(':');
    final outParts = (e.clockOut ?? '').split(':');
    if (inParts.length < 2 || outParts.length < 2) return '';
    final inMin = (int.tryParse(inParts[0]) ?? 0) * 60 +
        (int.tryParse(inParts[1]) ?? 0);
    final outMin = (int.tryParse(outParts[0]) ?? 0) * 60 +
        (int.tryParse(outParts[1]) ?? 0);
    final d = outMin - inMin;
    if (d <= 0) return '';
    return '${d ~/ 60}h${(d % 60).toString().padLeft(2, '0')}m';
  }

  Widget _rosterCard() {
    final pal = Pal.of(context);
    final clockedIn = _roster
        .where((e) => (e.clockOut ?? '').isEmpty)
        .length;
    return SectionCard(
      title: "Team Roster",
      trailing: Text('$clockedIn clocked in',
          style: TextStyle(
              fontFamily: kFontMono,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: clockedIn > 0 ? pal.success : pal.faint)),
      children: [
        for (final e in _roster.take(10))
          ListRow(
            head: _staffNames[e.id] ?? 'Staff ${shortId(e.id)}',
            rest: '${e.clockIn ?? '—'} → ${e.clockOut ?? 'on shift'}',
            trailing: e.clockOut == null ? 'active' : _duration(e),
            trailingColor: e.clockOut == null ? pal.primary : null,
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Handover form — six fields, exactly the web's shift handover.
// ─────────────────────────────────────────────────────────────────────────────

class _HandoverSheet extends ConsumerStatefulWidget {
  const _HandoverSheet();

  @override
  ConsumerState<_HandoverSheet> createState() => _HandoverSheetState();
}

class _HandoverSheetState extends ConsumerState<_HandoverSheet> {
  final _pendingOrders = TextEditingController();
  final _pendingTasks = TextEditingController();
  final _cashInfo = TextEditingController();
  final _problems = TextEditingController();
  final _customerIssues = TextEditingController();
  final _importantNotes = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _pendingOrders.dispose();
    _pendingTasks.dispose();
    _cashInfo.dispose();
    _problems.dispose();
    _customerIssues.dispose();
    _importantNotes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final app = ref.read(appStateProvider);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    try {
      await app.api.postHandover(
        pendingOrders: _pendingOrders.text.trim(),
        pendingTasks: _pendingTasks.text.trim(),
        cashInfo: _cashInfo.text.trim(),
        problems: _problems.text.trim(),
        customerIssues: _customerIssues.text.trim(),
        importantNotes: _importantNotes.text.trim(),
      );
      navigator.pop(true);
      showInfoOn(messenger, 'Handover saved for the next shift');
    } catch (e) {
      setState(() => _saving = false);
      showErrorOn(messenger, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return SafeArea(
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHandle(),
              const SizedBox(height: 6),
              Text('Shift Handover',
                  style: T.screenTitle.copyWith(color: pal.heading)),
              const SizedBox(height: 2),
              Text(
                  'What the next shift needs to know. Anything left blank is skipped.',
                  style: TextStyle(
                      fontFamily: kFontBody,
                      fontSize: 11.5,
                      color: pal.muted)),
              const SizedBox(height: 12),
              _field(_pendingOrders, 'Pending orders',
                  'e.g. Table 4 waiting on desserts'),
              _field(_pendingTasks, 'Pending tasks', 'Side work, restock…'),
              _field(_cashInfo, 'Cash info', 'Float notes, paid-ins…'),
              _field(_problems, 'Problems', 'Equipment, supplies…'),
              _field(_customerIssues, 'Customer issues', 'Complaints, holds…'),
              _field(_importantNotes, 'Important notes', 'Anything else…'),
              const SizedBox(height: 14),
              SizedBox(
                height: 40,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child:
                              CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined, size: 17),
                  label: const Text('Save Handover'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, String hint) {
    final pal = Pal.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: TextField(
        controller: c,
        maxLines: 2,
        minLines: 1,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: TextStyle(
              fontFamily: kFontBody, fontSize: 12, color: pal.muted),
        ),
        style: TextStyle(
            fontFamily: kFontBody, fontSize: 13, color: pal.heading),
      ),
    );
  }
}
