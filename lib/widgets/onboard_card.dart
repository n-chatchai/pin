import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../theme/pin_theme.dart';
import '../theme/theme_controller.dart';

/// Inline cards shown during the conversational onboarding demos (reminder /
/// news result, trip-summary carousel, theme picker). Driven by a plain spec
/// map on a local [ChatViewMessage]; never synced to the room.
class OnboardCard extends StatelessWidget {
  final Map<String, dynamic> spec;
  final ValueChanged<Map<String, String>>? onAction;
  const OnboardCard({super.key, required this.spec, this.onAction});

  @override
  Widget build(BuildContext context) {
    // Onboarding inline elements: the theme picker (final step) and tappable
    // option groups (chips / tone grid / address pills). No mock demo cards.
    switch (spec['type']) {
      case 'theme':
        return _ThemePicker(onAction: onAction);
      case 'options':
        return _OnboardOptions(spec: spec, onAction: onAction);
      default:
        return const SizedBox.shrink();
    }
  }
}

/// Inline tappable options rendered in the chat feed (design: chips / tone grid
/// / address pills — NOT the quick-reply bar). One-shot: tapping fires onAction.
class _OnboardOptions extends StatelessWidget {
  final Map<String, dynamic> spec;
  final ValueChanged<Map<String, String>>? onAction;
  const _OnboardOptions({required this.spec, this.onAction});

  List<Map<String, String>> get _opts => [
        for (final o in (spec['options'] as List? ?? const []))
          {for (final e in (o as Map).entries) '${e.key}': '${e.value}'}
      ];

  void _tap(Map<String, String> o) => onAction?.call(o);

  @override
  Widget build(BuildContext context) {
    final kind = spec['kind'];
    final pad = const EdgeInsets.fromLTRB(16, 2, 16, 6);
    if (kind == 'tone') {
      return Padding(padding: pad, child: _toneGrid(context));
    }
    // chips / addr: a left-aligned wrap of pills.
    return Padding(
      padding: pad,
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [for (final o in _opts) _pill(context, o)],
      ),
    );
  }

  Widget _pill(BuildContext context, Map<String, String> o) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => _tap(o),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.primary.withValues(alpha: 0.55)),
          boxShadow: const [
            BoxShadow(
                color: Color(0x0F000000), blurRadius: 6, offset: Offset(0, 2)),
          ],
        ),
        child: Text(o['label'] ?? '',
            style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: scheme.secondary)),
      ),
    );
  }

  Widget _toneGrid(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, c) {
      final w = (c.maxWidth - 12) / 2;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final o in _opts)
            GestureDetector(
              onTap: () => _tap(o),
              child: Container(
                width: w,
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: PinPalette.line),
                  boxShadow: const [
                    BoxShadow(
                        color: Color(0x0F000000),
                        blurRadius: 6,
                        offset: Offset(0, 2)),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(o['label'] ?? '',
                        style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: PinPalette.ink)),
                    const SizedBox(height: 4),
                    Text(o['sub'] ?? '',
                        style: TextStyle(
                            fontSize: 11.5, color: scheme.secondary)),
                  ],
                ),
              ),
            ),
        ],
      );
    });
  }
}

/// Theme swatch row — live-applies the palette on tap (ThemeController is a
/// singleton). Picking a swatch also finishes onboarding via [onAction] (v2:
/// no separate "done" button).
class _ThemePicker extends StatelessWidget {
  final ValueChanged<Map<String, String>>? onAction;
  const _ThemePicker({this.onAction});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PinPalette>(
      valueListenable: ThemeController.instance,
      builder: (context, current, _) => Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Wrap(
          spacing: 16,
          runSpacing: 12,
          children: [
            for (final p in PinPalette.all)
              GestureDetector(
                onTap: () {
                  ThemeController.instance.select(p.key);
                  onAction?.call({'value': 'done'});
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: p.accent,
                        shape: BoxShape.circle,
                        boxShadow: [
                          if (p.key == current.key)
                            const BoxShadow(
                                color: Colors.white,
                                spreadRadius: 3,
                                blurRadius: 0),
                          if (p.key == current.key)
                            const BoxShadow(
                                color: PinPalette.ink,
                                spreadRadius: 5,
                                blurRadius: 0),
                        ],
                      ),
                      child: p.key == current.key
                          ? const Icon(PhosphorIconsBold.check,
                              color: Colors.white, size: 20)
                          : null,
                    ),
                    const SizedBox(height: 7),
                    Text(p.name,
                        style: const TextStyle(
                            fontSize: 13, color: PinPalette.ink2)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
