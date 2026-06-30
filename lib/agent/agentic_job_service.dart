import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../services/notification_service.dart';

import '../services/matrix_service.dart';
import '../services/now_controllers.dart';
import '../services/pin_meta.dart';
import 'agent_config.dart';
import 'agent_session.dart';
import 'job_runner.dart';
import 'proxy_client.dart';

/// Runs ปิ่น's agentic jobs (the `schedule_job` tool, kind == 'agentic') whose
/// time has come. Called from TWO places that can overlap, so the run is behind
/// a process-wide guard:
///   • chat boot/resume (local_chat_screen) — the app-is-open path;
///   • the APNs silent-push wake (PushService) — the app-was-closed path.
/// The `at`/`time`/`lastRun` due logic lives in the pure, unit-tested
/// [dueAgenticJobs]; this layer does the I/O (room read, agent turn, room write).

bool _running = false;

/// Execute every due agentic job in [rid] using [session] for the agent turn,
/// posting ปิ่น's reply into the DM. One-shots are removed + cancelled
/// server-side after running; daily ones record `lastRun` (server rolls its own
/// copy forward). Best-effort — a failed job is left in place to retry.
/// [force] ignores the schedule/lastRun and runs EVERY agentic job now (used by
/// the admin force-wake) — otherwise only jobs whose time has come run.
Future<void> runDueAgenticJobs(String rid, AgentSession session,
    {bool force = false}) async {
  if (_running) return;
  _running = true;
  try {
    final jobs =
        await MatrixService.instance.loadListFromRoom(rid, 'io.tokens2.reminders');
    final now = DateTime.now();
    final due = force
        ? [for (final j in jobs) if ('${j['kind']}' == 'agentic') '${j['id']}']
        : dueAgenticJobs(jobs, now);
    if (due.isEmpty) return;
    final ProxyClient proxy = devProxy();
    var changed = false;
    for (final id in due) {
      final job = jobs.firstWhere((j) => '${j['id']}' == id);
      var foundNew = false; // did this run surface something? → drives backoff
      try {
        final r = await session.send('${job['text'] ?? ''}', persistUser: false);
        // A watch job that finds nothing new returns an empty reply → stay
        // silent (don't post). Only ping when ปิ่น actually has something.
        final hasReply = (r.text?.trim().isNotEmpty ?? false) || r.flex != null;
        foundNew = hasReply;
        if (hasReply) {
          final body = (r.text?.isNotEmpty ?? false)
              ? r.text!
              : '(ส่งการ์ดให้แล้ว)';
          // Post as ปิ่น; the live DM subscription renders it (no optimistic
          // bubble to dedup, so don't mark it seen).
          await MatrixService.instance.sendText(rid, body,
              role: 'user', flex: r.flex, meta: pinMeta(r.usedTools));
          // Notify so a watch finding / fired reminder is visible even when the
          // app is closed (this runs in the FCM/APNs bg isolate too). The chat
          // screen dedups its own optimistic render, so this only adds the OS
          // notification, not a duplicate bubble.
          await NotificationService.instance.showNow(rid, body);
        }
      } catch (e) {
        debugPrint('run job $id failed (retry next wake): $e');
        continue; // leave it in place
      }
      final intervalSec = (job['interval_sec'] as num?)?.toInt();
      if (intervalSec != null && intervalSec > 0) {
        // Interval (adaptive watch) job: stamp lastRun + re-pace. Found something
        // → snap to floor; silent → back off. Server keeps waking at the floor
        // cadence (a no-op until this larger interval elapses), so no re-register.
        job['lastRun'] = now.millisecondsSinceEpoch;
        final floor = (job['floor_sec'] as num?)?.toInt() ?? intervalSec;
        job['interval_sec'] =
            nextWatchInterval(intervalSec, floor, foundNew: foundNew);
      } else if ('${job['repeat']}' == 'daily') {
        // Daily jobs recur — stamp lastRun so the due logic waits a full day.
        job['lastRun'] = now.millisecondsSinceEpoch;
      } else {
        jobs.removeWhere((j) => '${j['id']}' == id);
        unawaited(proxy.scheduleCancel(id)); // stop the server re-pushing it
      }
      changed = true;
    }
    if (changed) {
      await MatrixService.instance
          .saveListToRoom(rid, 'io.tokens2.reminders', jobs);
      JobsController.instance.updateFromJson(jsonEncode(jobs));
    }
  } catch (e) {
    debugPrint('run due jobs failed: $e');
  } finally {
    _running = false;
  }
}
