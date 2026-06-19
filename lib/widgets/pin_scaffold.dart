import 'package:flutter/widgets.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/pin_theme.dart';

/// Material-free page shell. Replaces Material's `Scaffold`: cream background,
/// optional safe-area, and — crucially — a [DefaultTextStyle] so bare [Text]
/// widgets get the app body font (Sarabun) with no decoration. Without a
/// Material/DefaultTextStyle ancestor, Flutter paints text with the debug
/// yellow underline; this provides the proper base so that never happens.
class PinScaffold extends StatelessWidget {
  final Widget child;
  final Color? background;
  final bool safeArea;

  const PinScaffold({
    super.key,
    required this.child,
    this.background,
    this.safeArea = true,
  });

  @override
  Widget build(BuildContext context) {
    final body = DefaultTextStyle(
      style: GoogleFonts.sarabun(
        fontSize: 16,
        color: PinPalette.ink,
        decoration: TextDecoration.none,
      ),
      child: child,
    );
    return ColoredBox(
      color: background ?? PinPalette.cream,
      child: safeArea ? SafeArea(child: body) : body,
    );
  }
}
