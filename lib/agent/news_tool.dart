import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../services/prefs.dart';
import 'agent_reply.dart';
import 'proxy_client.dart';
import 'tools.dart';

/// On-device `news_reporter` — was an external dev microservice (8091); now the
/// device fetches the RSS itself and summarises through our blind LLM proxy, so
/// there's no extra server to host or key. Returns a flex carousel of items.
///
/// ponytail: feeds arrive newest-first, so we keep feed order and take the top
/// few after cross-source title dedup instead of parsing RFC-822 dates. Add a
/// real date sort only if a source ever returns out of order.

String _topicKey(String topic) {
  const aiHints = ['ai', 'เอไอ', 'ปัญญาประดิษฐ์', 'artificial', 'machine learning'];
  final t = topic.toLowerCase();
  return aiHints.any(t.contains) ? 'ai' : 'general';
}

/// Parse the admin-set tool config (`{"sources":{"general":[...],"ai":[...]}}`)
/// that ships in the catalog manifest — the device's "params" for this tool.
/// Unknown/missing → empty, and the handler falls back to the built-ins.
Map<String, List<_Source>> _parseConfig(dynamic config) {
  final out = <String, List<_Source>>{};
  final sources = (config is Map) ? config['sources'] : null;
  if (sources is Map) {
    sources.forEach((topic, list) {
      if (list is! List) return;
      out['$topic'] = [
        for (final s in list)
          if (s is Map && '${s['url'] ?? ''}'.isNotEmpty)
            _Source(
              '${s['name'] ?? ''}'.isEmpty ? '${s['url']}' : '${s['name']}',
              '${s['url']}',
              '${s['slug'] ?? ''}'.isEmpty ? null : '${s['slug']}',
            ),
      ];
    });
  }
  return out;
}

List<_Source> _defaults(String key) => key == 'ai'
    ? const [
        _Source('Latent Space', 'https://www.latent.space/feed', 'ainews'),
        _Source('TechCrunch',
            'https://techcrunch.com/category/artificial-intelligence/feed/'),
        _Source('Hugging Face', 'https://huggingface.co/blog/feed.xml'),
      ]
    : const [
        _Source(
            'Google News', 'https://news.google.com/rss?hl=th&gl=TH&ceid=TH:th'),
        _Source('BBC ไทย', 'https://feeds.bbci.co.uk/thai/rss.xml'),
      ];

/// Build the on-device news tool. `config` is the admin-set tool config from the
/// catalog manifest (RSS feeds per topic); empty → built-in default feeds.
AgentTool newsTool(ProxyClient proxy, {dynamic config}) {
  final sources = _parseConfig(config);
  return AgentTool(
      fnDecl(
        'news_reporter',
        'รายงานข่าวเป็นการ์ดเลื่อนได้ (carousel) พร้อมแหล่งข่าวและลิงก์อ่านต่อ '
        'เรียกทุกครั้งที่ผู้ใช้ขอข่าว ใช้พารามิเตอร์ topic เลือกหมวด: '
        'เว้นว่าง=ข่าวทั่วไป, ai=ข่าว AI',
        properties: {
          'topic': {
            'type': 'string',
            'description': 'หัวข้อข่าว เช่น เว้นว่าง=ข่าวทั่วไป, ai=ข่าว AI',
          },
        },
      ),
      kind: 'remote', // blind: only the topic leaves the device
      (args) async {
        final topic = '${args['topic'] ?? ''}'.trim();
        final key = _topicKey(topic);
        final feeds = (sources[key]?.isNotEmpty ?? false)
            ? sources[key]!
            : _defaults(key); // admin config or built-in fallback
        final items = await _fetch(feeds);
        if (items.isEmpty) return ToolResult.feedback('ดึงข่าวไม่ได้ตอนนี้');

        final lang =
            PrefsController.instance.value.lang == 'en' ? 'English' : 'Thai';
        await _summarise(proxy, items, lang); // translate headline + summary

        final cards = [
          for (final it in items)
            {
              'header': {'title': it.title},
              'body': [
                {'type': 'text', 'text': it.summary}
              ],
              'footer': {
                'icon': 'news',
                'text': it.source,
                'trailing': 'อ่านต่อ →',
                'action': {'data': it.link},
              },
            }
        ];
        return ToolResult.terminal(
            AgentReply(flex: {'carousel': cards}));
      },
    );
}

/// Pull each feed, parse RSS 2.0, tag source, dedupe by normalised title, cap 6.
Future<List<_Item>> _fetch(List<_Source> sources) async {
  final out = <_Item>[];
  final seen = <String>{};
  for (final src in sources) {
    try {
      final r = await http.get(Uri.parse(src.url),
          headers: {'User-Agent': 'news-reporter/1'}).timeout(
        const Duration(seconds: 20),
      );
      if (r.statusCode != 200) continue;
      for (final item in XmlDocument.parse(utf8.decode(r.bodyBytes))
          .findAllElements('item')) {
        String g(String tag) =>
            item.getElement(tag)?.innerText.trim() ?? '';
        final link = g('link');
        if (src.slug != null && !link.toLowerCase().contains(src.slug!)) {
          continue; // source carries multiple feeds; keep only the wanted slug
        }
        final title = g('title');
        final key = title
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9ก-๙]+'), '');
        if (title.isEmpty || key.isEmpty || !seen.add(key)) continue;
        final body = g('description').replaceAll(RegExp(r'<[^>]+>'), ' ').trim();
        out.add(_Item(
          title: title,
          link: link,
          summary: body.length > 240 ? body.substring(0, 240) : body,
          content: body,
          // Google News stores the real publisher in <source>; else the feed.
          source: g('source').isNotEmpty ? g('source') : src.name,
        ));
        if (out.length >= 6) return out;
      }
    } catch (_) {
      continue; // one bad feed shouldn't sink the rest
    }
  }
  return out;
}

/// One blind LLM call → translated headline + whole short summary per item, in
/// the user's language. Mutates items in place. Best-effort: keeps the raw
/// title/snippet on any failure.
Future<void> _summarise(
    ProxyClient proxy, List<_Item> items, String lang) async {
  final numbered = [
    for (var i = 0; i < items.length; i++)
      '$i. ${items[i].title}\n${_clip(items[i].content, 600)}'
  ].join('\n\n');
  try {
    final resp = await proxy.infer(messages: [
      {
        'role': 'system',
        'content':
            'You are a news editor. Output in $lang. For each numbered item, '
                'translate the headline to a short natural $lang headline and '
                'write a self-contained 1-2 sentence summary (no preamble, do '
                'not cut mid-sentence). Reply ONLY as a JSON array in the same '
                'order: [{"i":0,"title":"...","summary":"..."}]'
      },
      {'role': 'user', 'content': numbered},
    ]);
    final content =
        '${resp['choices']?[0]?['message']?['content'] ?? ''}'.trim();
    final s = content.indexOf('['), e = content.lastIndexOf(']');
    if (s < 0 || e <= s) return;
    final arr = jsonDecode(content.substring(s, e + 1)) as List;
    for (final row in arr) {
      if (row is! Map) continue;
      final i = (row['i'] as num?)?.toInt() ?? -1;
      if (i < 0 || i >= items.length) continue;
      final t = '${row['title'] ?? ''}'.trim();
      final sum = '${row['summary'] ?? ''}'.trim();
      if (t.isNotEmpty) items[i].title = t;
      if (sum.isNotEmpty) items[i].summary = sum;
    }
  } catch (_) {/* keep raw title/snippet */}
}

String _clip(String s, int n) => s.length > n ? s.substring(0, n) : s;

class _Source {
  final String name;
  final String url;
  final String? slug;
  const _Source(this.name, this.url, [this.slug]);
}

class _Item {
  String title;
  String summary;
  final String link;
  final String content;
  final String source;
  _Item({
    required this.title,
    required this.summary,
    required this.link,
    required this.content,
    required this.source,
  });
}
