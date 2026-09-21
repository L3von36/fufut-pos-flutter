/// Dependency-free chart primitives — the Flutter half of the web POS's
/// Chart.js/ECharts panels (DashboardView, PnLView, RevenueView,
/// AnalyticsView, ReportsView) at the app's compact density.
///
/// Hand-rolled on purpose: three shapes cover every chart the web POS draws
/// — horizontal bars (sales by category, top items, staff performance),
/// a donut (payment-method mix), and vertical spark bars (daily revenue,
/// rev-vs-expenses) — without pulling a chart package into a 100%-control
/// codebase.
library;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Horizontal labelled bars — "sales by category", "top items", staff
/// performance. Largest value fills the row; the rest scale against it.
class HBarChart extends StatelessWidget {
  final List<HBar> bars;
  final String Function(double)? valueLabel;

  const HBarChart({super.key, required this.bars, this.valueLabel});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    if (bars.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text('No data yet',
            style: TextStyle(fontFamily: kFontBody, fontSize: 11.5, color: pal.faint)),
      );
    }
    final maxV =
        bars.map((b) => b.value).fold<double>(0, (m, v) => v > m ? v : m);
    return Column(
      children: [
        for (final b in bars)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 96,
                  child: Text(b.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: kFontBody,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: pal.body)),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: Container(
                      height: 12,
                      color: pal.sunken,
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: maxV <= 0 ? 0 : (b.value / maxV).clamp(0.02, 1.0),
                        child: Container(color: b.color ?? pal.primary),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 76,
                  child: Text(
                    valueLabel != null
                        ? valueLabel!(b.value)
                        : _defaultLabel(b.value),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontFamily: kFontMono,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: pal.muted),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _defaultLabel(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

/// One horizontal bar row.
class HBar {
  final String label;
  final double value;
  final Color? color;
  const HBar(this.label, this.value, {this.color});
}

/// Donut for the payment-method mix. Slices scale by value; the hole shows
/// the total. Zero-value slices vanish rather than divide by zero.
class DonutChart extends StatelessWidget {
  final List<DonutSlice> slices;
  final String centerLabel;
  final String centerValue;

  const DonutChart({
    super.key,
    required this.slices,
    this.centerLabel = '',
    this.centerValue = '',
  });

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    final total = slices.fold<double>(0, (s, e) => s + e.value);
    final palette = [
      pal.primary,
      pal.gold,
      pal.info,
      pal.warning,
      pal.success,
      pal.danger,
    ];
    final visible = slices.where((s) => s.value > 0).toList();
    return Row(
      children: [
        SizedBox(
          width: 108,
          height: 108,
          child: total <= 0
              ? Center(
                  child: Text('—',
                      style: TextStyle(
                          fontFamily: kFontMono, fontSize: 18, color: pal.faint)))
              : CustomPaint(
                  painter: _DonutPainter(
                    slices: visible,
                    total: total,
                    palette: palette,
                    track: pal.sunken,
                    hole: pal.surface,
                  ),
                ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (centerValue.isNotEmpty) ...[
                Text(centerLabel.toUpperCase(),
                    style: TextStyle(
                        fontFamily: kFontBody,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: pal.muted)),
                Text(centerValue,
                    style: TextStyle(
                        fontFamily: kFontMono,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: pal.heading)),
                const SizedBox(height: 6),
              ],
              for (var i = 0; i < visible.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: palette[i % palette.length],
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(visible[i].label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontFamily: kFontBody,
                                fontSize: 11,
                                color: pal.body)),
                      ),
                      Text(
                        '${total > 0 ? ((visible[i].value / total) * 100).toStringAsFixed(0) : 0}%',
                        style: TextStyle(
                            fontFamily: kFontMono,
                            fontSize: 10.5,
                            color: pal.muted),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One donut slice.
class DonutSlice {
  final String label;
  final double value;
  const DonutSlice(this.label, this.value);
}

class _DonutPainter extends CustomPainter {
  final List<DonutSlice> slices;
  final double total;
  final List<Color> palette;
  final Color track;
  final Color hole;

  _DonutPainter({
    required this.slices,
    required this.total,
    required this.palette,
    required this.track,
    required this.hole,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..color = track;
    canvas.drawCircle(rect.center, rect.shortestSide / 2 - 8, stroke);

    var start = -3.14159 / 2; // 12 o'clock
    for (var i = 0; i < slices.length; i++) {
      final sweep = (slices[i].value / total) * 3.14159 * 2;
      final seg = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..color = palette[i % palette.length];
      canvas.drawArc(
          Rect.fromCircle(center: rect.center, radius: rect.shortestSide / 2 - 8),
          start,
          sweep,
          false,
          seg);
      start += sweep;
    }

    final holePaint = Paint()..color = hole;
    canvas.drawCircle(rect.center, rect.shortestSide / 2 - 16, holePaint);
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.total != total || old.slices.length != slices.length;
}

/// Vertical mini bars — daily revenue, rev-vs-expenses pairs, hourly
/// distribution. Negative values draw below the baseline (net P&L days).
class VBarChart extends StatelessWidget {
  final List<VBar> bars;
  final double height;

  const VBarChart({super.key, required this.bars, this.height = 96});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    if (bars.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text('No data yet',
              style: TextStyle(
                  fontFamily: kFontBody, fontSize: 11.5, color: pal.faint)),
        ),
      );
    }
    final maxV = bars
        .map((b) => b.value.abs())
        .fold<double>(0, (m, v) => v > m ? v : m);
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final b in bars)
            Expanded(
              child: Tooltip(
                message: '${b.label}  ${b.value.toStringAsFixed(0)}',
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (b.value >= 0)
                      Expanded(
                        flex: maxV <= 0 ? 1 : (b.value / maxV * 100).round().clamp(1, 100),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            color: b.color ?? pal.primary,
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(2)),
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    Container(
                        width: double.infinity,
                        height: 1,
                        color: pal.border),
                    if (b.value < 0)
                      Expanded(
                        flex: maxV <= 0 ? 1 : (b.value.abs() / maxV * 100).round().clamp(1, 100),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            color: b.color ?? pal.danger,
                            borderRadius: const BorderRadius.vertical(
                                bottom: Radius.circular(2)),
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One vertical bar.
class VBar {
  final String label;
  final double value;
  final Color? color;
  const VBar(this.label, this.value, {this.color});
}

/// A row of bar labels under a [VBarChart].
class VBarLabels extends StatelessWidget {
  final List<String> labels;
  const VBarLabels({super.key, required this.labels});

  @override
  Widget build(BuildContext context) {
    final pal = Pal.of(context);
    return Row(
      children: [
        for (final l in labels)
          Expanded(
            child: Text(
              l,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontFamily: kFontMono, fontSize: 8.5, color: pal.faint),
            ),
          ),
      ],
    );
  }
}
