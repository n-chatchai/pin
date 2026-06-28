import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/widgets.dart';

import '../theme/pin_theme.dart';
import '../theme/theme_controller.dart';

enum _Variant { filled, text, outlined, key }

/// Premium, Material-free button matching the pin.html design system. No ripple —
/// a subtle press-scale + tone shift instead. Variants (design source of truth):
/// - filled   → `.auth-email` primary CTA: accent fill, h48, r11.
/// - outlined → `.auth-google` provider/secondary: white + line border, h48, r11.
/// - key      → `.key-acts` utility (copy/save/load): white + line, h40, r9,
///              compact, accent-tinted leading icon.
/// - text     → quiet tertiary action.
/// Replaces Material's FilledButton / TextButton / OutlinedButton.
class PinButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  final _Variant variant;
  final bool busy; // show a spinner + ignore taps
  final double height;
  final Widget? icon; // outlined/key leading icon

  const PinButton(this.label,
      {super.key, this.onTap, this.busy = false, this.height = 52})
      : variant = _Variant.filled,
        icon = null;

  const PinButton.text(this.label, {super.key, this.onTap, this.height = 44})
      : variant = _Variant.text,
        busy = false,
        icon = null;

  const PinButton.outlined(this.label,
      {super.key, this.onTap, this.icon, this.busy = false, this.height = 52})
      : variant = _Variant.outlined;

  const PinButton.key(this.label,
      {super.key, this.onTap, this.icon, this.busy = false, this.height = 44})
      : variant = _Variant.key;

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
    final v = widget.variant;
    final filled = v == _Variant.filled;
    final compact = v == _Variant.key;
    final bordered = v == _Variant.outlined || compact;

    final fg = filled
        ? const Color(0xFFFFFFFF)
        : (v == _Variant.text ? PinPalette.ink2 : PinPalette.ink);
    final bg = filled
        ? (enabled ? accent : accent.withValues(alpha: 0.45))
        : (bordered ? const Color(0xFFFFFFFF) : null);
    final radius = compact ? 9.0 : 11.0;
    final fontSize = compact ? 13.0 : 14.5;

    final label = Text(
      widget.label,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        color: filled ? fg.withValues(alpha: _down ? 0.85 : 1) : fg,
      ),
    );

    final Widget child;
    if (widget.busy) {
      child = CupertinoActivityIndicator(
          color: filled ? const Color(0xFFFFFFFF) : PinPalette.ink);
    } else if (bordered && widget.icon != null) {
      // key icons tint to the accent (design: green-d stroke); outlined icons
      // (e.g. the colored Google "G") keep their own colors.
      final icon = compact
          ? IconTheme.merge(
              data: IconThemeData(color: accent, size: 16),
              child: widget.icon!)
          : widget.icon!;
      child = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [icon, SizedBox(width: compact ? 6 : 8), label],
      );
    } else {
      child = label;
    }

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
          width: v == _Variant.text ? null : double.infinity,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(radius),
            border: bordered ? Border.all(color: PinPalette.line) : null,
          ),
          child: child,
        ),
      ),
    );
  }
}
