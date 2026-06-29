import 'package:flutter_test/flutter_test.dart';
import 'package:pin/agent/news_tool.dart';

void main() {
  final keys = ['general', 'ai', 'คริปโต', 'ทีมบอล'];

  group('resolveNewsTopic', () {
    test('empty → general', () => expect(resolveNewsTopic(keys, ''), 'general'));
    test('exact, case-insensitive', () => expect(resolveNewsTopic(keys, 'AI'), 'ai'));
    test('thai exact', () => expect(resolveNewsTopic(keys, 'คริปโต'), 'คริปโต'));
    test('topic contains a configured key', () => expect(resolveNewsTopic(keys, 'ข่าว AI วันนี้'), 'ai'));
    test('unconfigured topic → general', () => expect(resolveNewsTopic(keys, 'หุ้น'), 'general'));
    test('no general key + no match → general', () => expect(resolveNewsTopic(['ai'], 'หุ้น'), 'general'));
    test('general key never matched by contains', () => expect(resolveNewsTopic(keys, 'general news'), 'general'));
  });
}
