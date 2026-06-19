// Verifies the weather plugin: ask ปิ่น for weather → bot calls Open-Meteo →
// sends a weather Flex card.
//   flutter test integration_test/weather_test.dart -d <sim> \
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

  testWidgets('weather plugin returns a flex card', (tester) async {
    await RustLib.init();
    final svc = MatrixService.instance;
    await svc.login(homeserver: _homeserver, username: _user, password: _pass);

    final room = await svc.createEncryptedRoom('pin-weather-test', invite: [_bot]);
    await Future<void>.delayed(const Duration(seconds: 10));

    final card = Completer<ChatMessage>();
    final sub = svc.messages
        .where((m) => m.roomId == room.id && m.sender == _bot && m.kind == 'flex')
        .listen((m) {
      if (!card.isCompleted) card.complete(m);
    });

    await svc.sendMessage(room.id, 'อากาศกรุงเทพวันนี้เป็นยังไงบ้าง');
    final m = await card.future.timeout(const Duration(seconds: 90));
    // ignore: avoid_print
    print('WEATHER CARD: ${m.flexJson}');
    expect(m.flexJson != null && m.flexJson!.contains('อากาศ'), true);
    expect(m.flexJson!.contains('°C') || m.flexJson!.contains('โอกาสฝน'), true);
    await sub.cancel();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
