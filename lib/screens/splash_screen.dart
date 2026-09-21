import 'package:flutter/material.dart';

import '../theme.dart';

/// Branded boot splash shown while the session cache restores.
///
/// Carries the exact identity of the login brand panel — teal gradient,
/// ringed seal, FU FUT wordmark, tagline — and continues seamlessly from
/// the native launch screen (solid `#0B5551`, the midpoint of this
/// gradient — see the flutter_native_splash block in pubspec.yaml).
///
/// The seal scales in with an ease-out settle, the wordmark fades up after
/// it, and a quiet "restoring session" line sits at the bottom so the wait
/// reads as intent rather than stall.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.hint = 'Restoring your session…'});

  /// One-line status under the bottom spinner.
  final String hint;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  )..forward();

  /// Seal: fades in and settles from a slight zoom.
  late final Animation<double> _sealFade =
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.55));
  late final Animation<double> _sealScale = Tween(
    begin: 0.88,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.7)));

  /// Wordmark block follows the seal.
  late final Animation<double> _markFade =
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.25, 0.75));
  late final Animation<Offset> _markSlide = Tween(
    begin: const Offset(0, 0.18),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: const Interval(0.25, 0.8)));

  /// Bottom status arrives last.
  late final Animation<double> _statusFade =
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.55, 1.0));

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        // Under the Scaffold's loose body constraints a decorated Container
        // shrink-wraps to its content — the splash rendered as a ~152x255
        // card pinned to the top-left. Force full-bleed.
        constraints: const BoxConstraints.expand(),
        // Same gradient as the login brand panel (teal-700 → teal-800).
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
              // Center: seal + wordmark.
              FadeTransition(
                opacity: _markFade,
                child: SlideTransition(
                  position: _markSlide,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _seal(),
                      const SizedBox(height: 22),
                      const Text('FU FUT',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              letterSpacing: 1.1)),
                      const SizedBox(height: 6),
                      Text('COFFEE · POS',
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: Colors.white.withValues(alpha: 0.7),
                              letterSpacing: 2.8)),
                      const SizedBox(height: 18),
                      Container(
                          width: 36,
                          height: 2,
                          color: Colors.white.withValues(alpha: 0.25)),
                      const SizedBox(height: 18),
                      Text('Authentic Ethiopian Coffee\n& Restaurant Management',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 11.5,
                              height: 1.5,
                              color: Colors.white.withValues(alpha: 0.6))),
                    ],
                  ),
                ),
              ),
              // Bottom: status line with a quiet spinner.
              Positioned(
                left: 0,
                right: 0,
                bottom: 42,
                child: FadeTransition(
                  opacity: _statusFade,
                  child: Column(
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white.withValues(alpha: 0.8)),
                      ),
                      const SizedBox(height: 10),
                      Text(widget.hint,
                          style: TextStyle(
                              fontFamily: kFontBody,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: Colors.white.withValues(alpha: 0.55),
                              letterSpacing: 0.3)),
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

  Widget _seal() {
    return FadeTransition(
      opacity: _sealFade,
      child: ScaleTransition(
        scale: _sealScale,
        child: Container(
          width: 108,
          height: 108,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.2), width: 2.5),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x33000000), blurRadius: 24, offset: Offset(0, 8)),
            ],
          ),
          child: ClipOval(
            child: Image.asset('assets/images/logo.webp', fit: BoxFit.cover),
          ),
        ),
      ),
    );
  }
}

