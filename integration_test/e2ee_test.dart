// On-device E2EE check: create the encrypted self-room, send a message, and
// confirm it round-trips back DECRYPTED through the sync stream. This is the one
// path API-level e2e can't cover (it needs real device crypto).
//   flutter test integration_test/e2ee_test.dart -d <device> \
//     --dart-define=PIN_USER=admin --dart-define=PIN_PASS=... \
//     --dart-define=PIN_HOMESERVER=https://pin-chat.tokens2.io
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:pin/services/matrix_service.dart';
import 'package:pin/src/rust/api/matrix.dart' as rust;
import 'package:pin/src/rust/frb_generated.dart';

const _user = String.fromEnvironment('PIN_USER');
const _pass = String.fromEnvironment('PIN_PASS');
const _homeserver = String.fromEnvironment(
  'PIN_HOMESERVER',
  defaultValue: 'https://pin-chat.tokens2.io',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('self-room: send → decrypted echo round-trips', (tester) async {
    await RustLib.init();
    expect(_user.isNotEmpty, true, reason: 'pass --dart-define=PIN_USER');

    final svc = MatrixService.instance;
    await svc.login(homeserver: _homeserver, username: _user, password: _pass);

    // Fresh single-member encrypted room (the self-DM primitive).
    final rid = await rust.createSelfRoom();
    print('CREATED $rid');

    // Touch the messages getter first to start the user sync loop, then listen.
    final body = 'hello e2ee ${rid.hashCode}';
    final got = Completer<rust.ChatMessage>();
    final sub = svc.messages
        .where((m) => m.roomId == rid && m.body == body)
        .listen((m) {
      if (!got.isCompleted) got.complete(m);
    });

    await svc.sendText(rid, body, role: 'user');
    print('SENT to $rid');

    final received = await got.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw TimeoutException('no decrypted echo received'),
    );
    print('RECEIVED decrypted body="${received.body}"');
    expect(received.body, body);

    // Room shows encrypted in the listing too.
    final rooms = await svc.listRooms();
    final mine = rooms.firstWhere((r) => r.id == rid);
    expect(mine.isEncrypted, true, reason: 'self-room must be encrypted');
    print('VERIFIED encrypted room: ${mine.name}');

    await sub.cancel();
    await rust.leaveRoom(role: 'user', roomId: rid); // cleanup
  }, timeout: const Timeout(Duration(minutes: 3)));
}
