import 'dart:ui';

import 'package:flutter/material.dart';

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

  const LiquidGlass({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.blur = 18,
    this.padding,
    this.opacity = 0.55,
    this.borderColor,
    this.elevation = 1,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            // Diagonal sheen: brighter top-left, thinner bottom-right.
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: (opacity + 0.14).clamp(0, 1)),
                Colors.white.withValues(alpha: (opacity - 0.10).clamp(0, 1)),
              ],
            ),
            border: Border.all(
              color: borderColor ?? Colors.white.withValues(alpha: 0.55),
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
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
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
