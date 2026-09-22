import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Branded boot splash — the premium "brand beat" while the session cache
/// restores.
///
/// Design language (matches the login brand panel and the launcher icon):
/// the white FU FUT badge floats on the deep teal field, lifted by a soft
/// spotlight and a breathing glow, announcing itself with quiet sonar rings.
/// A faint oversized seal watermarks the bottom-right corner for depth, the
/// wordmark sits in tracked-out caps with a gold `COFFEE · POS` eyebrow, and
/// a three-dot pulse — not a stock spinner — signals that work is happening.
///
/// Continuity with the native launch screen (solid `#0B5551`, the midpoint
/// of this gradient — see the flutter_native_splash block in pubspec.yaml)
/// is preserved: same two anchor teals, so the handoff stays invisible.
///
/// Motion timeline: one 1s entrance cascade (spotlight bloom → badge settle
/// → wordmark → eyebrow → ornament → tagline → status), then three infinite
/// ambient loops (breathing glow + sonar rings, dot pulse, diamond glint).
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.hint = 'Restoring your session…'});

  /// One-line status under the bottom loader.
  final String hint;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  /// Entrance cascade — plays once.
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..forward();

  /// Ambient loops — breathing glow and sonar rings, 3s per cycle.
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3000),
  )..repeat();

  /// Loader dots — 1.3s wave, three phase-shifted dots.
  late final AnimationController _dots = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  // ── Entrance intervals ──────────────────────────────────────────────────
  late final Animation<double> _spot =
      _ease(const Interval(0.0, 0.5)); // spotlight + watermark bloom
  late final Animation<double> _sealFade = _ease(const Interval(0.05, 0.55));
  late final Animation<double> _sealScale = Tween(begin: 0.86, end: 1.0)
      .animate(CurvedAnimation(
          parent: _entrance, curve: const Interval(0.05, 0.62, curve: Curves.easeOutCubic)));
  late final Animation<double> _mark = _ease(const Interval(0.25, 0.7));
  late final Animation<Offset> _markSlide = Tween(
    begin: const Offset(0, 0.16),
    end: Offset.zero,
  ).animate(CurvedAnimation(
      parent: _entrance, curve: const Interval(0.25, 0.72, curve: Curves.easeOutCubic)));
  late final Animation<double> _eyebrow = _ease(const Interval(0.38, 0.78));
  late final Animation<double> _ornament = _ease(const Interval(0.48, 0.85));
  late final Animation<double> _tagline = _ease(const Interval(0.55, 0.9));
  late final Animation<double> _status = _ease(const Interval(0.65, 1.0));

  Animation<double> _ease(Interval interval) =>
      CurvedAnimation(parent: _entrance, curve: interval);

  @override
  void dispose() {
    _entrance.dispose();
    _ambient.dispose();
    _dots.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        // Under the Scaffold's loose body constraints a decorated Container
        // shrink-wraps to its content — the splash once rendered as a
        // ~152x255 card pinned to the top-left. Force full-bleed.
        constraints: const BoxConstraints.expand(),
        // Same gradient anchors as the login brand panel and the native
        // launch screen (teal-700 → teal-800).
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0C5F5B), Color(0xFF0A4A47)],
          ),
        ),
        child: SafeArea(
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Layered light, deliberately clean — no texture, no watermark:
              //   1. a brand glow rising from the top (lighter teal)
              //   2. a crisp radial stage light centered behind the badge
              //   3. a grounding shade along the bottom edge
              // The two glows ride fractional Alignments (not pixel offsets)
              // so they track the hero across phone and desktop aspect
              // ratios.
              Positioned.fill(
                child: IgnorePointer(
                  child: FadeTransition(
                    opacity: _spot,
                    child: const Stack(
                      children: [
                        // 1. Brand glow — a soft rise of lighter teal from
                        //    the top edge, giving the field color depth.
                        Align(
                          alignment: Alignment(0.0, -1.18),
                          child: SizedBox(
                            width: 720,
                            height: 500,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: RadialGradient(
                                  colors: [
                                    Color(0x2B2BB0A9), // ~17% light teal
                                    Color(0x002BB0A9),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        // 2. Stage light — tight, centered on the hero so
                        //    the badge reads as spotlit, not hazy.
                        Align(
                          alignment: Alignment(0.0, -0.2),
                          child: SizedBox(
                            width: 470,
                            height: 470,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: RadialGradient(
                                  colors: [
                                    Color(0x22FFFFFF), // ~13% white
                                    Color(0x00FFFFFF),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        // 2b. Gold counter-glow — the brand's accent color
                        //     breathing in from the bottom-right corner;
                        //     turns the flat teal into a two-tone field.
                        Align(
                          alignment: Alignment(0.95, 0.95),
                          child: IgnorePointer(
                            child: SizedBox(
                              width: 560,
                              height: 560,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: RadialGradient(
                                    colors: [
                                      Color(0x1AD6B36A), // ~10% brand gold
                                      Color(0x00D6B36A),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        // 3. Bottom shade — grounds the composition so the
                        //    lower third doesn't float away.
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment(0.0, -0.1), // only the lower third
                                colors: [
                                  Color(0x3804201E), // 22% deep shade
                                  Color(0x0004201E),
                                ],
                                stops: [0.0, 0.42],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Hero + wordmark + ornament, vertically centered.
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _hero(),
                  const SizedBox(height: 24),
                  FadeTransition(
                    opacity: _mark,
                    child: SlideTransition(
                      position: _markSlide,
                      child: _wordmark(),
                    ),
                  ),
                  const SizedBox(height: 9),
                  FadeTransition(
                    opacity: _eyebrow,
                    child: const Text('COFFEE · POS',
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFE4CB99), // goldLight
                            letterSpacing: 4.2)),
                  ),
                  const SizedBox(height: 20),
                  FadeTransition(opacity: _ornament, child: _ornamentBar()),
                  const SizedBox(height: 18),
                  FadeTransition(
                    opacity: _tagline,
                    child: Text(
                        'Authentic Ethiopian Coffee\n& Restaurant Management',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontFamily: kFontBody,
                            fontSize: 11.5,
                            height: 1.55,
                            color: Colors.white.withValues(alpha: 0.58))),
                  ),
                ],
              ),
              // Bottom: three-dot pulse + status line.
              Positioned(
                left: 0,
                right: 0,
                bottom: 46,
                child: FadeTransition(
                  opacity: _status,
                  child: Column(
                    children: [
                      _dotLoader(),
                      const SizedBox(height: 12),
                      Text(widget.hint,
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: Colors.white.withValues(alpha: 0.52),
                              letterSpacing: 0.4)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Hero: breathing glow + sonar rings + badge ──────────────────────────

  Widget _hero() {
    return SizedBox(
      width: 236,
      height: 236,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Sonar rings — two staggered circles expanding out of the badge.
          ...List.generate(2, (i) => _sonarRing(i)),
          // Breathing glow directly behind the badge.
          AnimatedBuilder(
            animation: _ambient,
            builder: (context, _) {
              final t = _ambient.value;
              final breath = 0.5 + 0.5 * math.sin(2 * math.pi * t);
              return Transform.scale(
                scale: 1.0 + 0.14 * breath,
                child: Container(
                  width: 204,
                  height: 204,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        Colors.white.withValues(alpha: 0.10 + 0.06 * breath),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          // The badge itself — the launcher-icon mark, settling in.
          FadeTransition(
            opacity: _sealFade,
            child: ScaleTransition(
              scale: _sealScale,
              child: Container(
                width: 134,
                height: 134,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                        color: Color(0x52000000),
                        blurRadius: 34,
                        offset: Offset(0, 14)),
                    BoxShadow(
                        color: Color(0x26000000),
                        blurRadius: 10,
                        offset: Offset(0, 4)),
                  ],
                ),
                child: Image.asset('assets/branding/splash_badge.png'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One sonar ring: expands 0.9×→1.5× while fading 9%→0%, phase-shifted by
  /// [index] so the two rings alternate. Only visible after the badge lands.
  Widget _sonarRing(int index) {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: Listenable.merge([_ambient, _entrance]),
        builder: (context, _) {
          final phase = (_ambient.value + index * 0.5) % 1.0;
          final gate = _entrance.value.clamp(0.0, 1.0);
          return Center(
            child: Transform.scale(
              scale: 0.9 + 0.62 * phase,
              child: Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white
                        .withValues(alpha: 0.09 * (1 - phase) * gate),
                    width: 1.2,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Wordmark ────────────────────────────────────────────────────────────

  Widget _wordmark() {
    return Column(
      children: [
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, Color(0xFFD8F0EE)], // white → pale teal
          ).createShader(bounds),
          child: const Text(
            'FU FUT',
            style: TextStyle(
              fontFamily: kFontBody,
              fontSize: 30,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              letterSpacing: 5.5,
              height: 1.1,
            ),
          ),
        ),
      ],
    );
  }

  // ── Ornament: fading hairlines around a glinting gold diamond ───────────

  Widget _ornamentBar() {
    return AnimatedBuilder(
      animation: _ambient,
      builder: (context, _) {
        final t = _ambient.value;
        final glint = 0.55 + 0.45 * math.sin(2 * math.pi * t);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _hairline(),
            const SizedBox(width: 10),
            Transform.rotate(
              angle: math.pi / 4,
              child: Container(
                width: 5.5,
                height: 5.5,
                decoration: BoxDecoration(
                  color: const Color(0xFFE4CB99)
                      .withValues(alpha: 0.55 + 0.4 * glint),
                  borderRadius: BorderRadius.circular(1),
                  boxShadow: [
                    BoxShadow(
                        color: const Color(0xFFE4CB99)
                            .withValues(alpha: 0.35 * glint),
                        blurRadius: 7,
                        spreadRadius: 0.5),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            _hairline(reverse: true),
          ],
        );
      },
    );
  }

  /// Hairline fading toward its outer end; [reverse] mirrors the gradient
  /// for the right-hand side.
  Widget _hairline({bool reverse = false}) {
    final a = Colors.white.withValues(alpha: 0.0);
    final b = Colors.white.withValues(alpha: 0.36);
    return Container(
      width: 44,
      height: 1,
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: reverse ? [b, a] : [a, b]),
      ),
    );
  }

  // ── Loader: three phase-shifted dots ────────────────────────────────────

  Widget _dotLoader() {
    return AnimatedBuilder(
      animation: _dots,
      builder: (context, _) {
        final t = _dots.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = (t * 1.0 - i * 0.22) % 1.0;
            final wave = 0.5 + 0.5 * math.sin(2 * math.pi * phase);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3.5),
              child: Transform.translate(
                offset: Offset(0, -2.5 * wave),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.3 + 0.55 * wave),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
