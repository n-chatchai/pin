// Pure builders for the ปิ่น "watch" flex cards (rendered by FlexCardView).
// No Flutter deps → unit-testable. Two shapes, both calm/green (ปิ่น is smart,
// quiet, warm — never alarming):
//   • now    — one finding worth surfacing right away
//   • digest — the daily briefing: everything pending, at the user's time
//
// An item is {icon, topic, finding}; icon is a FlexCardView icon name
// (see _iconFor there), defaulting to 'news'.

Map<String, dynamic> _item(Map<String, dynamic> w) => {
      'type': 'watchitem',
      'icon': '${w['icon'] ?? 'news'}',
      'topic': '${w['topic'] ?? ''}',
      'finding': '${w['finding'] ?? w['last_seen'] ?? ''}',
    };

/// Immediate card for a single finding ปิ่น judged worth sharing now.
Map<String, dynamic> buildNowCard(Map<String, dynamic> watch) => {
      'header': {
        'icon': 'sparkles',
        'title': 'ปิ่นเฝ้าให้',
        'subtitle': 'เจอเรื่องที่คิดว่าอยากรู้เลย',
      },
      'body': [_item(watch)],
    };

/// Daily digest: all pending findings in one calm briefing card. [time] is the
/// user's chosen delivery time (HH:MM); [dateLabel] a short Thai date.
Map<String, dynamic> buildDigestCard(
  List<Map<String, dynamic>> watches, {
  required String time,
  String? dateLabel,
}) {
  final n = watches.length;
  final sub = dateLabel == null
      ? 'มี $n เรื่องที่เฝ้าไว้ให้'
      : 'มี $n เรื่องที่เฝ้าไว้ให้ · $dateLabel';
  return {
    'header': {'icon': 'sun', 'title': 'สวัสดีตอนเช้าค่ะ', 'subtitle': sub},
    'body': [for (final w in watches) _item(w)],
    'footer': {
      'icon': 'clock',
      'text': 'เปลี่ยนเวลาสรุปได้ที่ตั้งค่า',
      'trailing': time,
    },
  };
}
