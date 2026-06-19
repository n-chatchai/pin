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
  final IconData icon;
  final bool obscure;
  final bool enabled;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmitted;

  const PinField({
    super.key,
    required this.controller,
    required this.placeholder,
    required this.icon,
    this.obscure = false,
    this.enabled = true,
    this.keyboardType,
    this.onChanged,
    this.onSubmitted,
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
        borderRadius: BorderRadius.circular(16),
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
        onChanged: widget.onChanged,
        onSubmitted:
            widget.onSubmitted == null ? null : (_) => widget.onSubmitted!(),
        placeholder: widget.placeholder,
        placeholderStyle: const TextStyle(color: PinPalette.ink3, fontSize: 16),
        style: const TextStyle(color: PinPalette.ink, fontSize: 16),
        cursorColor: accent,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
        prefix: Padding(
          padding: const EdgeInsets.only(left: 14),
          child: Icon(widget.icon, size: 20, color: PinPalette.ink2),
        ),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _focused ? accent : const Color(0xFFE7E0D1),
            width: _focused ? 1.6 : 1,
          ),
        ),
      ),
    );
  }
}
