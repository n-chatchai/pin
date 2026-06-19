import 'package:flutter/material.dart';

import '../theme/pin_theme.dart';

/// Branded cold-start loader: the ปิ่น logo centred, with a Claude-Code-style
/// single-line status at the centre-bottom — a fixed-width spinner glyph cycles
/// while the text stays put (never shifts).
class BootLoading extends StatefulWidget {
  final String message;
  const BootLoading(this.message, {super.key});

  @override
  State<BootLoading> createState() => _BootLoadingState();
}

class _BootLoadingState extends State<BootLoading>
    with SingleTickerProviderStateMixin {
  static const _frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          // Centre: logo.
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.asset('assets/pin-logo.png',
                  width: 72, height: 72, fit: BoxFit.cover),
            ),
          ),
          // Centre-bottom: spinner + fixed status text.
          Align(
            alignment: const Alignment(0, 0.82),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 18,
                  child: AnimatedBuilder(
                    animation: _c,
                    builder: (_, __) {
                      final f = _frames[(_c.value * _frames.length).floor() %
                          _frames.length];
                      return Text(
                        f,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 15, color: scheme.secondary),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  widget.message,
                  style: const TextStyle(fontSize: 14, color: PinPalette.ink2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
