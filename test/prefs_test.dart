import 'package:flutter_test/flutter_test.dart';
import 'package:pin/services/prefs.dart';

/// Pure-logic tests for the persona/prefs rules that kept regressing:
/// (1) persona must NEVER be persisted on device, (2) the room→prefs mapping
/// must restore every persona field (tone/persona_mode/custom included).
void main() {
  // The persona identity fields — the ones that must stay room-only and must
  // all round-trip through the room state.
  // Persona identity + the room-derived flags (onboarded/personaSetup) must NOT
  // be persisted — they all come from the room.
  const roomDerivedKeys = {
    'pinName', 'userName', 'userCall', 'pinSelf', 'tone', 'pinEnding',
    'personaMode', 'customCall', 'customSelf', 'onboarded', 'personaSetup',
  };

  group('toLocalMap (room-derived state never persists)', () {
    test('excludes every persona key + onboarded/personaSetup', () {
      final local = const PinPrefs(
        pinName: 'มะลิ',
        userName: 'บอล',
        userCall: 'พี่บอล',
        pinSelf: 'หนู',
        tone: 'male',
        pinEnding: 'ครับ',
        personaMode: 'custom',
        customCall: 'นาย',
        customSelf: 'ข้า',
        onboarded: true,
        personaSetup: true,
      ).toLocalMap();
      for (final k in roomDerivedKeys) {
        expect(local.containsKey(k), isFalse,
            reason: 'room-derived key "$k" must not be on device');
      }
    });

    test('keeps true device-local settings', () {
      final local = const PinPrefs(
        lang: 'en',
        debugBot: true,
        morningTime: '09:30',
      ).toLocalMap();
      // lang is room-derived now (synced cross-device via room state), so it is
      // NOT persisted locally — see _roomDerivedKeys / copyWithRoomState.
      expect(local['lang'], isNull);
      expect(local['debugBot'], '1');
      expect(local['morningTime'], '09:30');
    });
  });

  group('copyWithRoomState (room is the source of truth)', () {
    test('restores every persona field from the room map', () {
      final p = const PinPrefs().copyWithRoomState({
        'pin_name': 'มะลิ',
        'user_name': 'บอล',
        'user_call': 'พี่บอล',
        'pin_self': 'หนู',
        'tone': 'male',
        'pin_ending': 'ครับ',
        'persona_mode': 'custom',
        'custom_call': 'นาย',
        'custom_self': 'ข้า',
      });
      expect(p.pinName, 'มะลิ');
      expect(p.userName, 'บอล');
      expect(p.userCall, 'พี่บอล');
      expect(p.pinSelf, 'หนู');
      expect(p.tone, 'male');
      expect(p.pinEnding, 'ครับ');
      expect(p.personaMode, 'custom');
      expect(p.customCall, 'นาย');
      expect(p.customSelf, 'ข้า');
    });

    test('derives tone from the ending for older rooms with no tone key', () {
      final p = const PinPrefs(tone: 'female')
          .copyWithRoomState({'pin_name': 'ปิ่น', 'pin_ending': 'ครับ'});
      expect(p.tone, 'male', reason: 'tone must follow the stored ending, not stay default');
      expect(p.pinEnding, 'ครับ');
    });

    test('a key absent from the room keeps the current value', () {
      final p = const PinPrefs(userCall: 'พี่เก่า', pinSelf: 'เดิม')
          .copyWithRoomState({'pin_name': 'ปิ่น', 'pin_ending': 'ค่ะ'});
      expect(p.userCall, 'พี่เก่า');
      expect(p.pinSelf, 'เดิม');
    });

    test('does not flip onboarded/personaSetup by itself', () {
      final p = const PinPrefs(onboarded: false, personaSetup: false)
          .copyWithRoomState({'pin_name': 'ปิ่น'});
      expect(p.onboarded, isFalse);
      expect(p.personaSetup, isFalse);
    });
  });

  group('tone migration', () {
    test('toneFromEnding maps each particle', () {
      expect(toneFromEnding('ครับ'), 'male');
      expect(toneFromEnding('ค่ะ'), 'female');
      expect(toneFromEnding('คะ'), 'female');
      expect(toneFromEnding('จ๊ะ'), 'casual');
      expect(toneFromEnding(''), 'neutral');
      expect(toneFromEnding('???'), 'female'); // unknown → safe default
    });

    test('toneParticle female swaps by sentence type', () {
      expect(toneParticle('female'), 'ค่ะ');
      expect(toneParticle('female', question: true), 'คะ');
      expect(toneParticle('male'), 'ครับ');
      expect(toneParticle('neutral'), '');
    });
  });

  test('toMap/fromMap round-trips persona + settings', () {
    const original = PinPrefs(
      pinName: 'มะลิ',
      userCall: 'พี่บอล',
      tone: 'casual',
      pinEnding: 'จ๊ะ',
      personaMode: 'friend',
      lang: 'en',
      onboarded: true,
    );
    final restored = PinPrefs.fromMap(original.toMap());
    expect(restored.pinName, 'มะลิ');
    expect(restored.userCall, 'พี่บอล');
    expect(restored.tone, 'casual');
    expect(restored.personaMode, 'friend');
    expect(restored.lang, 'en');
    expect(restored.onboarded, isTrue);
  });
}
