import 'package:flutter_test/flutter_test.dart';
import 'package:pin/agent/watch_card.dart';

void main() {
  group('buildNowCard', () {
    test('single item, no footer', () {
      final c = buildNowCard(
          {'icon': 'chart', 'topic': 'บอลโลก', 'finding': 'โมร็อกโกชนะ'});
      expect(c['header']['icon'], 'sparkles');
      expect(c['footer'], isNull);
      final body = c['body'] as List;
      expect(body, hasLength(1));
      expect(body.first['type'], 'watchitem');
      expect(body.first['topic'], 'บอลโลก');
      expect(body.first['finding'], 'โมร็อกโกชนะ');
      expect(body.first['icon'], 'chart');
    });

    test('missing icon defaults to news', () {
      final c = buildNowCard({'topic': 'x', 'finding': 'y'});
      expect((c['body'] as List).first['icon'], 'news');
    });
  });

  group('buildDigestCard (code fallback)', () {
    test('greeting uses the persona ending', () {
      final c = buildDigestCard([
        {'topic': 'A', 'last_seen': 'a'},
      ], time: '08:00', ending: 'ครับ');
      expect(c['header']['title'], 'ปิ่นสรุปให้ครับ');
    });

    test('multiple → carousel: cover + one card per topic', () {
      final c = buildDigestCard([
        {'topic': 'A', 'last_seen': 'a', 'source': 'https://x.com/1'},
        {'topic': 'B', 'last_seen': 'b'},
      ], time: '08:00', dateLabel: '7 ก.ค.');
      final cards = c['carousel'] as List;
      expect(cards, hasLength(3)); // cover + 2 topics
      expect(cards[1]['header']['title'], 'A');
      expect(cards[1]['footer']['action']['data'], 'https://x.com/1');
      expect(cards[2].containsKey('footer'), isFalse); // no source → no footer
    });
  });

  group('buildDigestFromItems (LLM structured output)', () {
    test('LLM title used verbatim; single item → one card', () {
      final c = buildDigestFromItems({
        'title': 'อรุณสวัสดิ์ครับพี่บอล',
        'summary': 'มี 1 เรื่อง',
        'items': [
          {'topic': 'ทอง', 'text': 'ขึ้น 150', 'source': 'https://g/1', 'icon': 'money'}
        ],
      }, time: '08:00');
      expect(c['carousel'], isNull);
      expect(c['header']['title'], 'อรุณสวัสดิ์ครับพี่บอล');
      expect((c['body'] as List).first['finding'], 'ขึ้น 150');
      expect((c['body'] as List).first['icon'], 'money');
      expect(c['footer']['action']['data'], 'https://g/1');
    });

    test('multiple items → carousel of topic cards', () {
      final c = buildDigestFromItems({
        'title': 'สวัสดีครับ',
        'items': [
          {'topic': 'A', 'text': 'a'},
          {'topic': 'B', 'text': 'b', 'source': 'https://x/2'},
        ],
      }, time: '08:00');
      final cards = c['carousel'] as List;
      expect(cards, hasLength(3));
      expect(cards[1]['header']['title'], 'A');
      expect(cards[2]['footer']['action']['data'], 'https://x/2');
    });
  });
}
