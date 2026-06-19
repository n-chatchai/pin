// End-to-end check against the real chat.tokens2.io homeserver.
// Credentials are injected at run time, never hardcoded:
//   flutter test integration_test/login_test.dart -d <sim> \
//     --dart-define=PIN_USER=... --dart-define=PIN_PASS=...
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:pin/services/matrix_service.dart';
import 'package:pin/src/rust/frb_generated.dart';

const _user = String.fromEnvironment('PIN_USER');
const _pass = String.fromEnvironment('PIN_PASS');
const _homeserver = String.fromEnvironment(
  'PIN_HOMESERVER',
  defaultValue: 'https://chat.tokens2.io',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real E2EE login + list rooms', (tester) async {
    await RustLib.init();
    expect(_user.isNotEmpty, true, reason: 'pass --dart-define=PIN_USER');

    final session = await MatrixService.instance.login(
      homeserver: _homeserver,
      username: _user,
      password: _pass,
    );
    // ignore: avoid_print
    print('LOGGED_IN user=${session.userId} device=${session.deviceId}');
    expect(session.userId.startsWith('@'), true);

    final rooms = await MatrixService.instance.listRooms();
    // ignore: avoid_print
    print('ROOM_COUNT=${rooms.length}');
    for (final r in rooms) {
      // ignore: avoid_print
      print('ROOM id=${r.id} name="${r.name}" enc=${r.isEncrypted}');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
