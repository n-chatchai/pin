// Verifies flex-button postback: app sends io.tokens2.action, bot dispatches it
// and replies.
//   flutter test integration_test/postback_test.dart -d <sim> \
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

  testWidgets('flex button postback round-trips to the bot', (tester) async {
    await RustLib.init();
    final svc = MatrixService.instance;
    await svc.login(homeserver: _homeserver, username: _user, password: _pass);

    final room = await svc.createEncryptedRoom('pin-postback-test', invite: [_bot]);
    await Future<void>.delayed(const Duration(seconds: 10));

    final replied = Completer<ChatMessage>();
    final sub = svc.messages
        .where((m) => m.roomId == room.id && m.sender == _bot)
        .listen((m) {
      if (!replied.isCompleted) replied.complete(m);
    });

    // Simulate tapping a flex card button.
    await svc.sendAction(room.id, 'draft:invoice:C');
    // ignore: avoid_print
    print('SENT postback');

    final m = await replied.future.timeout(const Duration(seconds: 90));
    // ignore: avoid_print
    print('BOT HANDLED postback → kind=${m.kind} body="${m.body}"');
    expect(m.body.trim().isNotEmpty || m.flexJson != null, true);
    await sub.cancel();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
