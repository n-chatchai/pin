import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../theme/pin_theme.dart';
import 'html_view.dart';

/// Renders a ปิ่น Flex card from its JSON spec (`io.tokens2.flex`).
/// LINE-Flex-inspired: a header + a list of components + optional footer.
/// Designed to match the card archetypes in design/pin.html.
class FlexCardView extends StatelessWidget {
  final Map<String, dynamic> spec;

  /// Postback handler: called with the button's `action.data`.
  final ValueChanged<String>? onAction;

  /// Fill the parent's height (carousel cards) so the footer pins to the bottom.
  final bool fill;

  const FlexCardView(
      {super.key, required this.spec, this.onAction, this.fill = false});

  @override
  Widget build(BuildContext context) {
    // Carousel: a horizontal, swipeable row of cards.
    final cards = spec['carousel'] as List?;
    if (cards != null && cards.isNotEmpty) {
      // A single "carousel" is just one card → render it full width.
      if (cards.length == 1) {
        return FlexCardView(
            spec: (cards.first as Map).cast<String, dynamic>(),
            onAction: onAction);
      }
      final w = MediaQuery.of(context).size.width;
      return SizedBox(
        height: 252,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          itemCount: cards.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          // ~75% so the next card peeks in → user sees there's more to swipe.
          itemBuilder: (context, i) => SizedBox(
            width: w * 0.75,
            child: FlexCardView(
                spec: (cards[i] as Map).cast<String, dynamic>(),
                onAction: onAction,
                fill: true),
          ),
        ),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final header = spec['header'] as Map<String, dynamic>?;
    final body = (spec['body'] as List?) ?? const [];
    final footer = spec['footer'] as Map<String, dynamic>?;

    return Container(
      // Single card → fill the bubble width.
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.92,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PinPalette.line),
        // Two-layer soft shadow (design --cardsh): a tight contact shadow + a
        // wider ambient one → the card feels lifted, not stamped on.
        boxShadow: const [
          BoxShadow(
              color: Color(0x0D282822), blurRadius: 2, offset: Offset(0, 1)),
          BoxShadow(
              color: Color(0x0B282822), blurRadius: 14, offset: Offset(0, 5)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        // In a carousel every card fills the fixed slot height so the footer
        // pins to the bottom → footers line up across cards of varying content.
        mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
        children: [
          if (header != null) _Header(header: header),
          _bodyBlock(context, body, scheme),
          if (footer != null) _Footer(footer: footer, onAction: onAction),
        ],
      ),
    );
  }

  Widget _bodyBlock(
      BuildContext context, List body, ColorScheme scheme) {
    final inner = Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in body)
            _component(context, c as Map<String, dynamic>, scheme),
        ],
      ),
    );
    if (!fill) return inner;
    // Take the space between header and footer. Scrollable so a long summary is
    // never cut — the user can swipe up within the card to read the rest
    // (footer stays pinned at the bottom).
    return Expanded(
      child: SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: inner,
      ),
    );
  }

  Widget _component(
      BuildContext context, Map<String, dynamic> c, ColorScheme scheme) {
    final type = c['type'] as String? ?? 'text';
    switch (type) {
      case 'text':
        return _text(c, scheme);
      case 'task':
        return _task(c, scheme);
      case 'agenda':
        return _agenda(c, scheme);
      case 'kv':
        return _kv(c, scheme);
      case 'bignum':
        return _bignum(c, scheme);
      case 'progress':
        return _progress(c, scheme);
      case 'watchitem':
        return _watchItem(c, scheme);
      case 'divider':
        return const Divider(height: 16, color: PinPalette.line);
      case 'button':
        return _button(c, scheme);
      case 'bars':
        return _bars(c, scheme);
      case 'gauge':
        return _gauge(c, scheme);
      case 'line':
        return _line(c, scheme);
      case 'html':
        return HtmlView('${c['html'] ?? ''}');
      default:
        return const SizedBox.shrink();
    }
  }

  Color _semantic(String? token, ColorScheme scheme) {
    switch (token) {
      case 'pos':
        return const Color(0xFF2E9E63);
      case 'neg':
        return PinPalette.neg;
      case 'accent':
        return scheme.primary;
      case 'muted':
        return PinPalette.ink2;
      default:
        return PinPalette.ink;
    }
  }

  Widget _text(Map<String, dynamic> c, ColorScheme scheme) {
    final style = c['style'] as String? ?? 'body';
    final color = _semantic(c['color'] as String?, scheme);
    final ts = switch (style) {
      'title' => TextStyle(
          fontSize: 16, fontWeight: FontWeight.w700, color: color),
      'muted' => TextStyle(fontSize: 13, color: PinPalette.ink2),
      _ => TextStyle(fontSize: 14, color: color),
    };
    final maxLines = c['maxLines'] as int?;
    final text = '${c['text'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      // Render markdown (**bold**, lists, links) like the chat bubble. A truncated
      // block (maxLines set) stays plain Text — GptMarkdown can't ellipsis.
      child: maxLines != null
          ? Text(text,
              style: ts, maxLines: maxLines, overflow: TextOverflow.ellipsis)
          : _markdown(text, ts),
    );
  }

  /// GptMarkdown with heading sizes CAPPED near the card typography, so a `#`/`##`
  /// in the body doesn't dwarf the card's own title.
  Widget _markdown(String text, TextStyle ts) => GptMarkdownTheme(
        // Markdown headings stay BELOW the card title (brand 15.5) — the card
        // title is the dominant heading; in-body headings are subordinate.
        gptThemeData: GptMarkdownThemeData(
          brightness: Brightness.light,
          h1: ts.copyWith(fontSize: 14, fontWeight: FontWeight.w700),
          h2: ts.copyWith(fontSize: 13, fontWeight: FontWeight.w700),
          h3: ts.copyWith(fontSize: 13, fontWeight: FontWeight.w700),
          h4: ts.copyWith(fontWeight: FontWeight.w700),
          h5: ts.copyWith(fontWeight: FontWeight.w700),
          h6: ts.copyWith(fontWeight: FontWeight.w700),
        ),
        child: GptMarkdown(text, style: ts),
      );

  /// A watch/briefing row: tinted icon chip + topic (bold) over its finding.
  /// Matches the "ตอนนี้" row rhythm; used by the daily digest + immediate cards.
  Widget _watchItem(Map<String, dynamic> c, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(_iconFor('${c['icon'] ?? 'news'}'),
                size: 19, color: scheme.secondary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${c['topic'] ?? ''}',
                    style: PinPalette.brand(size: 14.5, color: PinPalette.ink)),
                if ('${c['finding'] ?? ''}'.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('${c['finding']}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, height: 1.45, color: PinPalette.ink2)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _task(Map<String, dynamic> c, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Chip(label: '${c['tag'] ?? ''}', scheme: scheme),
          const SizedBox(width: 8),
          Expanded(
            child: Text('${c['text'] ?? ''}',
                style: const TextStyle(fontSize: 14, color: PinPalette.ink)),
          ),
          if (c['due'] != null)
            Text('${c['due']}',
                style: const TextStyle(fontSize: 12, color: PinPalette.ink2)),
        ],
      ),
    );
  }

  Widget _agenda(Map<String, dynamic> c, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text('${c['time'] ?? ''}',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.secondary)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text('${c['text'] ?? ''}',
                style: const TextStyle(fontSize: 14, color: PinPalette.ink)),
          ),
        ],
      ),
    );
  }

  Widget _kv(Map<String, dynamic> c, ColorScheme scheme) {
    final vColor = _semantic(c['color'] as String?, scheme);
    final hasColor = c['color'] != null && c['color'] != 'muted';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A small accent tick gives the row a left anchor and rhythm.
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 9),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.45),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 0.5),
              child: Text('${c['k'] ?? ''}',
                  style: const TextStyle(fontSize: 14, color: PinPalette.ink2)),
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${c['v'] ?? ''}',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: hasColor ? vColor : PinPalette.ink)),
              if (c['sub'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text('${c['sub']}',
                      style: const TextStyle(
                          fontSize: 11.5, color: PinPalette.ink3)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bignum(Map<String, dynamic> c, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${c['value'] ?? ''}',
                  style: PinPalette.brand(size: 30)),
              if (c['delta'] != null) ...[
                const SizedBox(width: 8),
                _DeltaPill(text: '${c['delta']}'),
              ],
            ],
          ),
          if (c['sub'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('${c['sub']}',
                  style: const TextStyle(fontSize: 13, color: PinPalette.ink2)),
            ),
        ],
      ),
    );
  }

  Widget _progress(Map<String, dynamic> c, ColorScheme scheme) {
    final v = (c['value'] as num?)?.toDouble().clamp(0.0, 1.0) ?? 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: v,
              minHeight: 7,
              backgroundColor: scheme.primary.withValues(alpha: 0.15),
              color: scheme.primary,
            ),
          ),
          if (c['label'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text('${c['label']}',
                  style: const TextStyle(fontSize: 12, color: PinPalette.ink2)),
            ),
        ],
      ),
    );
  }

  Widget _button(Map<String, dynamic> c, ColorScheme scheme) {
    final action = c['action'] as Map<String, dynamic>?;
    final data = action?['data'] as String?;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: data == null ? null : () => onAction?.call(data),
          style: OutlinedButton.styleFrom(
            foregroundColor: scheme.secondary,
            side: BorderSide(color: scheme.primary.withValues(alpha: 0.4)),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: Text('${c['label'] ?? ''}'),
        ),
      ),
    );
  }

  Widget _bars(Map<String, dynamic> c, ColorScheme scheme) {
    final values =
        (c['values'] as List?)?.map((e) => (e as num).toDouble()).toList() ??
            [];
    final labels =
        (c['labels'] as List?)?.map((e) => '$e').toList() ?? [];
    final highlight = (c['highlight'] as num?)?.toInt() ?? -1;
    final maxV = values.isEmpty ? 1.0 : values.reduce((a, b) => a > b ? a : b);
    String fmt(double v) =>
        v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SizedBox(
        height: 96,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < values.length; i++)
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    // Value sits above its bar → the chart reads without a y-axis.
                    Text(fmt(values[i]),
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: i == highlight
                                ? scheme.secondary
                                : PinPalette.ink2)),
                    const SizedBox(height: 3),
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      height: 52 * (maxV == 0 ? 0 : values[i] / maxV) + 2,
                      decoration: BoxDecoration(
                        // Vertical gradient gives each bar depth, not a flat fill.
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: i == highlight
                              ? [scheme.primary, scheme.secondary]
                              : [
                                  scheme.primary.withValues(alpha: 0.38),
                                  scheme.primary.withValues(alpha: 0.18),
                                ],
                        ),
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(5)),
                      ),
                    ),
                    if (i < labels.length)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(labels[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: i == highlight
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: i == highlight
                                    ? PinPalette.ink
                                    : PinPalette.ink2)),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _gauge(Map<String, dynamic> c, ColorScheme scheme) {
    final value = (c['value'] as num?)?.toDouble() ?? 0;
    final max = (c['max'] as num?)?.toDouble() ?? 100;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: SizedBox(
          width: 120,
          height: 78,
          child: CustomPaint(
            painter: _GaugePainter(
                (value / max).clamp(0.0, 1.0), scheme.primary, scheme.secondary),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${value.toInt()}',
                        style:
                            PinPalette.brand(size: 24, color: scheme.secondary)),
                    if (c['label'] != null)
                      Text('${c['label']}',
                          style: const TextStyle(
                              fontSize: 11, color: PinPalette.ink2)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _line(Map<String, dynamic> c, ColorScheme scheme) {
    final points =
        (c['points'] as List?)?.map((e) => (e as num).toDouble()).toList() ??
            [];
    final last = points.isEmpty ? null : points.last;
    String fmt(double v) =>
        v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: SizedBox(
              height: 60,
              child: CustomPaint(
                  painter: _LinePainter(points, scheme.primary)),
            ),
          ),
          if (last != null) ...[
            const SizedBox(width: 10),
            Text(fmt(last),
                style: PinPalette.brand(size: 18, color: scheme.secondary)),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final Map<String, dynamic> header;
  const _Header({required this.header});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      // Pale brand band (theme card tint) flowing into the white body below.
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(13, 12, 14, 12),
      child: Row(
        children: [
          if (header['icon'] != null) ...[
            // Tinted rounded-square icon chip — matches the app's "ตอนนี้" rows
            // and reads more premium than a bare glyph.
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(_iconFor('${header['icon']}'),
                  size: 18, color: scheme.secondary),
            ),
            const SizedBox(width: 11),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${header['title'] ?? ''}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        PinPalette.brand(size: 15.5, color: scheme.secondary)),
                if (header['subtitle'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text('${header['subtitle']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: PinPalette.ink2)),
                  ),
              ],
            ),
          ),
          if (header['trailing'] != null) ...[
            const SizedBox(width: 8),
            Text('${header['trailing']}',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.secondary)),
          ],
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final Map<String, dynamic> footer;
  final ValueChanged<String>? onAction;
  const _Footer({required this.footer, this.onAction});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final data = (footer['action'] as Map<String, dynamic>?)?['data'] as String?;
    // A footer with action.data is a tappable bar (e.g. news "อ่านต่อ →").
    final tappable = data != null;
    final accent = tappable ? scheme.secondary : PinPalette.ink2;
    final row = Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: PinPalette.line)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
      child: Row(
        children: [
          Icon(_iconFor('${footer['icon'] ?? 'clock'}'),
              size: 14, color: scheme.secondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text('${footer['text'] ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: PinPalette.ink2)),
          ),
          if (footer['trailing'] != null) ...[
            const SizedBox(width: 8),
            Text(
              '${footer['trailing']}',
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12, color: accent, fontWeight: FontWeight.w600),
            ),
          ],
          if (tappable)
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Icon(PhosphorIconsRegular.caretRight, size: 15, color: accent),
            ),
        ],
      ),
    );
    if (!tappable) return row;
    return InkWell(onTap: () => onAction?.call(data), child: row);
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final ColorScheme scheme;
  const _Chip({required this.label, required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: scheme.secondary)),
    );
  }
}

class _DeltaPill extends StatelessWidget {
  final String text;
  const _DeltaPill({required this.text});

  @override
  Widget build(BuildContext context) {
    final neg = text.trim().startsWith('-') || text.trim().startsWith('−');
    final color = neg ? PinPalette.neg : const Color(0xFF2E9E63);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

IconData _iconFor(String name) {
  switch (name) {
    case 'tasks':
      return PhosphorIconsRegular.listChecks;
    case 'sun':
      return PhosphorIconsRegular.sun;
    case 'calendar':
      return PhosphorIconsRegular.calendar;
    case 'money':
      return PhosphorIconsRegular.wallet;
    case 'chart':
      return PhosphorIconsRegular.trendUp;
    case 'fuel':
      return PhosphorIconsRegular.gasPump;
    case 'air':
      return PhosphorIconsRegular.wind;
    case 'fx':
      return PhosphorIconsRegular.arrowsLeftRight;
    case 'draft':
      return PhosphorIconsRegular.notePencil;
    case 'image':
      return PhosphorIconsRegular.image;
    case 'file':
    case 'doc':
      return PhosphorIconsRegular.fileText;
    case 'audio':
      return PhosphorIconsRegular.musicNote;
    case 'video':
      return PhosphorIconsRegular.videoCamera;
    case 'sparkles':
      return PhosphorIconsRegular.sparkle;
    case 'heart':
      return PhosphorIconsRegular.heart;
    case 'clock':
      return PhosphorIconsRegular.clock;
    case 'news':
      return PhosphorIconsRegular.newspaper;
    default:
      return PhosphorIconsRegular.lightning;
  }
}

class _GaugePainter extends CustomPainter {
  final double t; // 0..1
  final Color color;
  final Color deep;
  _GaugePainter(this.t, this.color, this.deep);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(8, 8, size.width - 16, (size.height - 16) * 2);
    const start = 3.1415926;
    final bg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.14);
    canvas.drawArc(rect, start, 3.1415926, false, bg);
    // Filled portion sweeps from accent → deep for a sense of progression.
    final fg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: start,
        endAngle: start + 3.1415926,
        colors: [color, deep],
      ).createShader(rect);
    canvas.drawArc(rect, start, 3.1415926 * t, false, fg);
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.t != t || old.color != color || old.deep != deep;
}

class _LinePainter extends CustomPainter {
  final List<double> points;
  final Color color;
  _LinePainter(this.points, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final minV = points.reduce((a, b) => a < b ? a : b);
    final maxV = points.reduce((a, b) => a > b ? a : b);
    final span = (maxV - minV).abs() < 1e-9 ? 1.0 : maxV - minV;
    final dx = size.width / (points.length - 1);
    const pad = 5.0; // keep the curve off the top/bottom edges
    double px(int i) => dx * i;
    double py(int i) =>
        size.height - pad - ((points[i] - minV) / span) * (size.height - pad * 2);

    // Smooth the polyline with Catmull-Rom → cubic Bézier segments.
    final line = Path()..moveTo(px(0), py(0));
    for (var i = 0; i < points.length - 1; i++) {
      final x0 = px(i), y0 = py(i), x1 = px(i + 1), y1 = py(i + 1);
      final xp = px(i == 0 ? i : i - 1), yp = py(i == 0 ? i : i - 1);
      final xn = px(i + 2 >= points.length ? i + 1 : i + 2);
      final yn = py(i + 2 >= points.length ? i + 1 : i + 2);
      line.cubicTo(
        x0 + (x1 - xp) / 6, y0 + (y1 - yp) / 6,
        x1 - (xn - x0) / 6, y1 - (yn - y0) / 6,
        x1, y1,
      );
    }

    // Soft area fill under the curve (gradient fading to nothing).
    final area = Path.from(line)
      ..lineTo(px(points.length - 1), size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
    // End marker: white halo + accent dot so the latest point pops.
    final ex = px(points.length - 1), ey = py(points.length - 1);
    canvas.drawCircle(Offset(ex, ey), 4.5, Paint()..color = Colors.white);
    canvas.drawCircle(Offset(ex, ey), 3.2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.points != points;
}
