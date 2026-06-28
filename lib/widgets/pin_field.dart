import 'package:flutter/cupertino.dart';

import '../theme/pin_theme.dart';
import '../theme/theme_controller.dart';

/// Material-free text field. Built on [CupertinoTextField] (no Material ripple,
/// no floating-label animation) and dressed as a premium ปิ่น field: a raised
/// white card with a hairline that turns to the accent ring on focus, a leading
/// icon, and a quiet placeholder. Replaces Material's TextField/InputDecoration.
class PinField extends StatefulWidget {
  final TextEditingController controller;
  final String placeholder;
  final IconData? icon; // optional leading icon
  final bool obscure;
  final bool enabled;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmitted;
  final int minLines;
  final int maxLines;
  final bool monospace; // for keys / codes

  const PinField({
    super.key,
    required this.controller,
    required this.placeholder,
    this.icon,
    this.obscure = false,
    this.enabled = true,
    this.keyboardType,
    this.onChanged,
    this.onSubmitted,
    this.minLines = 1,
    this.maxLines = 1,
    this.monospace = false,
  });

  @override
  State<PinField> createState() => _PinFieldState();
}

class _PinFieldState extends State<PinField> {
  final _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() => _focused = _focus.hasFocus));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = ThemeController.instance.value.accent;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6B5E45).withValues(alpha: 0.10),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: CupertinoTextField(
        controller: widget.controller,
        focusNode: _focus,
        enabled: widget.enabled,
        obscureText: widget.obscure,
        keyboardType: widget.keyboardType,
        autocorrect: false,
        minLines: widget.minLines,
        maxLines: widget.obscure ? 1 : widget.maxLines,
        onChanged: widget.onChanged,
        onSubmitted:
            widget.onSubmitted == null ? null : (_) => widget.onSubmitted!(),
        placeholder: widget.placeholder,
        placeholderStyle: const TextStyle(color: PinPalette.ink3, fontSize: 16),
        style: TextStyle(
            color: PinPalette.ink,
            fontSize: 16,
            fontFamily: widget.monospace ? 'monospace' : null),
        cursorColor: accent,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        prefix: widget.icon == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Icon(widget.icon, size: 20, color: PinPalette.ink2),
              ),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: _focused ? accent : const Color(0xFFE7E0D1),
            width: _focused ? 1.6 : 1,
          ),
        ),
      ),
    );
  }
}
