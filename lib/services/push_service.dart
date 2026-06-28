import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../agent/agent_config.dart';
import '../agent/agent_session.dart';
import '../agent/agentic_job_service.dart';
import 'matrix_service.dart';

/// Bridges native APNs to the agentic-job runner so jobs fire when the app is
/// CLOSED (the on-open path is in local_chat_screen). The server (proxy
/// scheduler.py) holds only {job_id, device_token, next_due} and, at due time,
/// sends an APNs *background* push (`content-available:1`, `pin_job`). iOS wakes
/// the app, native forwards the push here, and we run the job on-device — the
/// server never sees the prompt or the result.
///
/// iOS only: the server pushes via APNs directly (no FCM), so Android jobs run
/// on next app open/resume via the same [runDueAgenticJobs].
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  static const _ch = MethodChannel('io.tokens2.pin/push');

  /// Latest hex APNs device token, or null until native registers one. Read by
  /// the job-create path to register the wake with the server.
  String? deviceToken;

  /// Wire the native→Dart handler + ask native to register for remote pushes.
  /// Safe no-op on platforms with no native side (the channel just never calls).
  Future<void> init() async {
    _ch.setMethodCallHandler(_onNativeCall);
    try {
      await _ch.invokeMethod('registerForPush');
    } catch (_) {/* no native impl (e.g. Android) → on-open runner still works */}
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onToken':
        deviceToken = call.arguments as String?;
        debugPrint('apns token: ${deviceToken?.substring(0, 8)}…');
        return null;
      case 'onPush':
        // A wake arrived (we ignore the specific job_id and just run everything
        // due — simpler and self-heals if a push was missed). iOS gives ~30s.
        await _runDue();
        return null;
      default:
        return null;
    }
  }

  Future<void> _runDue() async {
    try {
      // Cold wake: restore the user session so the reply can post into the
      // self-DM. Best-effort — if it can't come up in the background window the
      // job is left in place and runs on next app open.
      if (!await MatrixService.instance.tryRestore()) return;
      final rid = await MatrixService.instance.pinRoomId();
      if (rid == null) return; // no self-room yet — runs on next open instead
      final session = AgentSession(room: rid, proxy: devProxy());
      await runDueAgenticJobs(rid, session);
    } catch (e) {
      debugPrint('push run-due failed: $e');
    }
  }
}
