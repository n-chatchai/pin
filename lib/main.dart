import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'dart:io';

import 'config.dart';
import 'services/ai_settings.dart';
import 'services/api_log.dart';
import 'src/rust/api/matrix_trace.dart';
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
import 'services/android_job_alarm.dart';
import 'services/notification_service.dart';
import 'services/push_service.dart';
import 'services/prefs.dart';
import 'src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'theme/pin_theme.dart';
import 'theme/theme_controller.dart';

/// Dev flag for screenshots: `--dart-define=PIN_PREVIEW=chat|settings|onboarding`
/// boots straight into that screen with mock data (no login/bot needed).
const _preview = String.fromEnvironment('PIN_PREVIEW');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    // Android: use the modern system Photo Picker (cancellable bottom sheet),
    // not the legacy ACTION_GET_CONTENT that opens Google Photos with no exit.
    final picker = ImagePickerPlatform.instance;
    if (picker is ImagePickerAndroid) picker.useAndroidPhotoPicker = true;
    
    await RustLib.init(
      externalLibrary: Platform.isIOS
          ? ExternalLibrary.process(iKnowHowToUseIt: true)
          : null,
    );
    // Debug builds only: passively observe matrix-sdk's own HTTP tracing spans
    if (kDebugBuild) _startMatrixTrace();
    
    await ThemeController.instance.load();
    await PrefsController.instance.load();
    await AiSettings.instance.load();
    
    // Defer notification initialization until AFTER the app is mounted
    // to prevent blocking the launch screen and causing a white screen.
    Future.microtask(() => NotificationService.instance.init());
    // APNs bridge for closed-app agentic-job wakes (iOS). No-op on Android.
    Future.microtask(() => PushService.instance.init());
    // Exact AlarmManager wakes for closed-app agentic jobs (Android). No-op iOS.
    Future.microtask(() => AndroidJobAlarm.init());

    runApp(const PinApp());
  } catch (e, st) {
    // Failsafe UI if initialization fails (e.g., Rust symbol stripping on iOS Release)
    runApp(MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Text(
              'FATAL ERROR ON LAUNCH:\n\n$e\n\n$st',
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ),
        ),
      ),
    ));
  }
}

/// Subscribe to the Rust Matrix HTTP tracer; each line is one Matrix call's
/// metadata `{method,url,status,ms}` (no headers/bodies). Best-effort.
void _startMatrixTrace() {
  startMatrixTrace().listen((line) {
    try {
      final m = jsonDecode(line) as Map<String, dynamic>;
      ApiLog.instance.addHttp(
        method: '${m['method'] ?? 'MTX'}',
        url: '${m['url'] ?? ''}',
        status: int.tryParse('${m['status'] ?? ''}') ?? 0,
        ms: (m['ms'] as num?)?.toInt() ?? 0,
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
        Widget child;
        if (snap.connectionState != ConnectionState.done) {
          child = const BootLoading('กำลังเชื่อมต่อบัญชี');
        } else {
          child = snap.data == true ? const AfterAuth() : const WelcomeScreen();
        }
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          child: child,
        );
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
  /// On a fresh install the local Keychain is empty (onboarded=false, NOT
  /// persisted locally — room state is the source of truth) but the account may
  /// already have a ปิ่น room. Pull it back to decide onboarding-vs-chat, so we
  /// must await this before gating (can't render non-blocking, or every launch
  /// flashes onboarding + triggers a key reset). It's fast now: findPinRoomId
  /// reads the local store (no blocking sync); on a cold store it returns null
  /// immediately, on a warm store it finds the room and reads a little state.
  late final Future<void> _hydrate = _rehydratePrefs();

  /// Bounded backstop so a stalled homeserver can't wedge the boot screen.
  Future<void> _rehydratePrefs() async {
    try {
      await _doRehydratePrefs().timeout(const Duration(seconds: 12));
    } catch (e) {
      debugPrint('[boot] rehydratePrefs failed/timeout: $e');
    }
  }

  Future<void> _doRehydratePrefs() async {
    // Persona is room-only (never persisted on device), so always pull it from
    // the ปิ่น room state on launch — the room is the single source of truth.
    debugPrint('[boot] rehydrate: findPinRoomId …');
    final id = await MatrixService.instance.findPinRoomId();
    debugPrint('[boot] rehydrate: pinRoom=$id');
    if (id == null) return; // brand-new account → onboarding runs
    final p = await MatrixService.instance.loadPrefsFromRoom(id);
    if (p == null || (p['pin_name'] ?? '').isEmpty) return;

    // Check if E2EE recovery keys need to be restored on this device.
    // E2EE keys are device-specific. If we are on a new device, a key backup
    // exists on the server, but local E2EE recovery is not yet enabled/restored.
    bool needsRestore = false;
    try {
      final state = await MatrixService.instance.recoveryState();
      final hasBackup = await MatrixService.instance.backupExists();
      needsRestore = hasBackup && state != 'enabled';
    } catch (_) {
      try {
        final state = await MatrixService.instance.recoveryState();
        needsRestore = state != 'enabled';
      } catch (_) {
        needsRestore = true;
      }
    }

    await PrefsController.instance.update(
      PrefsController.instance.value
          .copyWithRoomState(p)
          .copyWith(onboarded: !needsRestore, personaSetup: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _hydrate,
      builder: (context, hsnap) {
        Widget child;
        if (hsnap.connectionState != ConnectionState.done) {
          child = const BootLoading('กำลังเตรียมข้อมูล');
        } else {
          child = _gate();
        }
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          child: child,
        );
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
