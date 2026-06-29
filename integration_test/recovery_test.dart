// Deepest device E2EE path: a message sent before logout must DECRYPT again
// after relogin once the recovery key is restored (key backup → download room
// keys). This is the "history หาย after relogin" guarantee.
//   flutter test integration_test/recovery_test.dart -d <device> \
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

  testWidgets('history decrypts after relogin + recovery restore',
      (tester) async {
    await RustLib.init();
    expect(_user.isNotEmpty, true, reason: 'pass --dart-define=PIN_USER');
    final svc = MatrixService.instance;

    await svc.login(homeserver: _homeserver, username: _user, password: _pass);
    svc.messages.listen((_) {}); // start the sync loop → backups upload room keys
    // Reset recovery BEFORE sending so key backup + cross-signing are fresh and
    // server-consistent (UIA password path → uploaded master matches the 4S).
    final key = await rust.resetRecovery(password: _pass);
    expect(key.isNotEmpty, true, reason: 'recovery key');
    print('RECOVERY_KEY len=${key.length}');

    final rid = await rust.createSelfRoom(); // raw room; id survives in closure
    final secret = 'secret-${rid.hashCode}';
    await svc.sendText(rid, secret, role: 'user');
    print('SENT $secret to $rid');

    // Wait for the room key to actually reach the server backup before wiping.
    var backedUp = false;
    for (var i = 0; i < 12 && !backedUp; i++) {
      await Future<void>.delayed(const Duration(seconds: 4));
      backedUp = await svc.backupExists();
    }
    print('BACKUP_ON_SERVER=$backedUp');

    // New device: wipe crypto via logout, log back in.
    await svc.logout();
    await svc.login(homeserver: _homeserver, username: _user, password: _pass);
    svc.messages.listen((_) {}); // restart sync on the "new device"

    // Restore the recovery key → imports the backup decryption key.
    await rust.recoverWithKey(recoveryKey: key);
    print('RECOVERED');

    // Sync the room back into the client store after relogin (initial sync
    // carries joined rooms), then read history.
    for (var i = 0; i < 6; i++) {
      final rooms = await svc.listRooms();
      if (rooms.any((r) => r.id == rid)) break;
      await Future<void>.delayed(const Duration(seconds: 3));
    }

    // roomMessages auto-downloads the room keys when the first page is encrypted.
    var found = false;
    for (var i = 0; i < 6 && !found; i++) {
      final page = await svc.roomMessages(rid, limit: 40);
      found = page.messages.any((m) => m.body == secret);
      if (!found) await Future<void>.delayed(const Duration(seconds: 4));
    }
    print('DECRYPTED old message after restore: $found');
    expect(found, true, reason: 'old message must decrypt after recovery');

    await rust.leaveRoom(role: 'user', roomId: rid); // cleanup
  }, timeout: const Timeout(Duration(minutes: 4)));
}
