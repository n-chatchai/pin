// Verifies ปิ่น can schedule a reminder via Gemini function-calling.
//   flutter test integration_test/schedule_test.dart -d <sim> \
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

  testWidgets('bot schedules a daily reminder', (tester) async {
    await RustLib.init();
    final svc = MatrixService.instance;
    await svc.login(homeserver: _homeserver, username: _user, password: _pass);

    final room = await svc.createEncryptedRoom('pin-sched-test', invite: [_bot]);
    await Future<void>.delayed(const Duration(seconds: 10));

    final confirm = Completer<ChatMessage>();
    final sub = svc.messages
        .where((m) => m.roomId == room.id && m.sender == _bot && m.kind == 'text')
        .listen((m) {
      if (m.body.contains('เตือน') && !confirm.isCompleted) confirm.complete(m);
    });

    await svc.sendMessage(room.id, 'เตือนกินยาทุกวันตอน 9 โมงเช้าด้วยนะ');
    // ignore: avoid_print
    print('ASKED to schedule');

    final m = await confirm.future.timeout(const Duration(seconds: 90));
    // ignore: avoid_print
    print('CONFIRM: ${m.body}');
    expect(m.body.contains('เตือน'), true);
    expect(m.body.contains('09:00') || m.body.contains('ทุกวัน'), true);
    await sub.cancel();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
