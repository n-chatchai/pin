import 'dart:convert';

import '../services/android_job_alarm.dart';
import '../services/matrix_service.dart';
import '../services/notification_service.dart';
import '../services/now_controllers.dart';
import '../services/pin_meta.dart';
import '../services/prefs.dart';
import 'wake_sync.dart';
import 'watch_card.dart';
import 'when_parse.dart';

/// The daily watch briefing. Watch checks run on their own cadence and store
/// findings silently (pending_digest); this one job — a daily agentic reminder
/// at the user's chosen time — gathers everything pending into ONE calm card so
/// ปิ่น never pings the user in rapid bursts. Urgent findings bypass it (posted
/// immediately by update_watch).
const kDigestJobId = '_watch_digest';

const _thaiMonths = [
  '', 'ม.ค.', 'ก.พ.', 'มี.ค.', 'เม.ย.', 'พ.ค.', 'มิ.ย.',
  'ก.ค.', 'ส.ค.', 'ก.ย.', 'ต.ค.', 'พ.ย.', 'ธ.ค.',
];

/// Ensure a daily digest job exists at the user's time when the briefing is on.
/// Idempotent — safe to call on every add_watch. Removes it if the user turned
/// the briefing off.
Future<void> ensureDigestJob(String rid) async {
  final p = PrefsController.instance.value;
  final reminders = await MatrixService.instance
      .loadListFromRoom(rid, 'io.tokens2.reminders');
  final has = reminders.any((r) => '${r['id']}' == kDigestJobId);
  if (!p.morningReminder) {
    if (has) {
      reminders.removeWhere((r) => '${r['id']}' == kDigestJobId);
      await _save(rid, reminders);
    }
    return;
  }
  if (has) return; // already scheduled; time changes go through reschedule
  final when = parseWhen(p.morningTime) ?? parseWhen('08:00')!;
  reminders.add({
    'id': kDigestJobId,
    'time': hhmm(when),
    'text': '', // runner handles this id specially — no LLM turn
    'repeat': 'daily',
    'kind': 'agentic',
    'at': when.millisecondsSinceEpoch,
  });
  await _save(rid, reminders);
}

/// Re-time the digest job (call when the user changes the briefing time/toggle).
Future<void> rescheduleDigestJob(String rid) async {
  final reminders = await MatrixService.instance
      .loadListFromRoom(rid, 'io.tokens2.reminders');
  reminders.removeWhere((r) => '${r['id']}' == kDigestJobId);
  await _save(rid, reminders);
  await ensureDigestJob(rid);
}

Future<void> _save(String rid, List<Map<String, dynamic>> reminders) async {
  await MatrixService.instance
      .saveListToRoom(rid, 'io.tokens2.reminders', reminders);
  JobsController.instance.updateFromJson(jsonEncode(reminders));
  await syncWakeSchedule(rid);
  await AndroidJobAlarm.armAll(rid);
}

/// Deliver the briefing: gather watches with a pending finding → one card →
/// clear their pending flag. Silent when nothing is pending.
Future<void> runDigest(String rid) async {
  final watches = await MatrixService.instance
      .loadListFromRoom(rid, 'io.tokens2.watches');
  final pending = watches
      .where((w) =>
          w['pending_digest'] == true && '${w['last_seen'] ?? ''}'.isNotEmpty)
      .toList();
  if (pending.isEmpty) return;

  final p = PrefsController.instance.value;
  final now = DateTime.now();
  final card = buildDigestCard(pending,
      time: p.morningTime,
      dateLabel: '${now.day} ${_thaiMonths[now.month]}');
  final body =
      pending.map((w) => '• ${w['topic']}: ${w['last_seen']}').join('\n');
  await MatrixService.instance.sendText(rid, body,
      role: 'user', flex: card, meta: pinMeta(const ['watch']));
  await NotificationService.instance
      .showNow(rid, 'สรุปเช้านี้ · ${pending.length} เรื่องที่เฝ้าไว้');

  for (final w in pending) {
    w['pending_digest'] = false;
  }
  await MatrixService.instance
      .saveListToRoom(rid, 'io.tokens2.watches', watches);
  WatchesController.instance.updateFromJson(jsonEncode(watches));
}
