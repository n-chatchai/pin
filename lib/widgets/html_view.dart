import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:google_fonts/google_fonts.dart';

/// Renders an HTML string inside a chat flex card as native Flutter widgets
/// (no WKWebView / PlatformView — those force iOS into a slow compositing path
/// and stutter the whole chat). Auto-sizes to content, blocks navigation, and
/// applies the app's cream/ink palette so cards from the bot/creators look
/// consistent.
class HtmlView extends StatelessWidget {
  final String html;
  const HtmlView(this.html, {super.key});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: HtmlWidget(
          html,
          // Base body type — Sarabun (the app's body face), matching design.
          // Must come from GoogleFonts so the family actually resolves; a plain
          // 'Sarabun' string wouldn't (google_fonts registers an internal name).
          textStyle: GoogleFonts.sarabun(
            color: const Color(0xFF2A2A26),
            fontSize: 15,
            height: 1.5,
          ),
          // Local content only — swallow every tap so nothing launches a
          // browser (returning true tells fwfh the URL is "handled").
          onTapUrl: (_) => true,
          customStylesBuilder: (e) {
            switch (e.localName) {
              case 'a':
                return {'color': '#2E9E63'};
              // Cap headings so a model-authored <h1>/<h2> doesn't tower over the
              // chat — keep them card-scale, not page-scale.
              case 'h1':
              case 'h2':
                return {
                  'font-size': '17px',
                  'font-weight': '700',
                  'margin': '6px 0 4px',
                  'line-height': '1.3',
                };
              case 'h3':
              case 'h4':
                return {
                  'font-size': '15px',
                  'font-weight': '700',
                  'margin': '5px 0 3px',
                };
              case 'p':
              case 'ul':
              case 'ol':
                return {'margin': '4px 0'};
              // Tables fit the card width instead of overflowing/clipping: full
              // width, smaller type, wrap long cell text.
              case 'table':
                return {
                  'border-collapse': 'collapse',
                  'width': '100%',
                  'font-size': '13px',
                };
              case 'td':
              case 'th':
                return {
                  'border': '1px solid #E6E1D5',
                  'padding': '4px 6px',
                  'word-break': 'break-word',
                };
              // Inline code / repo names: a soft tinted chip, not a raw grey box.
              case 'code':
              case 'kbd':
                return {
                  'background': '#EFEcE3',
                  'padding': '1px 5px',
                  'border-radius': '5px',
                  'font-size': '13px',
                };
              case 'pre':
                return {
                  'background': '#F3F0E8',
                  'padding': '8px 10px',
                  'border-radius': '8px',
                  'font-size': '12.5px',
                  'white-space': 'pre-wrap',
                };
              case 'img':
                return {'max-width': '100%'};
              default:
                return null;
            }
          },
        ),
      ),
    );
  }
}
