import 'package:flutter/material.dart';

import '../theme/pin_theme.dart';
import '../theme/theme_controller.dart';

/// Bottom sheet to pick one of the five ปิ่น themes (design: floating menu /
/// settings → ธีมสี).
Future<void> showThemePicker(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ValueListenableBuilder<PinPalette>(
        valueListenable: ThemeController.instance,
        builder: (context, current, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text('ธีมสี', style: PinPalette.brand(size: 18)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final p in PinPalette.all)
                    _Swatch(
                      palette: p,
                      selected: p.key == current.key,
                      onTap: () => ThemeController.instance.select(p.key),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    ),
  );
}

class _Swatch extends StatelessWidget {
  final PinPalette palette;
  final bool selected;
  final VoidCallback onTap;

  const _Swatch({
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: SizedBox(
        width: 84,
        child: Column(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: palette.accent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? PinPalette.ink : Colors.transparent,
                  width: 3,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check, color: Colors.white, size: 22)
                  : null,
            ),
            const SizedBox(height: 6),
            Text(palette.name, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
