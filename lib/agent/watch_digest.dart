import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../services/android_job_alarm.dart';
import '../services/matrix_service.dart';
import '../services/notification_service.dart';
import '../services/now_controllers.dart';
import '../services/pin_meta.dart';
import '../services/prefs.dart';
import 'agent_config.dart';
import 'agent_reply.dart';
import 'device_brain.dart';
import 'tools.dart';
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
  final p = PrefsController.instance.value;
  final now = DateTime.now();
  // Deliver only near the set time. The exact alarm (Android) / APNs (iOS)
  // fires at that time; a stale open-catch-up hours later is skipped so the
  // briefing stays "at your time", not whenever the app happens to open (it'll
  // fire on tomorrow's alarm instead). Window = [set-10min, set+2h].
  final parts = p.morningTime.split(':');
  final setH = int.tryParse(parts.first) ?? 8;
  final setM = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
  final setAt = DateTime(now.year, now.month, now.day, setH, setM);
  final lateMins = now.difference(setAt).inMinutes;
  if (lateMins < -10 || lateMins > 120) return;

  final watches = await MatrixService.instance
      .loadListFromRoom(rid, 'io.tokens2.watches');
  final pending = watches
      .where((w) =>
          w['pending_digest'] == true && '${w['last_seen'] ?? ''}'.isNotEmpty)
      .toList();
  if (pending.isEmpty) return;

  // ปิ่น composes the briefing itself (structured output via compose_digest):
  // persona voice comes free, and it dedups/judges what's actually worth
  // showing across the batch — no hardcoded persona strings, no template feel.
  final card = await _composeDigest(pending, p) ??
      // Fallback if the model didn't emit a card (network/parse) — code-built.
      buildDigestCard(pending,
          time: p.morningTime, ending: p.pinEnding,
          dateLabel: '${now.day} ${_thaiMonths[now.month]}');
  final body =
      pending.map((w) => '• ${w['topic']}: ${w['last_seen']}').join('\n');
  await MatrixService.instance.sendText(rid, body,
      role: 'user', flex: card, meta: pinMeta(const ['watch']));
  await NotificationService.instance
      .showNow(rid, '${p.pinName}สรุปให้ · ${pending.length} เรื่องที่เฝ้าไว้');

  for (final w in pending) {
    w['pending_digest'] = false;
  }
  await MatrixService.instance
      .saveListToRoom(rid, 'io.tokens2.watches', watches);
  WatchesController.instance.updateFromJson(jsonEncode(watches));
}

/// Run one LLM turn where ปิ่น composes the digest via the compose_digest tool
/// (structured output: title/summary/items). Returns the flex card, or null if
/// the model didn't produce one. Persona (name/voice) is in the system prompt,
/// so the wording is natural; the model also dedups the pending findings.
Future<Map<String, dynamic>?> _composeDigest(
    List<Map<String, dynamic>> pending, PinPrefs p) async {
  try {
    final compose = AgentTool(
      fnDecl(
        'compose_digest',
        'สร้างการ์ดสรุปประจำวันจากเรื่องที่เฝ้าไว้ (เรียกเครื่องมือนี้เท่านั้น ไม่ต้องพิมพ์ข้อความ)',
        properties: {
          'title': {
            'type': 'string',
            'description': 'ทักทายสั้น ๆ ด้วยเสียงของคุณเอง (ตาม persona)'
          },
          'summary': {
            'type': 'string',
            'description': 'ภาพรวมสั้น ๆ 1 บรรทัด (ไม่ใส่ก็ได้)'
          },
          'items': {
            'type': 'array',
            'description':
                'เฉพาะเรื่องที่มีอัปเดตใหม่จริง — ตัดเรื่องซ้ำ/ไม่สำคัญ/เก่าออก',
            'items': {
              'type': 'object',
              'properties': {
                'topic': {'type': 'string'},
                'text': {'type': 'string', 'description': 'สรุป 1-2 ประโยค'},
                'source': {'type': 'string', 'description': 'URL ถ้ามี'},
                'icon': {
                  'type': 'string',
                  'enum': ['news', 'money', 'chart', 'calendar', 'heart', 'sparkles']
                }
              },
              'required': ['topic', 'text'],
            }
          },
        },
        required: ['title', 'items'],
      ),
      (args) async => ToolResult.terminal(
          AgentReply(flex: buildDigestFromItems(args, time: p.morningTime))),
    );

    final system = '${kPinSystemFor(
      name: p.pinName,
      userCall: p.userCall,
      self: p.pinSelf,
      tone: p.tone,
      lang: p.lang,
      persona: p.personaMode,
      customCall: p.customCall,
      customSelf: p.customSelf,
    )}\n\nนี่คืองานสรุปประจำวันของเรื่องที่ผู้ใช้ให้คุณเฝ้าไว้ (ไม่มีผู้ใช้อยู่ตรงนี้). '
        'อ่านรายการอัปเดตด้านล่าง ตัดเรื่องที่ซ้ำกันหรือไม่ใช่ของใหม่จริง ๆ ออก '
        'แล้วเรียก compose_digest เพื่อสร้างการ์ดสรุป — title เป็นคำทักทายด้วยเสียงของคุณ, '
        'items แต่ละเรื่องสรุปสั้น ๆ พร้อม source ถ้ามี. อย่าพิมพ์ข้อความอื่น.';

    final userText = pending
        .map((w) => '- ${w['topic']}: ${w['last_seen']}'
            '${'${w['source'] ?? ''}'.isNotEmpty ? ' (source: ${w['source']})' : ''}')
        .join('\n');

    final brain = DeviceBrain(
      proxy: devProxy(),
      tools: ToolRegistry([compose]),
      system: system,
    );
    final reply = await brain.reply(const [], userText);
    return reply.flex;
  } catch (e) {
    debugPrint('compose digest failed, using fallback: $e');
    return null;
  }
}
