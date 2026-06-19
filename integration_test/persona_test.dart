// Verifies persona prefs reach the bot: set userCall, bot addresses user by it.
//   flutter test integration_test/persona_test.dart -d <sim> \
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

  testWidgets('bot honours persona prefs (userCall)', (tester) async {
    await RustLib.init();
    final svc = MatrixService.instance;
    await svc.login(homeserver: _homeserver, username: _user, password: _pass);

    final room = await svc.createEncryptedRoom('pin-persona-test', invite: [_bot]);
    await Future<void>.delayed(const Duration(seconds: 10));

    // User wants to be called "คุณหมอ" — distinctive so we can detect it.
    await svc.sendPrefs(room.id, 'น้องปิ่น', 'คุณหมอ');
    await Future<void>.delayed(const Duration(seconds: 2));

    final reply = Completer<ChatMessage>();
    final sub = svc.messages
        .where((m) => m.roomId == room.id && m.sender == _bot && m.kind == 'text')
        .listen((m) {
      if (!reply.isCompleted) reply.complete(m);
    });

    await svc.sendMessage(room.id, 'ทักทายหน่อย แล้วเรียกฉันให้ถูกด้วยนะ');
    final m = await reply.future.timeout(const Duration(seconds: 90));
    // ignore: avoid_print
    print('PIN: ${m.body}');
    expect(m.body.contains('คุณหมอ'), true,
        reason: 'bot should address user as คุณหมอ');
    await sub.cancel();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
