import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../theme/pin_theme.dart';

/// Quiet one-tap language switch. The app auto-detects the device language on
/// first run, so this only ever offers the *other* language: in Thai it reads
/// "English", in English it reads "ไทย". A globe (not a flag) keeps it premium
/// and platform-neutral. Material-free.
class LangPick extends StatefulWidget {
  final String lang; // current: 'th' | 'en'
  final ValueChanged<String> onChanged;
  const LangPick({super.key, required this.lang, required this.onChanged});

  @override
  State<LangPick> createState() => _LangPickState();
}

class _LangPickState extends State<LangPick> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final toTh = widget.lang == 'en';
    final other = toTh ? 'th' : 'en';
    final label = toTh ? 'ไทย' : 'English';

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: () => widget.onChanged(other),
      child: AnimatedScale(
        scale: _down ? 0.96 : 1,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        child: Container(
          // Fixed size so the pill doesn't jump between "ไทย" and "English".
          width: 116,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFFFFFFF),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: PinPalette.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(LucideIcons.globe, size: 18, color: PinPalette.ink2),
              const SizedBox(width: 8),
              Text(label,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      height: 1.0,
                      color: PinPalette.ink2)),
            ],
          ),
        ),
      ),
    );
  }
}
