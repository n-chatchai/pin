import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../agent/agent_config.dart';
import '../agent/agent_session.dart';
import '../agent/agentic_job_service.dart';
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
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  static const _ch = MethodChannel('io.tokens2.pin/push');

  /// Latest push token (APNs hex on iOS, FCM token on Android), or null until
  /// registered. Read by the job-create path to register the wake with the server.
  String? deviceToken;

  /// "apns" or "fcm" — so the server knows which channel to push the token on.
  String get platform => Platform.isIOS ? 'apns' : 'fcm';

  Future<void> init() async {
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
      m.onTokenRefresh.listen((t) => deviceToken = t);
      // App in foreground/opened when the wake arrives → run inline.
      FirebaseMessaging.onMessage.listen((_) => _runDue());
      FirebaseMessaging.onMessageOpenedApp.listen((_) => _runDue());
    } catch (e) {
      debugPrint('fcm init failed: $e'); // falls back to AlarmManager / on-open
    }
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onToken':
        deviceToken = call.arguments as String?;
        debugPrint('apns token: ${deviceToken?.substring(0, 8)}…');
        return null;
      case 'onPush':
        await _runDue();
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
    await devProxy().pushRegister(tok, platform);
  }

  Future<void> _runDue() async {
    try {
      if (!await MatrixService.instance.tryRestore()) return;
      final rid = await MatrixService.instance.pinRoomId();
      if (rid == null) return;
      final session = AgentSession(room: rid, proxy: devProxy());
      await runDueAgenticJobs(rid, session);
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
    await runDueAgenticJobs(rid, session);
  } catch (e) {
    debugPrint('fcm bg run-due failed: $e');
  }
}
