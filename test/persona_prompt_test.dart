import 'package:flutter_test/flutter_test.dart';
import 'package:pin/agent/agent_config.dart';

/// A special character must COMPLEMENT the base persona: override the address
/// word + self-reference and add a demeanor, but keep the user's tone/ending.
void main() {
  group('special persona complements (not replaces) the base', () {
    test('butler overrides call/self + adds demeanor but keeps the user tone', () {
      final s = kPinSystemFor(
        userCall: 'พี่บอล',
        self: 'ปิ่น',
        tone: 'male',
        persona: 'butler',
      );
      expect(s, contains('นายท่าน'), reason: 'address word overridden by the character');
      expect(s, contains('กระหม่อม'), reason: 'self-reference overridden');
      expect(s, contains('นอบน้อม'), reason: "character's demeanor layered on");
      expect(s, contains('ครับ'), reason: "user's male tone/ending kept");
      expect(s, isNot(contains('ขอรับ')),
          reason: 'the character must not force its own ending over the user tone');
    });

    test('keeps a female tone under a special character', () {
      final s = kPinSystemFor(tone: 'female', persona: 'butler');
      expect(s, contains('ค่ะ'), reason: "user's female ending kept");
      expect(s, contains('นายท่าน'));
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
