import 'dart:ui';

import 'package:flutter/material.dart';

/// Luminance-preserving saturation matrix. >1 pops the backdrop's colours
/// through the glass (Apple "vibrancy") so the blur reads vivid, not grey.
ColorFilter _vibrancy(double s) {
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final inv = 1 - s;
  final r = inv * lr, g = inv * lg, b = inv * lb;
  return ColorFilter.matrix(<double>[
    r + s, g, b, 0, 0,
    r, g + s, b, 0, 0,
    r, g, b + s, 0, 0,
    0, 0, 0, 1, 0,
  ]);
}

/// Blur + vibrancy in one backdrop filter (saturate, then blur).
ImageFilter _glassFilter(double blur, double saturation) => ImageFilter.compose(
      outer: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
      inner: _vibrancy(saturation),
    );

/// iOS 26-style "liquid glass": a frosted, translucent surface that blurs and
/// brightens whatever scrolls behind it, finished with a bright top highlight
/// and a hairline edge so it reads as a floating pane of glass. Used for the
/// floating chat chrome (composer + fab buttons) that sits over scrolling
/// content.
class LiquidGlass extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final double blur;
  final EdgeInsetsGeometry? padding;

  /// Base glass tint strength (0–1). Higher = more opaque / less see-through.
  final double opacity;

  /// Edge hairline colour. Default is a bright white highlight; pass a soft grey
  /// (e.g. PinPalette.line) for a defined, "lifted" card edge like Claude's.
  final Color? borderColor;

  /// Drop-shadow strength multiplier (1 = default soft lift).
  final double elevation;

  /// Backdrop colour pop (1 = none). >1 = Apple vibrancy so the blur reads
  /// vivid instead of flat grey.
  final double saturation;

  const LiquidGlass({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.blur = 22,
    this.padding,
    this.opacity = 0.55,
    this.borderColor,
    this.elevation = 1,
    this.saturation = 1.5,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: _glassFilter(blur, saturation),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            // Gentle top-to-bottom sheen: a touch brighter up top where light
            // catches the edge, settling to the base tint below. Subtle beats a
            // hard diagonal — the latter reads as "painted gradient", not glass.
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withValues(alpha: (opacity + 0.10).clamp(0, 1)),
                Colors.white.withValues(alpha: (opacity - 0.04).clamp(0, 1)),
              ],
            ),
            border: Border.all(
              color: borderColor ?? Colors.white.withValues(alpha: 0.45),
              width: borderColor != null ? 1 : 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: Color.fromRGBO(40, 40, 34, 0.13 * elevation),
                blurRadius: 22 * elevation,
                offset: Offset(0, -2 * elevation),
              ),
              BoxShadow(
                color: Color.fromRGBO(40, 40, 34, 0.10 * elevation),
                blurRadius: 16 * elevation,
                offset: Offset(0, 6 * elevation),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Circular liquid-glass variant for floating action buttons.
class LiquidGlassCircle extends StatelessWidget {
  final Widget child;
  final double size;
  final VoidCallback? onTap;
  final double blur;

  const LiquidGlassCircle({
    super.key,
    required this.child,
    this.size = 42,
    this.onTap,
    this.blur = 16,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Color(0x2E282822),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ClipOval(
        child: BackdropFilter(
          filter: _glassFilter(blur, 1.5),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.70),
                  Colors.white.withValues(alpha: 0.42),
                ],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.60),
                width: 0.8,
              ),
            ),
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: Center(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
