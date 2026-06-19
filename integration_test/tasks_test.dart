// Verifies task sync: ask ปิ่น to add a task → bot tracks it and pushes
// io.tokens2.tasks → app surfaces it (kind=tasks payload).
//   flutter test integration_test/tasks_test.dart -d <sim> \
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

  testWidgets('adding a task syncs to the app', (tester) async {
    await RustLib.init();
    final svc = MatrixService.instance;
    await svc.login(homeserver: _homeserver, username: _user, password: _pass);

    final room = await svc.createEncryptedRoom('pin-tasks-test', invite: [_bot]);
    await Future<void>.delayed(const Duration(seconds: 10));

    final tasksMsg = Completer<ChatMessage>();
    final sub = svc.messages
        .where((m) => m.roomId == room.id && m.kind == 'tasks')
        .listen((m) {
      if (!tasksMsg.isCompleted) tasksMsg.complete(m);
    });

    await svc.sendMessage(
      room.id,
      'เพิ่มงานค้างให้หน่อย: กลุ่มรอคุณ "ส่งงานลูกค้า Z" กำหนดวันนี้',
    );
    // ignore: avoid_print
    print('ASKED to add task');

    final m = await tasksMsg.future.timeout(const Duration(seconds: 90));
    // ignore: avoid_print
    print('TASKS PAYLOAD: ${m.flexJson}');
    expect(m.flexJson != null && m.flexJson!.contains('ส่งงานลูกค้า Z'), true);
    await sub.cancel();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
