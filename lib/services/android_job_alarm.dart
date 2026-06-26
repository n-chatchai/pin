import 'dart:io';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/widgets.dart';

import '../agent/agent_config.dart';
import '../agent/agent_session.dart';
import '../agent/agentic_job_service.dart';
import '../agent/job_runner.dart';
import '../src/rust/frb_generated.dart';
import 'ai_settings.dart';
import 'matrix_service.dart';
import 'prefs.dart';

/// Android closed-app path for agentic jobs. iOS can't run scheduled background
/// code so it routes through the server (APNs) — Android CAN, so we use an exact
/// AlarmManager wake (no server, no FCM): at the job's time the OS spins a
/// background isolate, [_alarmCallback] re-inits the app stack and runs the due
/// jobs via the shared [runDueAgenticJobs]. Best-effort: Doze / process death /
/// no-network can still defer a run to the next app open (the on-open runner
/// covers that). No-op on non-Android.
class AndroidJobAlarm {
  AndroidJobAlarm._();

  /// Alarm ids share the 31-bit space the notifications use (job id is a 13-digit
  /// millisecondsSinceEpoch), so the same job maps to a stable alarm id.
  static int _aid(String jobId) =>
      (int.tryParse(jobId) ?? jobId.hashCode) & 0x7fffffff;

  /// Initialize the plugin (call once at boot, Android only).
  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    await AndroidAlarmManager.initialize();
  }

  /// (Re)arm an exact alarm for every upcoming agentic job in [rid]. Called on
  /// boot/resume (survives relaunch) and after a job runs (re-arms the next
  /// daily fire). No-op on non-Android.
  static Future<void> armAll(String rid) async {
    if (!Platform.isAndroid) return;
    final jobs =
        await MatrixService.instance.loadListFromRoom(rid, 'io.tokens2.reminders');
    for (final a in agenticAlarmsToArm(jobs, DateTime.now())) {
      await AndroidAlarmManager.oneShotAt(
        a.fireAt,
        _aid(a.id),
        _alarmCallback,
        exact: true,
        wakeup: true,
        allowWhileIdle: true,
        rescheduleOnReboot: true,
      );
    }
  }

  /// Cancel the alarm for a removed job (no-op on non-Android / never armed).
  static Future<void> cancel(String jobId) async {
    if (!Platform.isAndroid) return;
    await AndroidAlarmManager.cancel(_aid(jobId));
  }
}

/// Background-isolate entry point fired by AlarmManager. Top-level + vm:entry-point
/// so it survives tree-shaking and can be invoked headless. Re-inits the minimum
/// stack (Rust + prefs + companion session), runs due jobs, then re-arms (picks
/// up the next daily occurrence even if the app never opened).
@pragma('vm:entry-point')
Future<void> _alarmCallback(int alarmId) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await RustLib.init(); // Android loads the .so normally (no external lib)
    await PrefsController.instance.load();
    await AiSettings.instance.load();
    await AndroidAlarmManager.initialize(); // so the re-arm below can schedule
    await MatrixService.instance.ensurePinSession();
    final rid = await MatrixService.instance.pinRoomId();
    if (rid == null) return; // not provisioned — runs on next app open
    final session = AgentSession(room: rid, proxy: devProxy());
    await runDueAgenticJobs(rid, session);
    await AndroidJobAlarm.armAll(rid); // re-arm next daily fire
  } catch (e) {
    debugPrint('android job alarm failed: $e');
  }
}
