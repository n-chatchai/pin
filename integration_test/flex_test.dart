// Verifies ปิ่น can answer with a Flex card: ask for a task list as a card,
// bot calls show_card (Gemini function-calling) → sends io.tokens2.flex →
// app surfaces it as a flex message.
//   flutter test integration_test/flex_test.dart -d <sim> \
//     --dart-define=PIN_USER=... --dart-define=PIN_PASS=...
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:pin/services/matrix_service.dart';
import 'package:pin/src/rust/api/matrix.dart';
import 'package:pin/src/rust/frb_generated.dart';

const _user = String.fromEnvironment('PIN_USER');
const _pass = String.fromEnvironment('PIN_PASS');
const _homeserver = String.fromEnvironment(
  'PIN_HOMESERVER',
  defaultValue: 'https://chat.tokens2.io',
);
const _bot = '@pin-bot:chat.tokens2.io';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bot answers with a flex card', (tester) async {
    await RustLib.init();
    final svc = MatrixService.instance;
    await svc.login(homeserver: _homeserver, username: _user, password: _pass);

    final room = await svc.createEncryptedRoom('pin-flex-test', invite: [_bot]);
    await Future<void>.delayed(const Duration(seconds: 10));

    final card = Completer<ChatMessage>();
    final sub = svc.messages
        .where((m) => m.roomId == room.id && m.sender == _bot && m.kind == 'flex')
        .listen((m) {
      if (!card.isCompleted) card.complete(m);
    });

    await svc.sendMessage(
      room.id,
      'ขอดูงานค้างเป็นการ์ดหน่อย: รอคุณ ส่งงานลูกค้า A บ่ายสี่, '
      'รอเขา ดีล X 5วัน, เดดไลน์ พรีเซนต์ B พฤหัส',
    );
    // ignore: avoid_print
    print('ASKED for card');

    final m = await card.future.timeout(const Duration(seconds: 90));
    // ignore: avoid_print
    print('FLEX RECEIVED: ${m.flexJson}');
    expect(m.flexJson != null && m.flexJson!.isNotEmpty, true);
    expect(m.flexJson!.contains('header'), true);
    await sub.cancel();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
