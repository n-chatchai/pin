import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../agent/agent_config.dart';
import '../agent/agent_session.dart';
import '../agent/agentic_job_service.dart';
import '../agent/wake_sync.dart';
import '../src/rust/frb_generated.dart';
import 'matrix_service.dart';
import 'prefs.dart';

/// Closed-app wake bridge for agentic jobs. The server (proxy scheduler.py)
/// stores only {job_id, device_token, next_due} and at due time sends a *blind*
/// push — never the prompt or result, which live/run on the phone.
///   • iOS   → native APNs background push (content-available) → [_onNativeCall].
///   • Android → FCM data message → [fcmBackgroundHandler] (closed) / onMessage
///     (foreground). Android also keeps the exact-AlarmManager path as fallback.
/// Either way the wake just triggers [runDueAgenticJobs] on-device.
class PushService with WidgetsBindingObserver {
  PushService._();
  static final PushService instance = PushService._();

  static const _ch = MethodChannel('io.tokens2.pin/push');

  /// Latest push token (APNs hex on iOS, FCM token on Android), or null until
  /// registered. Read by the job-create path to register the wake with the server.
  String? deviceToken;

  /// "apns" or "fcm" — so the server knows which channel to push the token on.
  String get platform => Platform.isIOS ? 'apns' : 'fcm';

  Future<void> init() async {
    // Re-register on every foreground. Boot is racy (FCM token, session restore
    // and network readiness all land at different times, and the token can
    // rotate between launches), so a single boot/login attempt often misses.
    // Resume guarantees session + token + network are up; the upsert is
    // idempotent. This is the reliable catch-all.
    WidgetsBinding.instance.addObserver(this);
    // Cold-start catch: by ~4s the token, session restore and network are up
    // (boot itself is too early — DNS often isn't ready yet).
    Future.delayed(const Duration(seconds: 4), _refreshAndRegister);
    if (Platform.isAndroid) {
      await _initFcm();
      return;
    }
    // iOS: native APNs.
    _ch.setMethodCallHandler(_onNativeCall);
    try {
      await _ch.invokeMethod('registerForPush');
    } catch (_) {/* no native impl → on-open runner still works */}
  }

  Future<void> _initFcm() async {
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(fcmBackgroundHandler);
      final m = FirebaseMessaging.instance;
      await m.requestPermission(); // Android 13+ POST_NOTIFICATIONS (data msgs work regardless)
      deviceToken = await m.getToken();
      debugPrint('fcm token: ${deviceToken?.substring(0, 8)}…');
      await registerWithServer();
      m.onTokenRefresh.listen((t) {
        deviceToken = t;
        registerWithServer();
      });
      // App in foreground/opened when the wake arrives → run inline. An admin
      // force-wake carries data.force == "1" → run every watcher, ignore due.
      FirebaseMessaging.onMessage
          .listen((msg) => _runDue(force: msg.data['force'] == '1'));
      FirebaseMessaging.onMessageOpenedApp
          .listen((msg) => _runDue(force: msg.data['force'] == '1'));
    } catch (e) {
      debugPrint('fcm init failed: $e'); // falls back to AlarmManager / on-open
    }
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onToken':
        deviceToken = call.arguments as String?;
        debugPrint('apns token: ${deviceToken?.substring(0, 8)}…');
        // The APNs token arrives async (after boot), so register here too —
        // boot's registerWithServer often runs before the token exists.
        await registerWithServer();
        return null;
      case 'onPush':
        // iOS native forwards the APNs payload; force-wake sets force == "1".
        final force = (call.arguments is Map) &&
            ('${(call.arguments as Map)['force']}' == '1');
        await _runDue(force: force);
        return null;
      default:
        return null;
    }
  }

  /// Tell the server this user is wakeable (token + platform). Call once the
  /// user is logged in AND a token exists — best-effort, retries next boot.
  Future<void> registerWithServer() async {
    final tok = deviceToken;
    if (tok == null || tok.isEmpty) return;
    
    final proxy = devProxy();
    // Do not register if the matrix session hasn't restored yet (empty token).
    // The matrix_service will trigger this again once it's ready.
    if (proxy.token.isEmpty) return;

    await proxy.pushRegister(tok, platform);

    // Ensure-on-open: reconcile the server wake schedule from room state every
    // time we (re)register — boot, resume, and token refresh all land here. This
    // is the only reliable heal for watches that missed registration (created
    // before the token existed); a user who reopens the app converges.
    final rid = await MatrixService.instance.pinRoomId();
    if (rid != null) await syncWakeSchedule(rid);
  }

  /// Re-fetch the FCM token if it's missing (Android getToken is flaky at cold
  /// start — sometimes never returns), then register. The reliable catch-all,
  /// driven by app-resume + a post-boot timer.
  Future<void> _refreshAndRegister() async {
    if (Platform.isAndroid && (deviceToken == null || deviceToken!.isEmpty)) {
      try {
        deviceToken = await FirebaseMessaging.instance.getToken();
      } catch (_) {/* still no token — try again next resume */}
    }
    await registerWithServer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshAndRegister();
  }

  Future<void> _runDue({bool force = false}) async {
    try {
      if (!await MatrixService.instance.tryRestore()) return;
      final rid = await MatrixService.instance.pinRoomId();
      if (rid == null) return;
      final session = AgentSession(room: rid, proxy: devProxy());
      await runDueAgenticJobs(rid, session, force: force);
    } catch (e) {
      debugPrint('push run-due failed: $e');
    }
  }
}

/// FCM background handler — runs in a SEPARATE isolate with no app state, so it
/// brings up the runtime from scratch before running due jobs. Must be a
/// top-level/static function annotated for AOT entry.
@pragma('vm:entry-point')
Future<void> fcmBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
    // Cold isolate needs the Rust lib; but if the app process is still warm the
    // dylib is already loaded → a second init throws. Guard so both paths work.
    try {
      await RustLib.init();
    } catch (_) {/* already initialized in this process */}
    await PrefsController.instance.load();
    if (!await MatrixService.instance.tryRestore()) return;
    final rid = await MatrixService.instance.pinRoomId();
    if (rid == null) return;
    final session = AgentSession(room: rid, proxy: devProxy());
    await runDueAgenticJobs(rid, session, force: message.data['force'] == '1');
  } catch (e) {
    debugPrint('fcm bg run-due failed: $e');
  }
}
