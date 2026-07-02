// Pure builders for the ปิ่น "watch" flex cards (rendered by FlexCardView).
// No Flutter deps → unit-testable. Calm/green (ปิ่น is smart, quiet, warm —
// never alarming). Two shapes:
//   • now    — one finding worth surfacing right away (single card)
//   • digest — the daily briefing. 1 finding → single card; 2+ → a swipeable
//              carousel (a cover card + one card per topic).
//
// A watch item is {icon, topic, finding/last_seen, source?}; icon is a
// FlexCardView icon name (default 'news'); source is a URL → a "อ่านต่อ" footer.

String _finding(Map<String, dynamic> w) =>
    '${w['finding'] ?? w['last_seen'] ?? ''}';

/// Footer linking to the source article ("อ่านต่อ →"), or null when there's no
/// URL. The chat's onFlexAction opens http(s) `action.data` externally.
Map<String, dynamic>? _sourceFooter(Map<String, dynamic> w) {
  final src = '${w['source'] ?? ''}'.trim();
  if (src.isEmpty) return null;
  return {
    'icon': 'news',
    'text': 'อ่านต่อ',
    'action': {'data': src},
  };
}

/// One topic as its own card (used in the digest carousel + as the body of the
/// single-finding cards via [_watchItem]).
Map<String, dynamic> _topicCard(Map<String, dynamic> w) {
  final card = <String, dynamic>{
    'header': {'icon': '${w['icon'] ?? 'news'}', 'title': '${w['topic'] ?? ''}'},
    'body': [
      {'type': 'text', 'text': _finding(w)}
    ],
  };
  final footer = _sourceFooter(w);
  if (footer != null) card['footer'] = footer;
  return card;
}

Map<String, dynamic> _watchItem(Map<String, dynamic> w) => {
      'type': 'watchitem',
      'icon': '${w['icon'] ?? 'news'}',
      'topic': '${w['topic'] ?? ''}',
      'finding': _finding(w),
    };

/// Immediate card for a single finding ปิ่น judged worth sharing now.
/// [name] = ปิ่น's persona name (settings), so a renamed assistant reads right.
Map<String, dynamic> buildNowCard(Map<String, dynamic> watch,
    {String name = 'ปิ่น'}) {
  final card = <String, dynamic>{
    'header': {
      'icon': 'sparkles',
      'title': '${name}เฝ้าให้',
      'subtitle': 'เจอเรื่องที่คิดว่าอยากรู้เลย',
    },
    'body': [_watchItem(watch)],
  };
  final footer = _sourceFooter(watch);
  if (footer != null) card['footer'] = footer;
  return card;
}

/// Build the digest card from the LLM's structured output (compose_digest):
/// {title, summary, items:[{topic, text, source?, icon?}]}. ปิ่น writes the
/// title/summary in its own voice (persona) and has already deduped the items,
/// so there are no hardcoded persona strings here.
Map<String, dynamic> buildDigestFromItems(
  Map<String, dynamic> a, {
  required String time,
}) {
  final title = '${a['title'] ?? 'ปิ่นสรุปให้'}';
  final summary = '${a['summary'] ?? ''}';
  final items = [
    for (final it in (a['items'] as List? ?? const []))
      {
        'icon': '${(it as Map)['icon'] ?? 'news'}',
        'topic': '${it['topic'] ?? ''}',
        'finding': '${it['text'] ?? it['finding'] ?? ''}',
        'source': '${it['source'] ?? ''}',
      }
  ];
  final settingsFooter = {
    'icon': 'clock',
    'text': 'เปลี่ยนเวลาสรุปได้ที่ตั้งค่า',
    'trailing': time,
  };

  if (items.length <= 1) {
    final w = items.isEmpty ? <String, dynamic>{} : items.first;
    return {
      'header': {
        'icon': 'sun',
        'title': title,
        if (summary.isNotEmpty) 'subtitle': summary,
      },
      'body': [if (items.isNotEmpty) _watchItem(w)],
      'footer': (items.isNotEmpty ? _sourceFooter(w) : null) ?? settingsFooter,
    };
  }
  return {
    'carousel': [
      {
        'header': {'icon': 'sun', 'title': title, 'subtitle': summary},
        'body': [
          {'type': 'text', 'style': 'muted', 'text': 'ปัดดูทีละเรื่องได้เลย'}
        ],
        'footer': settingsFooter,
      },
      for (final w in items) _topicCard(w),
    ],
  };
}

/// Code-built digest (fallback when the LLM turn fails). [time] = delivery time;
/// [dateLabel] a short Thai date; [ending] = ปิ่น's polite particle.
Map<String, dynamic> buildDigestCard(
  List<Map<String, dynamic>> watches, {
  required String time,
  String? dateLabel,
  String ending = 'ค่ะ', // ปิ่น's polite particle, from persona (ครับ/ค่ะ)
}) {
  final n = watches.length;
  final greeting = 'ปิ่นสรุปให้$ending';
  final sub = dateLabel == null
      ? 'มี $n เรื่องที่เฝ้าไว้ให้'
      : 'มี $n เรื่องที่เฝ้าไว้ให้ · $dateLabel';
  final settingsFooter = {
    'icon': 'clock',
    'text': 'เปลี่ยนเวลาสรุปได้ที่ตั้งค่า',
    'trailing': time,
  };

  // Single finding → one calm card (greeting header + the item + its source).
  if (n == 1) {
    return {
      'header': {'icon': 'sun', 'title': greeting, 'subtitle': sub},
      'body': [_watchItem(watches.first)],
      'footer': _sourceFooter(watches.first) ?? settingsFooter,
    };
  }

  // Multiple → a swipeable carousel: a cover card, then one card per topic.
  return {
    'carousel': [
      {
        'header': {'icon': 'sun', 'title': greeting, 'subtitle': sub},
        'body': [
          {
            'type': 'text',
            'style': 'muted',
            'text': 'ปัดดูทีละเรื่องได้เลย$ending'
          }
        ],
        'footer': settingsFooter,
      },
      for (final w in watches) _topicCard(w),
    ],
  };
}
