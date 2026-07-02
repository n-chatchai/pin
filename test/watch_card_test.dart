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

  group('buildDigestCard', () {
    test('one item per watch + footer carries the time', () {
      final c = buildDigestCard([
        {'topic': 'A', 'last_seen': 'a'},
        {'topic': 'B', 'last_seen': 'b'},
      ], time: '08:00', dateLabel: '7 ก.ค.');
      expect(c['header']['icon'], 'sun');
      expect((c['header']['subtitle'] as String), contains('2'));
      expect((c['body'] as List), hasLength(2));
      // finding falls back to last_seen when finding key absent
      expect((c['body'] as List).first['finding'], 'a');
      expect(c['footer']['trailing'], '08:00');
    });
  });
}
