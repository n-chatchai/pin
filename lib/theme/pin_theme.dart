import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// One of the five selectable ปิ่น palettes. Only the accent family changes
/// between themes; the cream background + ink text stay constant.
class PinPalette {
  final String key;
  final String name; // Thai display name
  final Color accent;
  final Color deep;
  final Color dd;
  final Color pale;
  final Color card;
  final Color av;

  const PinPalette({
    required this.key,
    required this.name,
    required this.accent,
    required this.deep,
    required this.pale,
    required this.card,
    required this.av,
    required this.dd,
  });

  // Warm "Pi" neutrals: cream paper, warm-brown ink, warm hairline (matches the
  // marketing site tokens — design/now-pi.html, site/index.html).
  static const cream = Color(0xFFFBF6EE);
  static const ink = Color(0xFF2E2A24);
  static const ink2 = Color(0xFF6E6457);
  static const ink3 = Color(0xFF9A8F7E);
  static const line = Color(0xFFE7DCCB);
  static const neg = Color(0xFFB0432F);

  static const all = <PinPalette>[
    PinPalette(
      key: 'green',
      name: 'เขียว',
      accent: Color(0xFF34B06A), // deep forest — mature, single accent
      deep: Color(0xFF14532E),
      dd: Color(0xFF15663C), // hover/pressed (darker than accent)
      pale: Color(0xFFEEF3EC),
      card: Color(0xFFEBF3E7),
      av: Color(0xFFDBEAD3),
    ),
    PinPalette(
      key: 'clay',
      name: 'ดินเผา',
      accent: Color(0xFFC15F3C),
      deep: Color(0xFF7E3A20),
      dd: Color(0xFFA04A2C),
      pale: Color(0xFFF0E2DA),
      card: Color(0xFFF1E6DD),
      av: Color(0xFFE8D3C6),
    ),
    PinPalette(
      key: 'slate',
      name: 'ฟ้าสง่า',
      accent: Color(0xFF4F6FA6),
      deep: Color(0xFF2C436B),
      dd: Color(0xFF3E5B8C),
      pale: Color(0xFFE1E7F1),
      card: Color(0xFFE7ECF5),
      av: Color(0xFFD3DDEE),
    ),
    PinPalette(
      key: 'plum',
      name: 'พลัม',
      accent: Color(0xFF8A4A6B),
      deep: Color(0xFF5A2C45),
      dd: Color(0xFF743C5A),
      pale: Color(0xFFEEE0E8),
      card: Color(0xFFF0E5EC),
      av: Color(0xFFE2CCDB),
    ),
    PinPalette(
      key: 'pine',
      name: 'สนเขา',
      accent: Color(0xFF1F6B5E), // deep teal — cool, distinct from green
      deep: Color(0xFF134C42),
      dd: Color(0xFF185A4F),
      pale: Color(0xFFE9F1EF),
      card: Color(0xFFE3EEEB),
      av: Color(0xFFD2E5E0),
    ),
    PinPalette(
      key: 'graphite',
      name: 'กราไฟต์',
      accent: Color(0xFF42474F), // near-neutral slate — sober, premium
      deep: Color(0xFF2A2E34),
      dd: Color(0xFF353A41),
      pale: Color(0xFFEDEEEF),
      card: Color(0xFFE8E9EB),
      av: Color(0xFFD9DBDF),
    ),
  ];

  static PinPalette byKey(String key) =>
      all.firstWhere((p) => p.key == key, orElse: () => all.first);

  /// Builds the Flutter [ThemeData] for this palette.
  /// IBM Plex Sans Thai = headings/brand, Sarabun = body (Thai-first).
  ThemeData toTheme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      primary: accent,
      onPrimary: Colors.white,
      secondary: deep,
      surface: Colors.white,
      onSurface: ink,
      surfaceContainerHighest: card,
      brightness: Brightness.light,
    );

    final base = ThemeData(colorScheme: scheme, useMaterial3: true);
    final textTheme = GoogleFonts.sarabunTextTheme(base.textTheme).apply(
      bodyColor: ink,
      displayColor: ink,
    );

    // Fill the whole screen with a faint wash of the theme colour (cream tinted
    // toward the accent) so the palette is felt everywhere, not just on accents.
    final bg = Color.alphaBlend(accent.withValues(alpha: 0.05), cream);

    return base.copyWith(
      scaffoldBackgroundColor: bg,
      textTheme: textTheme,
      // Brand / headlines use Trirong (warm Thai serif) — the Pi voice.
      primaryTextTheme: GoogleFonts.trirongTextTheme(base.textTheme),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        titleTextStyle: GoogleFonts.trirong(
          fontSize: 19,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
      ),
      dividerColor: line,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      cardTheme: const CardThemeData(color: Colors.white),
    );
  }

  /// Headline/brand style helper (Trirong — warm Thai serif, the Pi voice).
  static TextStyle brand({double size = 28, Color? color}) =>
      GoogleFonts.trirong(
        fontSize: size,
        fontWeight: FontWeight.w600,
        color: color ?? ink,
      );
}
