import 'dart:convert';

import '../services/android_job_alarm.dart';
import '../services/matrix_service.dart';
import '../services/notification_service.dart';
import '../services/now_controllers.dart';
import '../services/pin_meta.dart';
import '../services/prefs.dart';
import '../services/tasks_controller.dart';
import 'agent_config.dart';
import 'agent_reply.dart';
import 'agent_store.dart';
import 'tools.dart';
import 'wake_sync.dart';
import 'watch_card.dart';
import 'watch_digest.dart';
import 'when_parse.dart';

/// On-device "ตอนนี้" tools: let ปิ่น create reminders / jobs / tasks / memory.
/// The data lives in the ปิ่น DM room state (the single source of truth) — the
/// server bot that used to write it is gone, so the model must call these.
///
/// Each tool builds a fresh [AgentStore] and `load()`s it: that overlays the
/// room copy on top of the local cache (the same pattern now_screen/abilities
/// use). The store's write methods (addReminder/addFact/addKnowledge) mirror
/// straight back to Matrix room state, so there's no shared instance to thread
/// through the session — the room is the source of truth.

/// Short Thai phrasing of when the reminder fires, for the feedback line.
String _whenLabel(DateTime when, bool daily) {
  if (daily) return 'ทุกวันเวลา ${hhmm(when)} น.';
  final now = DateTime.now();
  final sameDay =
      when.year == now.year && when.month == now.month && when.day == now.day;
  if (sameDay) return 'วันนี้ ${hhmm(when)} น.';
  return '${when.year}-${when.month.toString().padLeft(2, '0')}-'
      '${when.day.toString().padLeft(2, '0')} ${hhmm(when)} น.';
}

/// Build a reminder/job, persist it to room state + schedule the OS notification.
/// Returns (ok, message) — ok=false means it didn't record (the caller feeds the
/// message back so ปิ่น can retry instead of falsely confirming).
Future<(bool, String)> _scheduleEntry(
  Map<String, dynamic> args, {
  required String kind, // 'reminder' | 'agentic'
}) async {
  final text = '${args['text'] ?? ''}'.trim();
  if (text.isEmpty) return (false, 'ขอข้อความที่จะเตือนด้วยนะ');
  final repeat = '${args['repeat'] ?? 'once'}' == 'daily' ? 'daily' : 'once';
  final rawTime = '${args['time'] ?? ''}'.trim();
  final when = rawTime.isEmpty ? null : parseWhen(rawTime);
  if (when == null) {
    return (false,
        'อ่านเวลาไม่ออก ลองบอกเป็น "HH:MM", "+30m" หรือวันเวลาแบบ ISO นะ');
  }
  final daily = repeat == 'daily';
  final id = DateTime.now().millisecondsSinceEpoch.toString();

  final store = AgentStore();
  await store.load();
  final saved = await store.addReminder({
    'id': id,
    'time': hhmm(when),
    'text': text,
    'repeat': repeat,
    'kind': kind,
    'at': when.millisecondsSinceEpoch,
    if (args['advance_text'] != null && '${args['advance_text']}'.trim().isNotEmpty)
      'advance_text': '${args['advance_text']}'.trim(),
  });
  // Record to the room is the source of truth. If it didn't land, say so —
  // never ack a reminder we failed to save (the "acks but no record" bug).
  if (!saved) {
    return (false, 'ตั้งเตือนยังไม่สำเร็จ (บันทึกลงห้องไม่ได้ตอนนี้) ลองอีกครั้งนะ');
  }

  // Only plain reminders get an OS notification. Agentic jobs have no alert —
  // ปิ่น runs the task on next app open/resume (see _runDueJobs) and posts the
  // result; a bare notification with the raw prompt text would just confuse.
  // OS notification is best-effort — a phone permission/timezone hiccup must not
  // fail the whole thing: the reminder is already recorded and re-armed on open.
  final nid = kind == 'agentic' ? null : int.tryParse(id);
  if (nid != null) {
    try {
      await NotificationService.instance.scheduleReminder(
        id: nid,
        body: text,
        when: when,
        daily: daily,
      );
    } catch (_) {/* recorded already; the OS alarm re-arms on next app open */}
  }

  // Agentic jobs need to run when the app is closed. iOS: server APNs wake (via
  // the declarative reconcile below, no-op without a push token). Android: an
  // exact on-device alarm. Both fall back to the on-open runner.
  if (kind == 'agentic') {
    final rid = await _room();
    if (rid != null) {
      await syncWakeSchedule(rid); // reconcile full wake set from room state
      await AndroidJobAlarm.armAll(rid);
    }
  }

  final lead = kind == 'agentic' ? 'ตั้งงานอัตโนมัติ' : 'ตั้งเตือน';
  return (true, "$lead '$text' ${_whenLabel(when, daily)} แล้ว");
}

/// Resolve the ปิ่น DM room id; null when there's no room yet.
Future<String?> _room() => MatrixService.instance.pinRoomId();

/// The instruction a watch's daily agentic job runs. It must look, compare with
/// memory, update the watch, and stay SILENT unless there's something new —
/// pinging the chat only when it's actually worth the user's attention. (The
/// job runner drops an empty reply, so "no message" = no interruption.)
String _watchPrompt(String id, String topic) =>
    'นี่คืองานเฝ้าติดตามหัวข้อ "$topic" (watch id: $id). ทำตามนี้ตามลำดับ:\n'
    '1) เรียก web_search ด้วย query="$topic ล่าสุด" เพื่อหาข่าว/ข้อมูลล่าสุดของหัวข้อนี้ '
    '(query ต้องมีคำว่า "$topic" เสมอ ห้ามค้นกว้าง ๆ).\n'
    '2) เรียก recall_knowledge ด้วยคำค้น "watch $topic" เพื่อดูว่ารอบก่อนรู้อะไรไปแล้ว.\n'
    '3) ถ้าเจอเรื่องใหม่ (ไม่ซ้ำกับที่จำไว้ — รอบแรกถือว่าใหม่ทั้งหมด): '
    'เรียก update_watch(id:"$id", finding:"สรุปสั้น ๆ", urgency:..., source:"URL ที่มา") + save_knowledge หัวข้อ "watch $topic" '
    'เก็บสิ่งที่เจอกันซ้ำรอบหน้า. '
    'finding = ตัวข่าว/เนื้อหาล้วน 1-2 ประโยค — **ห้ามขึ้นต้นด้วยชื่อหัวข้อหรือ "พบ...ล่าสุด"** '
    '(การ์ดมีชื่อหัวข้อ "$topic" อยู่แล้ว) เช่นเขียน "Meituan เปิดตัว LongCat-2.0..." ไม่ใช่ "พบข่าว AI ล่าสุด: ...". '
    'source = URL ของแหล่งข่าวหลักจากผล web_search (ถ้ามี) เพื่อทำปุ่ม "อ่านต่อ". '
    'urgency: **"ใหม่" ไม่เท่ากับ "ด่วน"** — โดยดีฟอลต์ใช้ "digest" เสมอ. '
    'ใช้ "now" เฉพาะเมื่อผู้ใช้ต้อง**รู้เดี๋ยวนี้จริง ๆ**: ผลลัพธ์ที่กำลังรออยู่ (ผลบอล/ผลประกาศ), '
    'เดดไลน์/เวลาใกล้หมด, เหตุฉุกเฉิน, หรือราคาแตะเป้าที่ตั้งไว้. '
    'ข่าวคืบหน้า/อัปเดตทั่วไป (เช่น "บริษัทเปิดตัวสินค้า") = "digest" เสมอ แม้เพิ่งออก.\n'
    '4) **ห้ามพิมพ์ข้อความตอบผู้ใช้** — การ์ดสรุปจัดการการแจ้งให้แล้ว. '
    'แค่เรียกเครื่องมือแล้วจบงานเงียบ ๆ.\n'
    '5) ถ้า "ไม่มีอะไรใหม่เลยจริง ๆ" — ไม่ต้องเรียกอะไร จบงานเงียบ.';

/// Normalise the model's `interval` arg to a known tier, defaulting to daily.
/// Tier→seconds map lives in wake_sync ([watchTierSec]) — shared with the server
/// wake reconcile so both agree on cadence.
String _watchTier(String raw) =>
    watchTierSec.containsKey(raw.trim()) ? raw.trim() : 'daily';

/// A confirmation card for things that land in the "ตอนนี้" drawer. Its footer
/// is tappable → `open:now`, which the chat scaffold turns into openDrawer().
Map<String, dynamic> _nowCard(String detail) => {
      'header': {'icon': 'tasks', 'title': 'เพิ่มใน “ตอนนี้” แล้ว'},
      'body': [
        {'type': 'text', 'text': detail}
      ],
      'footer': {
        'icon': 'clock',
        'text': 'ดูใน “ตอนนี้”',
        'action': {'data': 'open:now'},
      },
    };

/// Wrap a (ok, message) producer: success → a tappable "ตอนนี้" card; failure →
/// feedback text so ปิ่น retries instead of confirming.
AgentTool _nowTool(
  Map<String, dynamic> decl,
  Future<(bool, String)> Function(Map<String, dynamic>) run,
) =>
    AgentTool(decl, (args) async {
      final (ok, msg) = await run(args);
      return ok
          ? ToolResult.terminal(AgentReply(flex: _nowCard(msg)))
          : ToolResult.feedback(msg);
    });

List<AgentTool> nowTools() => [
      // 1. one-shot / daily reminder ----------------------------------------
      _nowTool(
        fnDecl(
          'schedule_reminder',
          'ตั้งการเตือนให้ผู้ใช้ตามเวลาที่กำหนด (เตือนผ่านแจ้งเตือนของเครื่อง). '
          'ใช้เมื่อผู้ใช้ขอให้เตือน/นัดเวลา',
          properties: {
            'text': {
              'type': 'string', 
              'description': 'ข้อความที่จะเตือนตอน 5 นาทีก่อนถึงเวลาเป๊ะๆ (ถ้าเป็นนัดที่มี advance_text ข้อความนี้ควรเขียนเป็นแนว Check-in ถามไถ่ เช่น "อีก 5 นาทีจะเริ่มประชุมแล้ว พร้อมหรือยังคะ")'
            },
            'time': {
              'type': 'string',
              'description': 'เวลา: "HH:MM", "+30m"/"+2h" หรือ ISO-8601',
            },
            'repeat': {
              'type': 'string',
              'description': '"once" (ครั้งเดียว) หรือ "daily" (ทุกวัน)',
            },
            'advance_text': {
              'type': 'string',
              'description': 'ข้อความสำหรับตั้งเตือนล่วงหน้า 1 ชั่วโมง (ถ้ามี) เช่น "อีก 1 ชม. มีประชุมนะ"',
            },
          },
          required: ['text'],
        ),
        (args) => _scheduleEntry(args, kind: 'reminder'),
      ),

      // 2. agentic scheduled job --------------------------------------------
      _nowTool(
        fnDecl(
          'schedule_job',
          'ตั้งงานอัตโนมัติให้ปิ่นทำเองตามเวลาที่กำหนด (เช่น สรุปข่าวทุกเช้า). '
          'ใช้เมื่อผู้ใช้อยากให้ปิ่นทำงานบางอย่างให้เป็นประจำ/ตามเวลา',
          properties: {
            'text': {
              'type': 'string',
              'description': 'สิ่งที่ให้ปิ่นทำเมื่อถึงเวลา',
            },
            'time': {
              'type': 'string',
              'description': 'เวลา: "HH:MM", "+30m"/"+2h" หรือ ISO-8601',
            },
            'repeat': {
              'type': 'string',
              'description': '"once" หรือ "daily"',
            },
          },
          required: ['text'],
        ),
        (args) => _scheduleEntry(args, kind: 'agentic'),
      ), // schedule_job

      // 3. remove a reminder/job --------------------------------------------
      feedbackTool(
        fnDecl(
          'remove_reminder',
          'ลบการเตือนหรืองานอัตโนมัติที่ตั้งไว้ ด้วย id ของรายการนั้น',
          properties: {
            'id': {'type': 'string', 'description': 'id ของรายการที่จะลบ'},
          },
          required: ['id'],
        ),
        (args) async {
          final id = '${args['id'] ?? ''}'.trim();
          if (id.isEmpty) return 'ขอ id ของรายการที่จะลบด้วยนะ';
          final store = AgentStore();
          await store.load();
          await store.removeReminder(id);
          final nid = int.tryParse(id);
          if (nid != null) await NotificationService.instance.cancel(nid);
          await devProxy().scheduleCancel(id); // drop any server wake (no-op if none)
          await AndroidJobAlarm.cancel(id); // drop any on-device alarm (Android)
          return 'ลบรายการ id $id แล้ว';
        },
      ),

      // 4. add a task -------------------------------------------------------
      _nowTool(
        fnDecl(
          'add_task',
          'เพิ่มสิ่งที่ต้องทำ (to-do) เข้ารายการงานของผู้ใช้. '
          'ใช้เมื่อมีงานค้าง/สิ่งที่ต้องติดตาม',
          properties: {
            'text': {'type': 'string', 'description': 'ชื่องาน/สิ่งที่ต้องทำ'},
            'group': {
              'type': 'string',
              'description': 'หมวด เช่น "รอคุณ", "รอเขา", "เดดไลน์", "เงินค้าง"',
            },
            'due': {'type': 'string', 'description': 'กำหนดส่ง/วันครบ (ถ้ามี)'},
            'today': {'type': 'boolean', 'description': 'เป็นงานของวันนี้ไหม'},
            'overdue': {'type': 'boolean', 'description': 'เลยกำหนดแล้วไหม'},
            'sub': {'type': 'string', 'description': 'รายละเอียดย่อย (ถ้ามี)'},
          },
          required: ['text'],
        ),
        (args) async {
          final text = '${args['text'] ?? ''}'.trim();
          if (text.isEmpty) return (false, 'ขอชื่องานด้วยนะ');
          final rid = await _room();
          if (rid == null) return (false, 'ยังไม่พร้อม');
          final list =
              await MatrixService.instance.loadListFromRoom(rid, 'io.tokens2.tasks');
          list.add({
            'group': '${args['group'] ?? 'รอคุณ'}',
            'text': text,
            'sub': '${args['sub'] ?? ''}',
            'due': '${args['due'] ?? ''}',
            'today': args['today'] == true,
            'overdue': args['overdue'] == true,
          });
          final ok = await MatrixService.instance
              .saveListToRoom(rid, 'io.tokens2.tasks', list);
          TasksController.instance.updateFromJson(jsonEncode(list));
          return ok
              ? (true, "เพิ่มงาน '$text' แล้ว")
              : (false, 'ยังบันทึกงานไม่สำเร็จ ลองอีกครั้งนะ');
        },
      ),

      // 5. update an existing task ------------------------------------------
      _nowTool(
        fnDecl(
          'update_task',
          'แก้ไขงานที่มีอยู่ (ค้นจากชื่องาน) เช่น ย้ายหมวด/ใส่กำหนดส่ง/ทำเครื่องหมายเลยกำหนด',
          properties: {
            'text': {
              'type': 'string',
              'description': 'ชื่องานที่จะแก้ (ใช้จับคู่กับงานเดิม)',
            },
            'group': {'type': 'string', 'description': 'หมวดใหม่ (ถ้าจะเปลี่ยน)'},
            'due': {'type': 'string', 'description': 'กำหนดส่งใหม่ (ถ้าจะเปลี่ยน)'},
            'today': {'type': 'boolean', 'description': 'ตั้งเป็นงานวันนี้ไหม'},
            'overdue': {'type': 'boolean', 'description': 'ทำเครื่องหมายเลยกำหนดไหม'},
          },
          required: ['text'],
        ),
        (args) async {
          final text = '${args['text'] ?? ''}'.trim();
          if (text.isEmpty) return (false, 'ขอชื่องานที่จะแก้ด้วยนะ');
          final rid = await _room();
          if (rid == null) return (false, 'ยังไม่พร้อม');
          final list =
              await MatrixService.instance.loadListFromRoom(rid, 'io.tokens2.tasks');
          final idx = list.indexWhere((t) => '${t['text']}' == text);
          final Map<String, dynamic> task = idx >= 0
              ? list[idx]
              : {'group': 'รอคุณ', 'text': text};
          if (args.containsKey('group')) task['group'] = '${args['group']}';
          if (args.containsKey('due')) task['due'] = '${args['due']}';
          if (args.containsKey('today')) task['today'] = args['today'] == true;
          if (args.containsKey('overdue')) {
            task['overdue'] = args['overdue'] == true;
          }
          if (idx < 0) list.add(task);
          final ok = await MatrixService.instance
              .saveListToRoom(rid, 'io.tokens2.tasks', list);
          TasksController.instance.updateFromJson(jsonEncode(list));
          return ok
              ? (true, idx >= 0 ? "แก้งาน '$text' แล้ว" : "เพิ่มงาน '$text' แล้ว")
              : (false, 'ยังบันทึกไม่สำเร็จ ลองอีกครั้งนะ');
        },
      ),

      // 6. remember a fact --------------------------------------------------
      feedbackTool(
        fnDecl(
          'remember_fact',
          'จดจำข้อเท็จจริงสั้น ๆ เกี่ยวกับผู้ใช้ไว้ใช้ภายหลัง. '
          'ใช้เมื่อผู้ใช้บอกให้จำ/"จำไว้นะ"',
          properties: {
            'text': {'type': 'string', 'description': 'สิ่งที่จะจำ'},
          },
          required: ['text'],
        ),
        (args) async {
          final text = '${args['text'] ?? ''}'.trim();
          if (text.isEmpty) return 'ขอสิ่งที่จะให้จำด้วยนะ';
          final rid = await _room();
          if (rid == null) return 'ยังไม่พร้อม';
          final store = AgentStore();
          await store.load();
          final ok = await store.addFact(rid, text);
          return ok
              ? 'จำไว้แล้ว: $text'
              : 'ยังจำไม่สำเร็จ (บันทึกลงห้องไม่ได้) ลองอีกครั้งนะ';
        },
      ),

      // 7. save a longer piece of knowledge ---------------------------------
      feedbackTool(
        fnDecl(
          'save_knowledge',
          'บันทึกความรู้/ข้อมูลที่ยาวกว่าข้อเท็จจริงสั้น ๆ (มีหัวข้อ+เนื้อหา) '
          'เพื่อให้ค้นกลับมาได้ภายหลัง',
          properties: {
            'title': {'type': 'string', 'description': 'หัวข้อ'},
            'summary': {'type': 'string', 'description': 'สรุปสั้น ๆ'},
            'content': {'type': 'string', 'description': 'เนื้อหาเต็ม'},
          },
          required: ['title'],
        ),
        (args) async {
          final title = '${args['title'] ?? ''}'.trim();
          if (title.isEmpty) return 'ขอหัวข้อด้วยนะ';
          final rid = await _room();
          if (rid == null) return 'ยังไม่พร้อม';
          final store = AgentStore();
          await store.load();
          final ok = await store.addKnowledge(
            rid,
            KnowledgeItem(
              title,
              '${args['summary'] ?? ''}',
              '${args['content'] ?? ''}',
            ),
          );
          return ok
              ? "บันทึกความรู้ '$title' แล้ว"
              : 'ยังบันทึกไม่สำเร็จ ลองอีกครั้งนะ';
        },
      ),

      // 8. recall stored knowledge ------------------------------------------
      feedbackTool(
        fnDecl(
          'recall_knowledge',
          'ค้นความรู้ที่ปิ่นบันทึกไว้ก่อนหน้านี้ ด้วยคำค้น',
          properties: {
            'query': {'type': 'string', 'description': 'คำค้น'},
          },
          required: ['query'],
        ),
        (args) async {
          final query = '${args['query'] ?? ''}'.trim();
          if (query.isEmpty) return 'ขอคำค้นด้วยนะ';
          final rid = await _room();
          if (rid == null) return 'ยังไม่พร้อม';
          final store = AgentStore();
          await store.load();
          // On-device semantic recall: the store embeds the query + items via the
          // bundled model, falling back to recency when no model is provisioned.
          final hits = await store.searchKnowledge(rid, query, 5);
          if (hits.isEmpty) return 'ยังไม่มีข้อมูลที่บันทึกไว้';
          final lines = [
            for (final k in hits)
              '• ${k.title}'
                  '${k.summary.isNotEmpty ? ' — ${k.summary}' : ''}'
                  '${k.summary.isEmpty && k.content.isNotEmpty ? ' — ${k.content}' : ''}',
          ];
          return 'ความรู้ที่บันทึกไว้:\n${lines.join('\n')}';
        },
      ),

      // 9. request a capability ปิ่น can't do yet --------------------------
      feedbackTool(
        fnDecl(
          'request_capability',
          'ใช้เมื่อผู้ใช้ขอให้ปิ่นทำสิ่งที่ "ยังไม่มีเครื่องมือรองรับ" (เช่น เข้าถึง Gmail/'
          'อีเมล, เชื่อมปฏิทินภายนอก, ควบคุมแอปอื่น). บันทึกคำขอไว้ให้ทีมพัฒนาเพิ่ม '
          'ความสามารถ แล้วบอกผู้ใช้ว่าระบบจะเพิ่มให้เร็ว ๆ นี้. ห้ามแกล้งทำว่าทำได้',
          properties: {
            'capability': {
              'type': 'string',
              'description': 'ความสามารถที่ผู้ใช้ต้องการ สั้น ๆ เช่น "เข้าถึง Gmail"',
            },
            'detail': {
              'type': 'string',
              'description': 'รายละเอียดสิ่งที่ผู้ใช้อยากให้ทำ (ถ้ามี)',
            },
          },
          required: ['capability'],
        ),
        (args) async {
          final cap = '${args['capability'] ?? ''}'.trim();
          if (cap.isEmpty) return 'ขอชื่อความสามารถที่ต้องการด้วยนะ';
          final rid = await _room();
          if (rid == null) return 'ยังไม่พร้อม';
          final list = await MatrixService.instance
              .loadListFromRoom(rid, 'io.tokens2.capability_requests');
          // Skip duplicates (same capability already queued) — bump its count.
          final i = list.indexWhere(
              (e) => '${e['capability']}'.toLowerCase() == cap.toLowerCase());
          if (i >= 0) {
            list[i]['count'] = ((list[i]['count'] as num?)?.toInt() ?? 1) + 1;
            list[i]['at'] = DateTime.now().millisecondsSinceEpoch;
          } else {
            list.add({
              'capability': cap,
              'detail': '${args['detail'] ?? ''}',
              'status': 'requested',
              'count': 1,
              'at': DateTime.now().millisecondsSinceEpoch,
            });
          }
          final ok = await MatrixService.instance
              .saveListToRoom(rid, 'io.tokens2.capability_requests', list);
          // Also report to the server backlog (admin page). Best-effort.
          await devProxy().requestCapability(cap, '${args['detail'] ?? ''}');
          return ok
              ? 'บันทึกคำขอ "$cap" ไว้แล้ว — บอกผู้ใช้ว่าตอนนี้ยังทำไม่ได้ '
                  'แต่บันทึกคำขอไว้ให้ทีมพัฒนาแล้ว'
              : 'ยังบันทึกคำขอไม่สำเร็จ ลองอีกครั้งนะ';
        },
      ),

      // 10. add a watch — keep an eye on a topic, ping only on something new ---
      _nowTool(
        fnDecl(
          'add_watch',
          'ให้ปิ่นคอยเฝ้าติดตามหัวข้อที่ผู้ใช้สนใจ (เช่น ราคา, ข่าว, หุ้น) แล้วบอกเมื่อมีอะไรใหม่. '
          'กฎเหล็ก (ต้องทำตามอย่างเคร่งครัด!):\n'
          '1. ถ้าผู้ใช้พิมพ์ว่า "ตาม..." หรือ "เฝ้า..." (เช่น "ตามราคาน้ำมัน", "เฝ้าหุ้น") → บังคับให้เรียก add_watch ทันทีแบบไม่มีเงื่อนไข! ห้ามตอบเป็นข้อความเฉยๆ หรือรับปากเปล่าๆ เด็ดขาด!\n'
          '2. ถึงแม้หัวข้อจะดูกว้างมาก (เช่น "ราคาทอง", "น้ำมัน", "ข่าว") ก็ห้ามอิดออด ห้ามปฏิเสธ ห้ามถามให้แคบลง ให้สร้าง Watcher ทันที!\n'
          '3. ถ้าสั่งหลายเรื่องในประโยคเดียว → เรียก add_watch ซ้ำๆ จนครบทุกเรื่อง',
          properties: {
            'topic': {
              'type': 'string',
              'description': 'เรื่องที่จะเฝ้า เช่น "ข่าว AI", "ราคา BTC"',
            },
            'interval': {
              'type': 'string',
              'enum': ['realtime', 'hourly', 'daily', 'weekly', 'idle'],
              'description': 'ความถี่ในการเช็ค — เลือกจากธรรมชาติของหัวข้อ+คำผู้ใช้: '
                  'realtime(~2ชม.)=ตัวเลขสด ราคาเหรียญ/หุ้น ผลสด ภัยพิบัติกำลังเกิด; '
                  'hourly(~6ชม.)=ข่าวด่วนร้อน ดราม่ากำลังพีค ของลดเวลาจำกัด; '
                  'daily(1วัน)=ข่าวทั่วไป ความเคลื่อนไหววงการ (ดีฟอลต์ถ้าไม่แน่ใจ); '
                  'weekly(7วัน)=เทรนด์ ของใหม่ยี่ห้อ สถานะนาน ๆ ขยับ; '
                  'idle(30วัน)="ไว้มีอะไรค่อยบอก" เรื่องแทบไม่ขยับ. '
                  'คำบอกใบ้เวลาในประโยคผู้ใช้สำคัญสุด (เช่น "ด่วน"→hourly, "ไม่ต้องรีบ"→weekly)',
            },
            'time': {
              'type': 'string',
              'description': 'ระบุเฉพาะเมื่อผู้ใช้อยากได้เวลาตายตัวต่อวัน "HH:MM" '
                  '(เช่น "ทุก 8 โมง") — ถ้าใส่จะทับ interval เป็นเช็ควันละครั้งเวลานี้',
            },
            'icon': {
              'type': 'string',
              'enum': ['news', 'money', 'chart', 'sun', 'calendar', 'heart', 'sparkles'],
              'description': 'ไอคอนหมวดของเรื่องที่เฝ้า (ใช้บนการ์ดสรุป) — '
                  'money/chart=การเงิน/ราคา, calendar=นัด/อีเวนต์, heart=สุขภาพ, '
                  'news=ข่าวทั่วไป (ดีฟอลต์)',
            },
          },
          required: ['topic'],
        ),
        (args) async {
          final topic = '${args['topic'] ?? ''}'.trim();
          if (topic.isEmpty) return (false, 'ขอหัวข้อที่จะเฝ้าด้วยนะ');
          final rid = await _room();
          if (rid == null) return (false, 'ยังไม่พร้อม');
          final list = await MatrixService.instance
              .loadListFromRoom(rid, 'io.tokens2.watches');
          if (list.any(
              (w) => '${w['topic']}'.toLowerCase() == topic.toLowerCase())) {
            return (false, 'เฝ้าเรื่อง "$topic" อยู่แล้วนะ');
          }
          // A fixed daily "HH:MM" wins if the user asked for one; otherwise the
          // LLM-judged interval tier sets the cadence (adaptive watch).
          final timeArg = '${args['time'] ?? ''}'.trim();
          final tier = _watchTier('${args['interval'] ?? ''}');
          final fixedDaily = timeArg.isNotEmpty;
          final id = DateTime.now().millisecondsSinceEpoch.toString();
          list.add({
            'id': id,
            'topic': topic,
            'last_seen': '',
            'last_seen_at': 0,
            'has_new': false,
            'pending_digest': false,
            'icon': '${args['icon'] ?? 'news'}',
            'interval': fixedDaily ? 'daily' : tier,
            if (fixedDaily) 'time': timeArg, // kept so re-sync knows the hour
            'created': DateTime.now().millisecondsSinceEpoch,
          });
          final ok = await MatrixService.instance
              .saveListToRoom(rid, 'io.tokens2.watches', list);
          if (!ok) return (false, 'ยังบันทึกไม่สำเร็จ ลองอีกครั้งนะ');
          WatchesController.instance.updateFromJson(jsonEncode(list));

          // The checker = an agentic job (id == watch id) whose prompt tells ปิ่น
          // to look, compare with memory, and speak only on something new.
          final store = AgentStore();
          await store.load();
          if (fixedDaily) {
            final when = parseWhen(timeArg) ?? parseWhen('09:00')!;
            await store.addReminder({
              'id': id,
              'time': hhmm(when),
              'text': _watchPrompt(id, topic),
              'repeat': 'daily',
              'kind': 'agentic',
              'at': when.millisecondsSinceEpoch,
            });
          } else {
            final intervalSec = watchTierSec[tier]!;
            final now = DateTime.now().millisecondsSinceEpoch;
            await store.addReminder({
              'id': id,
              'text': _watchPrompt(id, topic),
              'repeat': 'interval',
              'kind': 'agentic',
              'interval_sec': intervalSec,
              'floor_sec': intervalSec, // tier base; backoff caps at 8× this
              'at': now, // first check ~now; settles to the interval after
            });
          }
          // Make sure the daily briefing job exists (findings batch into it).
          await ensureDigestJob(rid);
          // Reconcile the whole server wake schedule from room state (declarative)
          // — this new watch plus any that missed registration earlier. Idempotent.
          await syncWakeSchedule(rid);
          await AndroidJobAlarm.armAll(rid);
          return (true,
              "จะคอยเฝ้าเรื่อง '$topic' ให้ — สรุปให้ทุกเช้า (เปลี่ยนเวลาได้ในตั้งค่า) ถ้ามีเรื่องด่วนจะบอกทันที");
        },
      ),

      // 11. update a watch — called BY the checker job when it finds something --
      feedbackTool(
        fnDecl(
          'update_watch',
          'บันทึกผลการเฝ้าติดตามล่าสุด (เรียกจากงานเฝ้าเมื่อเจอเรื่องใหม่). '
          'เรื่องปกติรวมไปแจ้งในสรุปประจำวัน — "ใหม่" ไม่เท่ากับ "ด่วน", '
          'ตั้ง urgency="now" เฉพาะเรื่องที่ผู้ใช้ต้องรู้เดี๋ยวนี้จริง ๆ '
          '(ผลลัพธ์ที่กำลังรอ/เดดไลน์/ฉุกเฉิน/ราคาแตะเป้า) เท่านั้น',
          properties: {
            'id': {'type': 'string', 'description': 'id ของ watch'},
            'finding': {
              'type': 'string',
              'description': 'สรุปสั้น ๆ สิ่งที่เจอล่าสุด',
            },
            'urgency': {
              'type': 'string',
              'enum': ['now', 'digest'],
              'description':
                  'digest = รวมในสรุปประจำวัน (ค่าเริ่มต้น, ใช้กับข่าว/อัปเดตทั่วไปแม้เพิ่งออก) · '
                  'now = แจ้งทันที เฉพาะเรื่องที่ต้องรู้เดี๋ยวนี้จริง ๆ',
            },
            'source': {
              'type': 'string',
              'description':
                  'URL แหล่งข่าว/ที่มาของ finding (จากผล web_search) เพื่อทำปุ่ม "อ่านต่อ" — ใส่ถ้ามี',
            },
          },
          required: ['id', 'finding'],
        ),
        (args) async {
          final id = '${args['id'] ?? ''}'.trim();
          final finding = '${args['finding'] ?? ''}'.trim();
          if (id.isEmpty || finding.isEmpty) return 'ขอ id กับ finding ด้วยนะ';
          final urgent = '${args['urgency'] ?? 'digest'}' == 'now';
          final source = '${args['source'] ?? ''}'.trim();
          final rid = await _room();
          if (rid == null) return 'ยังไม่พร้อม';
          final list = await MatrixService.instance
              .loadListFromRoom(rid, 'io.tokens2.watches');
          final i = list.indexWhere((w) => '${w['id']}' == id);
          if (i < 0) return 'ไม่พบ watch id $id';
          list[i]['last_seen'] = finding;
          list[i]['last_seen_at'] = DateTime.now().millisecondsSinceEpoch;
          list[i]['has_new'] = true;
          list[i]['source'] = source; // '' clears a stale link
          // Urgent findings ปิ่น posts right away → not pending for the digest.
          // Everything else waits for the daily briefing (no rapid pings).
          list[i]['pending_digest'] = !urgent;
          final ok = await MatrixService.instance
              .saveListToRoom(rid, 'io.tokens2.watches', list);
          WatchesController.instance.updateFromJson(jsonEncode(list));
          if (urgent) {
            final card = buildNowCard({
              'icon': list[i]['icon'],
              'topic': list[i]['topic'],
              'finding': finding,
              'source': source,
            }, name: PrefsController.instance.value.pinName);
            await MatrixService.instance.sendText(rid, finding,
                role: 'user', flex: card, meta: pinMeta(const ['watch']));
            await NotificationService.instance
                .showNow(rid, '${list[i]['topic']}: $finding');
          }
          return ok ? 'อัปเดต watch แล้ว' : 'อัปเดตไม่สำเร็จ';
        },
      ),

      // 12. remove a watch ---------------------------------------------------
      feedbackTool(
        fnDecl(
          'remove_watch',
          'เลิกเฝ้าติดตามหัวข้อ ด้วย id หรือชื่อหัวข้อ',
          properties: {
            'id': {'type': 'string', 'description': 'id หรือชื่อหัวข้อที่จะเลิกเฝ้า'},
          },
          required: ['id'],
        ),
        (args) async {
          final key = '${args['id'] ?? ''}'.trim();
          if (key.isEmpty) return 'ขอ id หรือชื่อเรื่องที่จะเลิกเฝ้าด้วยนะ';
          final rid = await _room();
          if (rid == null) return 'ยังไม่พร้อม';
          final list = await MatrixService.instance
              .loadListFromRoom(rid, 'io.tokens2.watches');
          final i = list.indexWhere((w) =>
              '${w['id']}' == key ||
              '${w['topic']}'.toLowerCase() == key.toLowerCase());
          if (i < 0) return 'ไม่พบเรื่องที่เฝ้าชื่อ/id "$key"';
          final wid = '${list[i]['id']}';
          final topic = '${list[i]['topic']}';
          list.removeAt(i);
          await MatrixService.instance
              .saveListToRoom(rid, 'io.tokens2.watches', list);
          WatchesController.instance.updateFromJson(jsonEncode(list));
          // Cancel the checker job that shares the watch id.
          final store = AgentStore();
          await store.load();
          await store.removeReminder(wid);
          // Reconcile from room state — the removed watch is no longer in the set,
          // so the server drops its wake. Heals drift in the same pass.
          await syncWakeSchedule(rid);
          await AndroidJobAlarm.cancel(wid);
          return 'เลิกเฝ้าเรื่อง "$topic" แล้ว';
        },
      ),
    ];
