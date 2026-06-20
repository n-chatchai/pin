import 'dart:convert';

import 'package:flutter/material.dart';

import 'config.dart';
import 'services/api_log.dart';
import 'src/rust/api/inspector.dart';
import 'widgets/boot_loading.dart';
import 'screens/all_tasks_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/welcome_screen.dart';
import 'screens/chat_preview.dart';
import 'screens/local_chat_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/plugins_screen.dart';
import 'screens/settings_screen.dart';
import 'services/matrix_service.dart';
import 'services/notification_service.dart';
import 'services/prefs.dart';
import 'src/rust/frb_generated.dart';
import 'theme/pin_theme.dart';
import 'theme/theme_controller.dart';

/// Dev flag for screenshots: `--dart-define=PIN_PREVIEW=chat|settings|onboarding`
/// boots straight into that screen with mock data (no login/bot needed).
const _preview = String.fromEnvironment('PIN_PREVIEW');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  // Opt-in only (PIN_INSPECTOR, not PIN_DEBUG): start the Matrix HTTP inspector
  // BEFORE any login/restore so build_client routes through the loopback proxy.
  // OFF by default — the proxy MITMs all Matrix traffic, so it must never be on
  // for normal debug use. Each JSON line → the Chuck-style API log.
  if (kInspectorBuild) _startMatrixInspector();
  await ThemeController.instance.load();
  await PrefsController.instance.load();
  await NotificationService.instance.init();
  runApp(const PinApp());
}

/// Subscribe to the Rust inspector proxy; each line is one Matrix HTTP round-trip
/// `{method,url,status,ms,req,resp}`. Best-effort — a parse hiccup drops one row.
void _startMatrixInspector() {
  startMatrixInspector().listen((line) {
    try {
      final m = jsonDecode(line) as Map<String, dynamic>;
      ApiLog.instance.addHttp(
        method: '${m['method'] ?? 'MTX'}',
        url: '${m['url'] ?? ''}',
        status: (m['status'] as num?)?.toInt() ?? 0,
        ms: (m['ms'] as num?)?.toInt() ?? 0,
        reqBody: m['req']?.toString(),
        respBody: m['resp']?.toString(),
      );
    } catch (_) {/* malformed line — skip */}
  });
}

class PinApp extends StatelessWidget {
  const PinApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PinPalette>(
      valueListenable: ThemeController.instance,
      builder: (context, palette, _) => MaterialApp(
        title: 'ปิ่น',
        debugShowCheckedModeBanner: false,
        theme: palette.toTheme(),
        home: _previewHome() ?? const _Bootstrap(),
      ),
    );
  }

  Widget? _previewHome() => switch (_preview) {
        'chat' => const ChatPreview(),
        'settings' =>
          const SettingsScreen(userId: '@test:$kHomeserver'),
        'onboarding' => OnboardingScreen(onDone: () {}),
        'tasks' => const AllTasksScreen(),
        'plugins' => const PluginsScreen(),
        'auth' => const AuthScreen(),
        _ => null,
      };
}

/// Restores an existing session on launch, otherwise shows login.
class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late final Future<bool> _restored = MatrixService.instance.tryRestore();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _restored,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const BootLoading('กำลังเชื่อมต่อบัญชี');
        }
        return snap.data == true ? const AfterAuth() : const WelcomeScreen();
      },
    );
  }
}

/// Post-login gate: show onboarding once, then the home screen.
class AfterAuth extends StatefulWidget {
  const AfterAuth({super.key});

  @override
  State<AfterAuth> createState() => _AfterAuthState();
}

class _AfterAuthState extends State<AfterAuth> {
  /// On a fresh install the local Keychain is empty (onboarded=false) but the
  /// account may already have a ปิ่น room carrying the persona in room state.
  /// Pull it back before we decide whether to run onboarding.
  late final Future<void> _hydrate = _rehydratePrefs();

  Future<void> _rehydratePrefs() async {
    if (PrefsController.instance.value.onboarded) return;
    final id = await MatrixService.instance.findPinRoomId();
    if (id == null) return; // brand-new account → onboarding runs
    final p = await MatrixService.instance.loadPrefsFromRoom(id);
    if (p == null || (p['pin_name'] ?? '').isEmpty) return;
    await PrefsController.instance.update(
      PrefsController.instance.value.copyWith(
        pinName: p['pin_name'],
        userCall: p['user_call'],
        pinSelf: p['pin_self'],
        pinEnding: p['pin_ending'],
        onboarded: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _hydrate,
      builder: (context, hsnap) {
        if (hsnap.connectionState != ConnectionState.done) {
          return const BootLoading('กำลังเตรียมข้อมูล');
        }
        return _gate();
      },
    );
  }

  Widget _gate() {
    return ValueListenableBuilder<PinPrefs>(
      valueListenable: PrefsController.instance,
      builder: (context, prefs, _) {
        if (!prefs.onboarded) {
          return OnboardingScreen(onDone: () {}); // prefs update drives rebuild
        }
        // E2EE: same polished chat UI, backed by the on-device agent (no server
        // bot). Conversation + memory stay on the phone.
        return const LocalChatScreen();
      },
    );
  }
}
