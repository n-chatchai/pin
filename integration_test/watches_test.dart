// Capability persistence on device: watches (and reminders, same mechanism)
// live in a room STATE event, so they survive logout→relogin with no local
// storage — the room is the single source of truth.
//   flutter test integration_test/watches_test.dart -d <device> \
//     --dart-define=PIN_USER=admin --dart-define=PIN_PASS=... \
//     --dart-define=PIN_HOMESERVER=https://pin-chat.tokens2.io
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

  testWidgets('watches persist in room state across logout→relogin',
      (tester) async {
    await RustLib.init();
    expect(_user.isNotEmpty, true, reason: 'pass --dart-define=PIN_USER');
    final svc = MatrixService.instance;

    await svc.login(homeserver: _homeserver, username: _user, password: _pass);
    final rid = await rust.createSelfRoom(); // id survives in closure
    final topic = 'ทองคำ-${rid.hashCode}';
    final ok = await svc.saveListToRoom(rid, 'io.tokens2.watches', [
      {'topic': topic, 'note': 'ราคาทอง'},
    ]);
    expect(ok, true, reason: 'state write must succeed');
    print('SAVED watch $topic to $rid');

    // New device: wipe + relogin. State events carry in room sync.
    await svc.logout();
    await svc.login(homeserver: _homeserver, username: _user, password: _pass);
    for (var i = 0; i < 6; i++) {
      final rooms = await svc.listRooms();
      if (rooms.any((r) => r.id == rid)) break;
      await Future<void>.delayed(const Duration(seconds: 3));
    }

    var topics = <String>[];
    for (var i = 0; i < 6; i++) {
      final list = await svc.loadListFromRoom(rid, 'io.tokens2.watches');
      topics = [for (final w in list) w['topic'] as String? ?? ''];
      if (topics.contains(topic)) break;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    print('LOADED watches=$topics');
    expect(topics, contains(topic), reason: 'watch must survive relogin');

    await rust.leaveRoom(role: 'user', roomId: rid); // cleanup
  }, timeout: const Timeout(Duration(minutes: 3)));
}
