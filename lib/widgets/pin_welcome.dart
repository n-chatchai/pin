import 'package:flutter/material.dart';

import '../theme/pin_theme.dart';

/// One-shot welcome shown the moment onboarding finishes (right after the theme
/// swatch is picked): the ปิ่น mark fades up, the greeting rises under it in the
/// brand serif, it holds, then the whole thing fades out and [onDone] fires.
///
/// Adapts to the user's persona: [name] + [ending] (ค่ะ/ครับ/นะ/…) and the
/// chosen [accent] colour the headline.
class PinWelcome extends StatefulWidget {
  final String name;
  final String ending; // bare particle, e.g. 'ค่ะ' / 'ครับ' / '' (neutral)
  final Color accent;
  final VoidCallback onDone;

  const PinWelcome({
    super.key,
    required this.name,
    required this.ending,
    required this.accent,
    required this.onDone,
  });

  @override
  State<PinWelcome> createState() => _PinWelcomeState();
}

class _PinWelcomeState extends State<PinWelcome>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..forward();

  // Sub-phases carved out of the single 2.6s timeline.
  late final _logo = CurvedAnimation(
      parent: _c, curve: const Interval(0.0, 0.30, curve: Curves.easeOutCubic));
  late final _text = CurvedAnimation(
      parent: _c, curve: const Interval(0.18, 0.46, curve: Curves.easeOut));
  late final _exit = CurvedAnimation(
      parent: _c, curve: const Interval(0.84, 1.0, curve: Curves.easeIn));

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ending = widget.ending.trim();
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        return Opacity(
          opacity: 1 - _exit.value, // hold at 1, fade out only at the tail
          child: Container(
            color: PinPalette.cream,
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Opacity(
                  opacity: _logo.value,
                  child: Transform.translate(
                    offset: Offset(0, 12 * (1 - _logo.value)),
                    child: Transform.scale(
                      scale: 0.95 + 0.05 * _logo.value,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(23),
                        child: Image.asset('assets/pin-logo.png',
                            width: 88, height: 88, fit: BoxFit.cover),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Opacity(
                  opacity: _text.value,
                  child: Transform.translate(
                    offset: Offset(0, 14 * (1 - _text.value)),
                    child: Column(
                      children: [
                        Text.rich(
                          TextSpan(children: [
                            TextSpan(
                                text: widget.name,
                                style: PinPalette.brand(
                                    size: 21, color: widget.accent)),
                            TextSpan(
                                text: ending.isEmpty
                                    ? 'พร้อมแล้ว!'
                                    : 'พร้อมแล้ว $ending!',
                                style: PinPalette.brand(
                                    size: 21, color: PinPalette.ink)),
                          ]),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 4),
                        Text('มาเริ่มคุยกันเลย',
                            style: PinPalette.brand(
                                size: 14, color: PinPalette.ink2)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
