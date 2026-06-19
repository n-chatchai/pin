// Verifies the @pin-bot service end-to-end: create an encrypted room, invite the
// bot, send a message, and confirm the bot decrypts it and echoes back
// (re-encrypted). Requires the bot container to be running.
//   flutter test integration_test/bot_echo_test.dart -d <sim> \
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

  testWidgets('bot joins encrypted room and echoes', (tester) async {
    await RustLib.init();
    final svc = MatrixService.instance;
    await svc.login(homeserver: _homeserver, username: _user, password: _pass);

    final room = await svc.createEncryptedRoom('pin-bot-test', invite: [_bot]);
    // ignore: avoid_print
    print('ROOM ${room.id} enc=${room.isEncrypted}, invited $_bot');

    // Give the bot time to receive the invite and join.
    await Future<void>.delayed(const Duration(seconds: 10));

    final echoed = Completer<ChatMessage>();
    final sub = svc.messages
        .where((m) => m.roomId == room.id && m.sender == _bot)
        .listen((m) {
      // ignore: avoid_print
      print('BOT REPLY: "${m.body}"');
      if (m.body.startsWith('echo:') && !echoed.isCompleted) {
        echoed.complete(m);
      }
    });

    await svc.sendMessage(room.id, 'ping');
    // ignore: avoid_print
    print('SENT ping');

    final reply = await echoed.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw TimeoutException('bot did not echo'),
    );
    expect(reply.body, 'echo: ping');
    // ignore: avoid_print
    print('VERIFIED bot E2EE echo');

    await sub.cancel();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
