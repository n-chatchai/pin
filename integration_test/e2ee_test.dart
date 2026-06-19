// End-to-end E2EE check: create an encrypted room, send a message, and confirm
// it round-trips back decrypted through the sync stream.
//   flutter test integration_test/e2ee_test.dart -d <sim> \
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

  testWidgets('create encrypted room, send + receive decrypted', (tester) async {
    await RustLib.init();
    expect(_user.isNotEmpty, true, reason: 'pass --dart-define=PIN_USER');

    final svc = MatrixService.instance;
    await svc.login(
      homeserver: _homeserver,
      username: _user,
      password: _pass,
    );

    final room = await svc.createEncryptedRoom('pin-e2ee');
    // ignore: avoid_print
    print('CREATED room=${room.id} enc=${room.isEncrypted}');
    expect(room.isEncrypted, true, reason: 'room must be encrypted');

    // Subscribe before sending so we catch the echo.
    final body = 'hello e2ee ${room.id.hashCode}';
    final got = Completer<ChatMessage>();
    final sub = svc.messages
        .where((m) => m.roomId == room.id && m.body == body)
        .listen((m) {
      if (!got.isCompleted) got.complete(m);
    });

    await svc.sendMessage(room.id, body);
    // ignore: avoid_print
    print('SENT to ${room.id}');

    final received = await got.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw TimeoutException('no decrypted echo received'),
    );
    // ignore: avoid_print
    print('RECEIVED decrypted body="${received.body}" isMe=${received.isMe}');
    expect(received.body, body);
    expect(received.isMe, true);

    // Confirm the room shows as encrypted in the listing too.
    final rooms = await svc.listRooms();
    final mine = rooms.firstWhere((r) => r.id == room.id);
    expect(mine.isEncrypted, true);
    // ignore: avoid_print
    print('VERIFIED encrypted room in listing: ${mine.name}');

    await sub.cancel();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
