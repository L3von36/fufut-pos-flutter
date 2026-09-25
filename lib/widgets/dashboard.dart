/// Shared building blocks for the per-role dashboards — the web POS's
/// `.kpi-card`, `.card`, quick-action tiles and section headers, at the app's
/// compact enterprise density.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_state.dart';
import '../state/app_time.dart' show fmtLongDate;
import '../state/roles.dart';
import '../theme.dart';

/// Greeting banner — "Good evening, Yonas" + role + date, the web
/// dashboard's `.dash-greeting`. Hour windows follow the web's split.
class GreetingHeader extends ConsumerWidget {
  const GreetingHeader({super.key});

  static String _greeting(DateTime now) {
    final h = now.hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appStateProvider);
    final pal = Pal.of(context);
    final now = DateTime.now();
    final name = app.user?.firstName ?? app.user?.displayName ?? 'there';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${_greeting(now)}, $name',
            style: TextStyle(
                fontFamily: kFontBody,
                fontSize: 16.5,
                fontWeight: FontWeight.w800,
                color: pal.heading)),
        const SizedBox(height: 2),
        Text(
          '${roleTitle(app.user?.role ?? '')} · ${_fmtDate(now)}',
          style: TextStyle(
              fontFamily: kFontBody, fontSize: 11.5, color: pal.muted),
        ),
      ],
    );
  }

  /// The long date under the greeting — app_time's one [fmtLongDate].
  static String _fmtDate(DateTime d) => fmtLongDate(d);
}

/// One KPI tile — the web's `.kpi-card`: label eyebrow, big mono value,
/// optional accent color for the value.
class KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final IconData? icon;
  final String? sub;

  const KpiCard({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.icon,
    this.sub,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: pal.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 13, color: pal.faint),
                const SizedBox(width: 5),
              ],
              Expanded(
                child: Text(label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: pal.muted)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  fontFamily: kFontMono,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: valueColor ?? pal.heading)),
          if (sub != null && sub!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(sub!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 10, color: pal.faint)),
          ],
        ],
      ),
    );
  }
}

/// Card with a header row — the web `.card` + `.card-header` (title left,
/// optional trailing widget right).
class SectionCard extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final List<Widget> children;
  final EdgeInsets padding;

  const SectionCard({
    super.key,
    required this.title,
    this.trailing,
    required this.children,
    this.padding = const EdgeInsets.all(12),
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: pal.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: pal.heading)),
                ),
                if (trailing != null) trailing!,
              ],
            ),
          ),
          Padding(padding: padding, child: Column(children: children)),
        ],
      ),
    );
  }
}

/// One row inside a SectionCard list — leading text (+bold head), trailing
/// value; hairline separated, tight 8px vertical padding.
class ListRow extends StatelessWidget {
  final String head;
  final String? rest;
  final String trailing;
  final Color? trailingColor;
  final Widget? leading;

  const ListRow({
    super.key,
    required this.head,
    this.rest,
    required this.trailing,
    this.trailingColor,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: pal.border, width: 0.5)),
      ),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 8)],
          Expanded(
            child: Text.rich(
              TextSpan(
                text: head,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: pal.heading),
                children: [
                  if (rest != null && rest!.isNotEmpty)
                    TextSpan(
                        text: ' — $rest',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w400,
                            color: pal.muted)),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(trailing,
              style: TextStyle(
                  fontFamily: kFontMono,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: trailingColor ?? pal.body)),
        ],
      ),
    );
  }
}

/// A quick-action tile — the web dashboard's `.qa-tile`: icon in a tinted
/// rounded square above a short label. 44dp touch target minimum.
class QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? tint;

  const QuickAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final color = tint ?? pal.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: pal.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: pal.border),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 17, color: color),
            ),
            const SizedBox(height: 6),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: kFontBody,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: pal.body)),
          ],
        ),
      ),
    );
  }
}

/// Skeleton lines while a dashboard loads.
class DashboardSkeleton extends StatelessWidget {
  const DashboardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Container(width: 160, height: 18, color: pal.sunken),
        const SizedBox(height: 14),
        Row(
          children: [
            for (var i = 0; i < 2; i++) ...[
              Expanded(
                child: Container(height: 74, color: pal.sunken),
              ),
              if (i == 0) const SizedBox(width: 10),
            ],
          ],
        ),
        const SizedBox(height: 10),
        Container(height: 120, color: pal.sunken),
      ],
    );
  }
}

/// Inline error banner with a retry — used instead of a blank body.
class LoadError extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const LoadError({super.key, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 30, color: pal.faint),
            const SizedBox(height: 8),
            Text('$error',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: kFontBody, fontSize: 12, color: pal.muted)),
            const SizedBox(height: 10),
            OutlinedButton(
                onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
