// Full agent loop on device: a real login token authorises the gateway, the
// catalog loads, and DeviceBrain → gateway → Gemini returns a non-empty reply.
// Proves the end-to-end inference path is wired on a real device (free tier).
//   flutter test integration_test/agent_turn_test.dart -d <device> \
//     --dart-define=PIN_USER=admin --dart-define=PIN_PASS=... \
//     --dart-define=PIN_HOMESERVER=https://pin-chat.tokens2.io
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:pin/agent/agent_config.dart';
import 'package:pin/agent/agent_session.dart';
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

  testWidgets('agent turn returns a non-empty reply via the gateway',
      (tester) async {
    await RustLib.init();
    expect(_user.isNotEmpty, true, reason: 'pass --dart-define=PIN_USER');
    final svc = MatrixService.instance;

    await svc.login(homeserver: _homeserver, username: _user, password: _pass);
    final rid = await rust.createSelfRoom();

    final session = AgentSession(room: rid, proxy: devProxy());
    final reply = await session.send(
      'ตอบสั้นๆ คำเดียว: เมืองหลวงของไทยคือ?',
      persistUser: false,
    );
    print('REPLY text="${reply.text}" tools=${reply.usedTools}');
    expect(reply.isEmpty, false, reason: 'gateway must return a reply');

    await rust.leaveRoom(role: 'user', roomId: rid); // cleanup
  }, timeout: const Timeout(Duration(minutes: 3)));
}
