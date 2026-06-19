import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/widgets.dart';

import '../theme/pin_theme.dart';
import '../theme/theme_controller.dart';

/// Premium, Material-free button. No ripple — a subtle press-scale + tone shift
/// instead (the iOS-leaning feel the app wants). Two variants: a filled accent
/// primary and a quiet text button. Replaces Material's FilledButton/TextButton.
class PinButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  final bool filled; // true = accent fill, false = quiet text
  final bool busy; // show a spinner + ignore taps
  final double height;

  const PinButton(this.label,
      {super.key,
      this.onTap,
      this.filled = true,
      this.busy = false,
      this.height = 56});

  const PinButton.text(this.label, {super.key, this.onTap, this.height = 44})
      : filled = false,
        busy = false;

  @override
  State<PinButton> createState() => _PinButtonState();
}

class _PinButtonState extends State<PinButton> {
  bool _down = false;

  void _set(bool v) {
    if (widget.onTap != null) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null && !widget.busy;
    final accent = ThemeController.instance.value.accent;
    final fg = widget.filled ? const Color(0xFFFFFFFF) : PinPalette.ink2;
    final bg = widget.filled
        ? (enabled ? accent : accent.withValues(alpha: 0.45))
        : null;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: enabled ? widget.onTap : null,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          height: widget.height,
          width: widget.filled ? double.infinity : null,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(16),
          ),
          child: widget.busy
              ? const CupertinoActivityIndicator(color: Color(0xFFFFFFFF))
              : Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: widget.filled ? 16 : 15,
                    fontWeight: FontWeight.w600,
                    color: widget.filled
                        ? fg.withValues(alpha: _down ? 0.85 : 1)
                        : fg,
                  ),
                ),
        ),
      ),
    );
  }
}
