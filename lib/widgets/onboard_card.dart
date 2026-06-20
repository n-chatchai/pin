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
    final scheme = Theme.of(context).colorScheme;
    // Uniform icon chip (brand primary tint + secondary glyph) — matches the
    // app's flex-card header across reminder / news / weather.
    final chip = scheme.primary.withValues(alpha: 0.15);
    switch (spec['type']) {
      case 'reminder':
        return _result(context, PhosphorIconsRegular.bell, scheme.secondary, chip);
      case 'news':
        return _result(
            context, PhosphorIconsRegular.newspaper, scheme.secondary, chip);
      case 'weather':
        return _result(
            context, PhosphorIconsRegular.cloudSun, scheme.secondary, chip);
      case 'trip':
        return _trip(context);
      case 'theme':
        return _ThemePicker(onAction: onAction);
      case 'voice_hint':
        return _voiceHint(context);
      case 'options':
        return _OnboardOptions(spec: spec, onAction: onAction);
      default:
        return const SizedBox.shrink();
    }
  }

  // Reminder / news / weather: icon chip + title + subtitle. Matches the app's
  // flex-card header idiom (rounded-square icon chip, brand title).
  Widget _result(
      BuildContext context, IconData icon, Color iconColor, Color iconBg) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 80, 4),
      padding: const EdgeInsets.all(12),
      decoration: _cardBox,
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
                color: iconBg, borderRadius: BorderRadius.circular(9)),
            child: Icon(icon, color: iconColor, size: 18),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${spec['title'] ?? ''}',
                    style:
                        PinPalette.brand(size: 15.5, color: scheme.secondary)),
                const SizedBox(height: 1),
                Text('${spec['sub'] ?? ''}',
                    style: const TextStyle(fontSize: 12, color: PinPalette.ink2)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Trip summary: horizontal-scroll day cards (one per day).
  Widget _trip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final days = (spec['days'] as List?) ?? const [];
    return SizedBox(
      height: 164,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
        itemCount: days.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final day = days[i] as Map;
          final items = (day['items'] as List?) ?? const [];
          return Container(
            width: 198,
            decoration: _cardBox,
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  color: scheme.surfaceContainerHighest,
                  child: Text('${day['d'] ?? ''} · เชียงใหม่',
                      style:
                          PinPalette.brand(size: 14.5, color: scheme.secondary)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Column(
                    children: [
                      for (var j = 0; j < items.length; j++)
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          decoration: BoxDecoration(
                            border: j < items.length - 1
                                ? const Border(
                                    bottom: BorderSide(
                                        color: PinPalette.line, width: 0.5))
                                : null,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${j + 1}',
                                  style: TextStyle(
                                      color: scheme.secondary,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text('${items[j]}',
                                    style: const TextStyle(
                                        fontSize: 13, color: Color(0xFF3A443E))),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // Voice step: display-only example phrases (the real composer mic drives it).
  Widget _voiceHint(BuildContext context) {
    final examples = (spec['examples'] as List?) ?? const [];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 60, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 2, bottom: 6),
            child: Text('ลองพูดว่า:',
                style: TextStyle(fontSize: 12, color: PinPalette.ink3)),
          ),
          for (final e in examples)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: PinPalette.line),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(PhosphorIconsRegular.microphone,
                      size: 17, color: PinPalette.ink2),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text('"$e"',
                        style: const TextStyle(
                            fontSize: 14,
                            fontStyle: FontStyle.italic,
                            color: PinPalette.ink)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // Matches the app flex-card shell (design --cardsh): radius 14, hairline
  // border, two-layer soft shadow.
  static final _cardBox = BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(14),
    border: Border.all(color: PinPalette.line),
    boxShadow: const [
      BoxShadow(color: Color(0x0D282822), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x0B282822), blurRadius: 14, offset: Offset(0, 5)),
    ],
  );
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
