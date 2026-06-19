import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/pin_theme.dart';

/// Lightweight floating toast bubble — replaces Material SnackBars, which
/// covered the composer with a full-width bar. A rounded pill that slides up
/// into view above the bottom chrome, holds, then auto slides back down.
class PinToast {
  static OverlayEntry? _current;

  static void show(BuildContext context, String message) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    _current?.remove();
    _current = null;

    final mq = MediaQuery.of(context);
    // Rest just above the home indicator / keyboard, hugging the bottom edge.
    final restBottom = mq.viewInsets.bottom +
        (mq.viewInsets.bottom > 0 ? 12 : mq.padding.bottom + 16);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ToastView(
        message: message,
        bottom: restBottom,
        onGone: () {
          entry.remove();
          if (_current == entry) _current = null;
        },
      ),
    );
    overlay.insert(entry);
    _current = entry;
  }
}

class _ToastView extends StatefulWidget {
  final String message;
  final double bottom;
  final VoidCallback onGone;
  const _ToastView({
    required this.message,
    required this.bottom,
    required this.onGone,
  });

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );
  late final Animation<double> _anim =
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  Timer? _hold;

  @override
  void initState() {
    super.initState();
    _c.forward(); // slide up + fade in
    _hold = Timer(const Duration(milliseconds: 2000), _dismiss);
  }

  Future<void> _dismiss() async {
    if (!mounted) return;
    await _c.reverse(); // slide down + fade out
    widget.onGone();
  }

  @override
  void dispose() {
    _hold?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 24,
      right: 24,
      bottom: widget.bottom,
      child: IgnorePointer(
        child: Center(
          child: AnimatedBuilder(
            animation: _anim,
            builder: (_, child) => Opacity(
              opacity: Curves.easeOut.transform(_anim.value.clamp(0, 1)),
              child: Transform.translate(
                // Slide up from below the screen edge into its resting spot.
                offset: Offset(0, 90 * (1 - _anim.value)),
                child: child,
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: PinPalette.ink,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [
                    BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 12,
                        offset: Offset(0, 4)),
                  ],
                ),
                child: Text(
                  widget.message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13.5, height: 1.3),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
