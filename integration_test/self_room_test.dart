// On-device check of the self-room determinism fix: the canonical self-room id
// lives in an account-data pointer, so logout→relogin resolves the SAME room
// (no duplicate spawning, no history orphaning).
//   flutter test integration_test/self_room_test.dart -d <device> \
//     --dart-define=PIN_USER=admin --dart-define=PIN_PASS=... \
//     --dart-define=PIN_HOMESERVER=https://pin-chat.tokens2.io
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:pin/services/matrix_service.dart';
import 'package:pin/services/pin_meta.dart';
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

  testWidgets('self-room pointer is deterministic across logout→relogin',
      (tester) async {
    await RustLib.init();
    expect(_user.isNotEmpty, true, reason: 'pass --dart-define=PIN_USER');
    final svc = MatrixService.instance;

    await svc.login(homeserver: _homeserver, username: _user, password: _pass);
    final rid1 = await svc.getOrCreatePinDm();
    print('rid1=$rid1');

    // The account-data pointer now points at that room.
    final ptr = await rust.accountDataGet(
        role: 'user', name: 'io.tokens2.selfroom');
    expect(selfRoomId(ptr), rid1, reason: 'pointer must hold the self-room id');

    // Logout (wipes the device crypto store) then log back in.
    await svc.logout();
    await svc.login(homeserver: _homeserver, username: _user, password: _pass);

    final rid2 = await svc.getOrCreatePinDm();
    print('rid2=$rid2');
    expect(rid2, rid1, reason: 'relogin must resolve the SAME room (no dup)');

    // Exactly one ปิ่น room exists (self-heal left no duplicates).
    final pinRooms =
        (await svc.listRooms()).where((r) => r.name == 'ปิ่น').toList();
    print('pin rooms=${pinRooms.length}');
    expect(pinRooms.length, 1, reason: 'no duplicate self-rooms');

    await rust.leaveRoom(role: 'user', roomId: rid1); // cleanup
  }, timeout: const Timeout(Duration(minutes: 3)));
}
