import 'package:flutter_test/flutter_test.dart';
import 'package:pin/agent/agent_config.dart';

/// A special character sets call/self/demeanor; the ENDING is left to the model
/// (it gets the role + the user's gender register and picks the particle). The
/// assistant keeps its name + helpful-assistant role. Custom keeps the user's
/// tone.
void main() {
  group('special character: model-chosen ending, name kept', () {
    test('butler sets address/self/demeanor, keeps name, does NOT hardcode the ending', () {
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
      expect(s, contains('คำลงท้าย'), reason: 'model is asked to choose a fitting ending');
      expect(s, contains('มะลิ'), reason: 'assistant name is kept');
      expect(s, isNot(contains('พี่บอล')), reason: 'the base address word is overridden');
      expect(s, isNot(contains('ขอรับ')), reason: 'ending is NOT hardcoded — the model derives it');
    });

    test('butler hands a different register for male vs female (→ ขอรับ vs เจ้าค่ะ)', () {
      final male = kPinSystemFor(name: 'มะลิ', tone: 'male', persona: 'butler');
      final female = kPinSystemFor(name: 'มะลิ', tone: 'female', persona: 'butler');
      expect(male, contains('ผู้ชาย'));
      expect(female, contains('ผู้หญิง'));
      expect(male, isNot(equals(female)),
          reason: 'the gender register changes the prompt so the model can adapt the ending');
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
