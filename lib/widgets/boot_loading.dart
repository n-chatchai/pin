import 'package:flutter/material.dart';

import '../theme/pin_theme.dart';

/// Branded loader visual (design/welcome-anim.html · stage 1): the ปิ่น mark
/// pops in with a little overshoot then breathes gently, while [message] gets a
/// left→right shimmer sweep. Fills its parent with the cream background so it can
/// sit over content and fade out when loading is done. No Scaffold — see
/// [BootLoading] for the full-screen cold-start wrapper.
class PinLoader extends StatefulWidget {
  final String message;
  const PinLoader(this.message, {super.key});

  @override
  State<PinLoader> createState() => _PinLoaderState();
}

class _PinLoaderState extends State<PinLoader> with TickerProviderStateMixin {
  // Pop: scale/rotate/opacity in once, with a back-ease overshoot.
  late final _popC = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..forward();
  late final _pop = CurvedAnimation(
      parent: _popC, curve: const Cubic(0.2, 1.5, 0.4, 1.0));

  // Breathe: 1→1.055→1, starts once the pop settles.
  late final _breatheC = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000), // ช้าลง
  );

  // Shimmer: a highlight band sliding across the status text, forever.
  late final _shimmerC = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3000), // ช้าลง
  )..repeat();

  @override
  void initState() {
    super.initState();
    _popC.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        _breatheC.repeat(reverse: true);
      }
    });
  }

  @override
  void dispose() {
    _popC.dispose();
    _breatheC.dispose();
    _shimmerC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Stack(
        children: [
          Center(
            child: AnimatedBuilder(
              animation: Listenable.merge([_popC, _breatheC]),
              builder: (_, child) {
                final breathe = 1 + 0.055 * _breatheC.value;
                return Opacity(
                  opacity: _pop.value.clamp(0.0, 1.0),
                  child: Transform.rotate(
                    angle: -0.21 * (1 - _pop.value), // -12deg → 0
                    child: Transform.scale(
                      scale: _pop.value * breathe,
                      child: child,
                    ),
                  ),
                );
              },
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(23),
                  boxShadow: [
                    BoxShadow(
                        color: accent.withValues(alpha: 0.34),
                        blurRadius: 22,
                        offset: const Offset(0, 8)),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(23),
                  child: Image.asset('assets/pin-logo.png',
                      width: 88, height: 88, fit: BoxFit.cover),
                ),
              ),
            ),
          ),
          Align(
            alignment: const Alignment(0, 0.7),
            child: AnimatedBuilder(
              animation: _shimmerC,
              builder: (_, child) => ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (rect) => LinearGradient(
                  colors: const [PinPalette.ink3, PinPalette.ink, PinPalette.ink3],
                  stops: const [0.35, 0.5, 0.65],
                  transform: _SlideGradient(_shimmerC.value * 2 - 1),
                ).createShader(rect),
                child: child,
              ),
              child: Text(
                widget.message,
                style: PinPalette.brand(size: 15).copyWith(
                  decoration: TextDecoration.none, // แก้ปัญหาขีดเส้นใต้สีเหลืองเวลาอยู่นอก Scaffold
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen branded cold-start loader (app boot). Thin Scaffold wrapper
/// around [PinLoader].
class BootLoading extends StatelessWidget {
  final String message;
  const BootLoading(this.message, {super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: PinLoader(message),
      );
}

/// Shifts a gradient horizontally by [dx] (fraction of the shader width, so the
/// highlight band travels off both edges as dx runs −1→1).
class _SlideGradient extends GradientTransform {
  final double dx;
  const _SlideGradient(this.dx);
  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * dx, 0, 0);
}
