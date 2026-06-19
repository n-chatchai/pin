// Verifies reaction + reply round-trip through real Matrix (E2EE room).
// Sends a base message, reacts to it, and replies to it; confirms all three
// come back over the sync stream with correct relation metadata.
//   flutter test integration_test/wire_test.dart -d <sim> \
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reaction + reply round-trip', (tester) async {
    await RustLib.init();
    final svc = MatrixService.instance;
    final session =
        await svc.login(homeserver: _homeserver, username: _user, password: _pass);

    final room = await svc.createEncryptedRoom('pin-wire-test');

    final gotBase = Completer<void>();
    final gotReaction = Completer<ChatMessage>();
    final gotReply = Completer<ChatMessage>();
    String? baseId;

    final sub = svc.messages.where((m) => m.roomId == room.id).listen((m) {
      if (m.kind == 'text' && m.body == 'base msg' && !gotBase.isCompleted) {
        gotBase.complete();
      }
      if (m.kind == 'reaction' &&
          m.reactionTarget == baseId &&
          !gotReaction.isCompleted) {
        gotReaction.complete(m);
      }
      if (m.replyToEventId == baseId && !gotReply.isCompleted) {
        gotReply.complete(m);
      }
    });

    baseId = await svc.sendMessage(room.id, 'base msg');
    // ignore: avoid_print
    print('BASE id=$baseId');
    await gotBase.future.timeout(const Duration(seconds: 30));

    await svc.sendReaction(room.id, baseId, '👍');
    await svc.sendReply(room.id, 'my reply',
        inReplyToEventId: baseId, inReplyToSender: session.userId);

    final reaction = await gotReaction.future.timeout(const Duration(seconds: 30));
    // ignore: avoid_print
    print('REACTION key=${reaction.reactionKey} target=${reaction.reactionTarget}');
    expect(reaction.reactionKey, '👍');

    final reply = await gotReply.future.timeout(const Duration(seconds: 30));
    // ignore: avoid_print
    print('REPLY body="${reply.body}" replyTo=${reply.replyToEventId}');
    expect(reply.replyToEventId, baseId);
    // ignore: avoid_print
    print('VERIFIED reaction + reply wired to Matrix');

    await sub.cancel();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
