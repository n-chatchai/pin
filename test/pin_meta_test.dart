import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pin/services/pin_meta.dart';

void main() {
  group('isPinMeta', () {
    test('true when meta.pin == true', () {
      expect(isPinMeta(jsonEncode({'pin': true})), isTrue);
      expect(isPinMeta(jsonEncode({'pin': true, 'used': ['search']})), isTrue);
    });
    test('false for human turns / missing flag', () {
      expect(isPinMeta(null), isFalse);
      expect(isPinMeta(''), isFalse);
      expect(isPinMeta(jsonEncode({})), isFalse);
      expect(isPinMeta(jsonEncode({'used': ['x']})), isFalse);
      expect(isPinMeta(jsonEncode({'pin': false})), isFalse);
    });
    test('false on malformed / non-map json (never throws)', () {
      expect(isPinMeta('not json'), isFalse);
      expect(isPinMeta('[1,2,3]'), isFalse);
      expect(isPinMeta('"pin"'), isFalse);
    });
  });

  group('pinMeta', () {
    test('always carries pin flag; omits empty used', () {
      expect(pinMeta([]), {'pin': true});
      expect(pinMeta(['search', 'card']), {
        'pin': true,
        'used': ['search', 'card'],
      });
    });
    test('round-trips through isPinMeta', () {
      expect(isPinMeta(jsonEncode(pinMeta([]))), isTrue);
      expect(isPinMeta(jsonEncode(pinMeta(['a']))), isTrue);
    });
  });

  group('self-room account-data pointer', () {
    test('encode → decode round-trip', () {
      const rid = '!abc123:pin-chat.tokens2.io';
      expect(selfRoomId(selfRoomPointer(rid)), rid);
    });
    test('null/absent/malformed → null (never throws)', () {
      expect(selfRoomId(null), isNull);
      expect(selfRoomId(''), isNull);
      expect(selfRoomId(jsonEncode({})), isNull);
      expect(selfRoomId(jsonEncode({'room': ''})), isNull);
      expect(selfRoomId(jsonEncode({'room': 42})), isNull);
      expect(selfRoomId('garbage'), isNull);
    });
  });

  group('resolveSelfRoom', () {
    final rooms = [
      (id: '!admin:s', name: 'pin-chat.tokens2.io Admin Room'),
      (id: '!a:s', name: 'ปิ่น'),
      (id: '!b:s', name: 'ปิ่น'),
    ];
    test('account-data pointer wins over name-match', () {
      expect(resolveSelfRoom(selfRoomPointer('!ptr:s'), rooms), '!ptr:s');
    });
    test('no pointer → first room named ปิ่น (never the admin room)', () {
      expect(resolveSelfRoom(null, rooms), '!a:s');
    });
    test('no pointer + no ปิ่น room → null (→ onboarding)', () {
      expect(resolveSelfRoom(null, [
        (id: '!admin:s', name: 'pin-chat.tokens2.io Admin Room'),
      ]), isNull);
      expect(resolveSelfRoom(null, const []), isNull);
    });
    test('malformed pointer falls back to name-match', () {
      expect(resolveSelfRoom('garbage', rooms), '!a:s');
    });
  });
}
