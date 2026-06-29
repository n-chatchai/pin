import 'package:flutter_test/flutter_test.dart';
import 'package:pin/agent/when_parse.dart';

void main() {
  final now = DateTime(2026, 6, 29, 14, 30); // Mon 2:30pm

  group('parseWhen relative', () {
    test('+30m', () => expect(parseWhen('+30m', now: now), now.add(const Duration(minutes: 30))));
    test('+2h', () => expect(parseWhen('+2h', now: now), now.add(const Duration(hours: 2))));
    test('+1d', () => expect(parseWhen('+1d', now: now), now.add(const Duration(days: 1))));
    test('bare number = minutes', () => expect(parseWhen('90', now: now), now.add(const Duration(minutes: 90))));
    test('spaces tolerated', () => expect(parseWhen(' + 15 m ', now: now), now.add(const Duration(minutes: 15))));
  });

  group('parseWhen HH:MM (rolls past times to tomorrow)', () {
    test('later today', () => expect(parseWhen('16:00', now: now), DateTime(2026, 6, 29, 16, 0)));
    test('past today → tomorrow', () => expect(parseWhen('09:00', now: now), DateTime(2026, 6, 30, 9, 0)));
    test('exactly now → tomorrow', () => expect(parseWhen('14:30', now: now), DateTime(2026, 6, 30, 14, 30)));
  });

  group('parseWhen ISO / unreadable', () {
    test('ISO timestamp', () => expect(parseWhen('2026-07-01T08:00:00', now: now), DateTime(2026, 7, 1, 8, 0)));
    test('thai words → null', () => expect(parseWhen('พรุ่งนี้เช้า', now: now), isNull));
    test('empty → null', () => expect(parseWhen('', now: now), isNull));
    test('junk → null', () => expect(parseWhen('25:99', now: now), isNull));
  });

  test('hhmm zero-pads', () {
    expect(hhmm(DateTime(2026, 1, 1, 9, 5)), '09:05');
    expect(hhmm(DateTime(2026, 1, 1, 23, 0)), '23:00');
  });
}
