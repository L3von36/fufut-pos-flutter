import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Shared UI atoms for the POS — the PWA's `.badge`, toasts and helpers.
///
/// Snackbars double as the PWA's toasts: dark pills, colored by kind
/// (success `rgba(34,120,69,.96)`, error `rgba(198,40,40,.96)`,
/// info `rgba(30,90,210,.96)`, warning `rgba(200,105,10,.96)`).

const Color _toastSuccess = Color(0xF5227845);
const Color _toastError = Color(0xF5C62828);
const Color _toastWarn = Color(0xF5C8690A);

// ─────────────────────────────────────────────────────────────────────────────
// AsyncButton — every network-writing button in the app, stateful.
// ─────────────────────────────────────────────────────────────────────────────

/// Owner's rule (2026-09): EVERY button that does work over the network
/// carries its own state — idle, busy (spinner + disabled), success (check,
/// briefly) — on every screen, for every role. A tap that is in flight can
/// never fire twice, a slow link never leaves the staff wondering whether
/// the tap landed, and a finished action visibly confirms before the sheet
/// pops or the list refreshes.
///
/// Errors are NOT the button's business: the action's own handler surfaces
/// them (the showErrorOn/showInfoOn helpers) — the widget reverts to idle on
/// failure and never rethrows, so no tap can turn into an unhandled future.
class AsyncButton extends StatefulWidget {
  /// The action to run. Resolve = success beat; throw = revert to idle.
  final Future<void> Function() onPressed;
  final String label;
  final IconData? icon;

  /// Filled by default; true renders the outlined variant.
  final bool outlined;

  /// Filled variant colors — defaults to the theme's primary button.
  final Color? background;
  final Color? foreground;

  final double height;
  final EdgeInsetsGeometry? padding;

  /// Terminal actions stay on the success beat a beat longer (settle, send).
  final Duration successHold;

  const AsyncButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.outlined = false,
    this.background,
    this.foreground,
    this.height = 42,
    this.padding,
    this.successHold = const Duration(milliseconds: 800),
  });

  @override
  State<AsyncButton> createState() => _AsyncButtonState();
}

class _AsyncButtonState extends State<AsyncButton> {
  bool _busy = false;
  bool _success = false;
  Timer? _hold;

  Future<void> _run() async {
    if (_busy || _success) return;
    setState(() => _busy = true);
    try {
      await widget.onPressed();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _success = true;
      });
      // A cancellable timer, not a delayed future: a disposed button (a sheet
      // that popped on success) must not leave a pending timer behind.
      _hold?.cancel();
      _hold = Timer(widget.successHold, () {
        if (mounted) setState(() => _success = false);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      // The handler already surfaced the refusal; the button just reverts.
    }
  }

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final Widget lead;
    if (_busy) {
      lead = SizedBox(
        width: 15,
        height: 15,
        child: CircularProgressIndicator(
          strokeWidth: 2.2,
          valueColor: AlwaysStoppedAnimation(
              widget.outlined ? (widget.foreground ?? pal.primary) : Colors.white),
        ),
      );
    } else if (_success) {
      lead = const Icon(Icons.check_rounded, size: 18);
    } else if (widget.icon != null) {
      lead = Icon(widget.icon, size: 18);
    } else {
      lead = const SizedBox(width: 18);
    }

    const labelStyle = TextStyle(
        fontFamily: kFontBody, fontSize: 12.5, fontWeight: FontWeight.w800);

    final onPressed = (_busy || _success) ? null : _run;

    if (widget.outlined) {
      return SizedBox(
        width: double.infinity,
        height: widget.height,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: widget.foreground ?? pal.primary,
            padding: widget.padding,
            textStyle: labelStyle,
          ),
          icon: lead,
          label: Text(_busy ? 'Working…' : widget.label),
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      height: widget.height,
      child: FilledButton.icon(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: _success ? pal.success : (widget.background ?? pal.primary),
          padding: widget.padding,
          textStyle: labelStyle,
        ),
        icon: lead,
        label: Text(_busy ? 'Working…' : widget.label),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Toasts
// ─────────────────────────────────────────────────────────────────────────────

/// A non-dismissible "working" barrier for actions whose button has already
/// left the screen — the settle sheet pops before the network call runs, so
/// the button's own busy state is gone exactly when it matters most. Returns
/// a hide callback; always call it (in `finally` too).
Future<Future<void> Function()> showProcessingOverlay(
    BuildContext context, String label) async {
  final pal = Pal.of(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  navigator.push(PageRouteBuilder(
    opaque: false,
    barrierDismissible: false,
    barrierColor: pal.overlay,
    pageBuilder: (_, __, ___) => PopScope(
      canPop: false,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
          decoration: BoxDecoration(
            color: pal.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: pal.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(width: 12),
            Text(label,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: pal.heading)),
          ]),
        ),
      ),
    ),
    transitionsBuilder: (_, anim, __, child) =>
        FadeTransition(opacity: anim, child: child),
  ));
  return () async {
    if (navigator.canPop()) navigator.pop();
  };
}

/// One toast at a time, always.
///
/// Owner's rule (2026-09): a toast is a heartbeat, not wallpaper — it shows,
/// it fades, the screen is clean again. Two things made toasts feel sticky:
/// the snackbar QUEUE (each new toast waited behind the last, so four quick
/// actions kept pills on screen for ~15s) and durations tuned per call site.
/// Every helper now clears the queue first and carries one fixed duration:
/// info/success 2.5s, warning 3.5s, error 4.5s (errors read longer).
void _toast(
  ScaffoldMessengerState messenger,
  String message,
  Color background, {
  Duration duration = const Duration(seconds: 2, milliseconds: 500),
  SnackBarAction? action,
}) {
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: background,
      duration: duration,
      behavior: SnackBarBehavior.floating,
      action: action,
    ));
}

void showError(BuildContext context, Object error) => showErrorOn(
    ScaffoldMessenger.of(context), error);

void showInfo(BuildContext context, String message) => showInfoOn(
    ScaffoldMessenger.of(context), message);

void showWarn(BuildContext context, String message) => showWarnOn(
    ScaffoldMessenger.of(context), message);

/// Captured-messenger variants. An async action that pops its own sheet
/// cannot use a BuildContext afterwards — the messenger state is the safe
/// handle: captured before the await, used after it, no mounted dance needed.
void showErrorOn(ScaffoldMessengerState messenger, Object error) =>
    _toast(messenger, '$error', _toastError,
        duration: const Duration(milliseconds: 4500));

void showInfoOn(ScaffoldMessengerState messenger, String message) =>
    _toast(messenger, message, _toastSuccess);

/// Non-fatal but worth reading — a gate refused, a till is closed, a sweep
/// released something. Amber, reads longer than info.
void showWarnOn(ScaffoldMessengerState messenger, String message) =>
    _toast(messenger, message, _toastWarn,
        duration: const Duration(milliseconds: 3500));

/// A snackbar with an inline Undo action — the cart's remove flow.
void showUndoOn(
  ScaffoldMessengerState messenger,
  String message,
  VoidCallback onUndo,
) =>
    _toast(
      messenger,
      message,
      _toastSuccess,
      duration: const Duration(seconds: 4),
      action: SnackBarAction(
        label: 'UNDO',
        textColor: Colors.white,
        onPressed: onUndo,
      ),
    );

/// Inline, non-blocking feedback — the screen-level counterpart of the toasts.
/// Load failures, empty states with an explanation, refusals worth keeping on
/// screen: things a 4-second pill cannot carry. Severity colors match the
/// toasts; [onRetry] renders a trailing action button when provided.
class InfoBanner extends StatelessWidget {
  final String message;
  final InfoSeverity severity;
  final VoidCallback? onRetry;
  final IconData? icon;

  const InfoBanner(
    this.message, {
    super.key,
    this.severity = InfoSeverity.info,
    this.onRetry,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final (bg, fg, lead) = switch (severity) {
      InfoSeverity.error => (
          const Color(0xFFFDECEA),
          const Color(0xFFB3261E),
          Icons.error_outline_rounded
        ),
      InfoSeverity.warning => (
          const Color(0xFFFFF6E5),
          const Color(0xFF92510A),
          Icons.warning_amber_rounded
        ),
      InfoSeverity.success => (
          const Color(0xFFE8F5EE),
          const Color(0xFF1B6644),
          Icons.check_circle_outline_rounded
        ),
      InfoSeverity.info => (
          const Color(0xFFEAF1FD),
          const Color(0xFF1D4FA8),
          Icons.info_outline_rounded
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: fg.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon ?? lead, size: 17, color: fg),
          const SizedBox(width: 9),
          Expanded(
            child: Text(message,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 12.5,
                    height: 1.35,
                    color: fg)),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: fg,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Retry'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Severity of an [InfoBanner].
enum InfoSeverity { info, success, warning, error }

/// The till displays the last 4 characters of an order id ("Order #abc123").
/// Empty ids render as an empty tag rather than "#".
String shortId(String id) =>
    id.isEmpty ? '' : '#${id.substring(id.length >= 4 ? id.length - 4 : 0)}';

// ─────────────────────────────────────────────────────────────────────────────
// Status badges — exact PWA `.badge-*` palette
// ─────────────────────────────────────────────────────────────────────────────

class BadgeColors {
  const BadgeColors({required this.bg, required this.fg, required this.border});
  final Color bg;
  final Color fg;
  final Color border;
}

/// Colors per `.badge-{status}` in the PWA stylesheet. `served` / `unpaid` /
/// `partial` have no dedicated class there — they render bare (transparent).
BadgeColors badgeColors(BuildContext context, String status) {
  final pal = Pal.of(context);
  final dark = Theme.of(context).brightness == Brightness.dark;
  switch (status.toLowerCase()) {
    case 'new':
      return dark
          ? const BadgeColors(
              bg: Color(0x263B82F6), fg: Color(0xFF60A5FA), border: Color(0x333B82F6))
          : const BadgeColors(
              bg: Color(0xFFEFF6FF), fg: Color(0xFF1E40AF), border: Color(0xFFBFDBFE));
    case 'preparing':
    case 'pending':
      return dark
          ? const BadgeColors(
              bg: Color(0x26F59E0B), fg: Color(0xFFFBBF24), border: Color(0x33F59E0B))
          : const BadgeColors(
              bg: Color(0xFFFFFBEB), fg: Color(0xFF92400E), border: Color(0xFFFDE68A));
    case 'ready':
      return dark
          ? const BadgeColors(
              bg: Color(0x266366F1), fg: Color(0xFFA5B4FC), border: Color(0x336366F1))
          : const BadgeColors(
              bg: Color(0xFFEEF2FF), fg: Color(0xFF3730A3), border: Color(0xFFC7D2FE));
    case 'completed':
    case 'fulfilled':
      return dark
          ? const BadgeColors(
              bg: Color(0x2622C55E), fg: Color(0xFF4ADE80), border: Color(0x3322C55E))
          : const BadgeColors(
              bg: Color(0xFFF0FDF4), fg: Color(0xFF166534), border: Color(0xFFBBF7D0));
    case 'cancelled':
      return dark
          ? const BadgeColors(
              bg: Color(0x26EF4444), fg: Color(0xFFF87171), border: Color(0x33EF4444))
          : const BadgeColors(
              bg: Color(0xFFFEF2F2), fg: Color(0xFF991B1B), border: Color(0xFFFECACA));
    default: // served, unpaid, partial → bare badge, body color text
      return BadgeColors(bg: Colors.transparent, fg: pal.body, border: Colors.transparent);
  }
}

/// The PWA `.badge` — compact pill: uppercase, 10px/700, tight padding.
class StatusBadge extends StatelessWidget {
  final String status;
  const StatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final c = badgeColors(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(99),
        border: c.border == Colors.transparent
            ? null
            : Border.all(color: c.border),
      ),
      child: Text(
        status.toUpperCase(),
        style: T.badge.copyWith(color: c.fg),
      ),
    );
  }
}

/// Paid / unpaid chip on order cards (Tables-view pay badges: gold / green).
class PayBadge extends StatelessWidget {
  final bool paid;
  const PayBadge({super.key, required this.paid});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final Color bg, fg;
    if (paid) {
      bg = dark ? const Color(0x2622C55E) : const Color(0xFFF0FDF4);
      fg = dark ? const Color(0xFF4ADE80) : const Color(0xFF166534);
    } else {
      bg = dark ? const Color(0x26F59E0B) : const Color(0xFFFFFBEB);
      fg = dark ? const Color(0xFFFBBF24) : const Color(0xFF92400E);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(paid ? 'PAID' : 'UNPAID',
          style: T.badge.copyWith(color: fg)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small structural atoms
// ─────────────────────────────────────────────────────────────────────────────

/// Bottom-sheet drag handle — the PWA's 40×4 rounded bar.
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Center(
      child: Container(
        width: 32,
        height: 3.5,
        margin: const EdgeInsets.only(top: 10, bottom: 6),
        decoration: BoxDecoration(
          color: pal.borderStrong,
          borderRadius: BorderRadius.circular(99),
        ),
      ),
    );
  }
}

/// Sidebar-section header — uppercase, tracked, translucent white.
class NavSectionHeader extends StatelessWidget {
  final String label;
  const NavSectionHeader({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(label.toUpperCase(),
          style: T.navHeader.copyWith(
              color: Colors.white.withValues(alpha: 0.68), fontSize: 10.0)),
    );
  }
}

/// Empty state — 48px neutral circle icon + line, like the PWA lists.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? hint;
  final VoidCallback? onRetry;

  const EmptyState(
      {super.key, required this.icon, required this.title, this.hint, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: pal.sunken,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 23, color: pal.faint),
            ),
            const SizedBox(height: 10),
            Text(title,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: pal.heading)),
            if (hint != null && hint!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(hint!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: kFontBody, fontSize: 11.5, color: pal.muted)),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onRetry, child: const Text('Refresh')),
            ],
          ],
        ),
      ),
    );
  }
}

/// Dine-in context bar above the menu: "Ordering for Table N" +
/// a ghost "Make Takeaway" action — the PWA's `.table-context-bar`.
class TableContextBar extends StatelessWidget {
  final String tableNum;
  final VoidCallback onMakeTakeaway;

  const TableContextBar(
      {super.key, required this.tableNum, required this.onMakeTakeaway});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: pal.tintBg,
        border: Border.all(color: pal.primary),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.table_restaurant, size: 17, color: pal.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: 'Ordering for ',
                style: TextStyle(fontFamily: kFontBody, fontSize: 12.5, color: pal.body),
                children: [
                  TextSpan(
                    text: 'Table $tableNum',
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: pal.primary),
                  ),
                ],
              ),
            ),
          ),
          TextButton(
            onPressed: onMakeTakeaway,
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
            child: Text('Make Takeaway',
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 11.5, fontWeight: FontWeight.w600,
                    color: pal.primary)),
          ),
        ],
      ),
    );
  }
}
