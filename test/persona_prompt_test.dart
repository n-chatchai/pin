import 'package:flutter_test/flutter_test.dart';
import 'package:pin/agent/agent_config.dart';

/// A special character speaks in its own voice (call/self/demeanor + its own
/// ending, e.g. butler → ขอรับ) but COMPLEMENTS the base: the assistant keeps
/// its name and helpful-assistant role. Custom has no preset voice → keeps the
/// user's tone.
void main() {
  group('special character speaks in its own voice but keeps the name', () {
    test('butler uses its own address/self/ending + keeps the assistant name', () {
      final s = kPinSystemFor(
        name: 'มะลิ',
        userCall: 'พี่บอล',
        self: 'ปิ่น',
        tone: 'male',
        persona: 'butler',
      );
      expect(s, contains('นายท่าน'), reason: 'address word is the character\'s');
      expect(s, contains('กระหม่อม'), reason: 'self-reference is the character\'s');
      expect(s, contains('นอบน้อม'), reason: "character's demeanor");
      expect(s, contains('ขอรับ'), reason: "character's own ending");
      expect(s, contains('มะลิ'), reason: 'assistant name is kept (complement, not erase)');
      expect(s, isNot(contains('พี่บอล')), reason: 'the base address word is overridden');
    });

    test('custom persona overrides call/self but keeps the user tone', () {
      final s = kPinSystemFor(
        tone: 'casual',
        persona: 'custom',
        customCall: 'เจ้านาย',
        customSelf: 'บอท',
      );
      expect(s, contains('เจ้านาย'));
      expect(s, contains('บอท'));
      expect(s, contains('จ๊ะ'), reason: "user's casual tone kept");
    });
  });

  group('basic persona = pure user settings', () {
    test('no character → address/self/tone are exactly the user values', () {
      final s = kPinSystemFor(
        name: 'มะลิ',
        userCall: 'พี่บอล',
        self: 'หนู',
        tone: 'male',
      );
      expect(s, contains('มะลิ'));
      expect(s, contains('พี่บอล'));
      expect(s, contains('หนู'));
      expect(s, contains('ครับ'));
      expect(s, isNot(contains('นายท่าน')), reason: 'no special character applied');
    });
  });
}
