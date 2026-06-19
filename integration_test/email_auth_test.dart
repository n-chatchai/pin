// Verifies email auth: signing in provisions a Matrix account (register-or-login)
// and the E2EE client works after.
//   flutter test integration_test/email_auth_test.dart -d <sim>
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:pin/services/auth_service.dart';
import 'package:pin/services/matrix_service.dart';
import 'package:pin/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('email sign-in provisions a working Matrix account',
      (tester) async {
    await RustLib.init();
    // Stable test email so re-runs log into the same account.
    const email = 'pin-emailtest@example.com';
    const password = 'pw-emailtest-123';

    await AuthService().signInWithEmail(
      homeserver: 'chat.tokens2.io',
      email: email,
      password: password,
    );

    // If E2EE client is up, listing rooms succeeds (even if empty).
    final rooms = await MatrixService.instance.listRooms();
    // ignore: avoid_print
    print('EMAIL AUTH OK — rooms=${rooms.length}');
    expect(rooms, isA<List>());
  }, timeout: const Timeout(Duration(minutes: 3)));
}
