import 'dart:convert';

import '../services/android_job_alarm.dart';
import '../services/matrix_service.dart';
import '../services/notification_service.dart';
import '../services/push_service.dart';
import '../services/tasks_controller.dart';
import 'agent_config.dart';
import 'agent_reply.dart';
import 'agent_store.dart';
import 'tools.dart';

/// On-device "ตอนนี้" tools: let ปิ่น create reminders / jobs / tasks / memory.
/// The data lives in the ปิ่น DM room state (the single source of truth) — the
/// server bot that used to write it is gone, so the model must call these.
///
/// Each tool builds a fresh [AgentStore] and `load()`s it: that overlays the
/// room copy on top of the local cache (the same pattern now_screen/abilities
/// use). The store's write methods (addReminder/addFact/addKnowledge) mirror
/// straight back to Matrix room state, so there's no shared instance to thread
/// through the session — the room is the source of truth.

/// HH:MM (24h) for a daily reminder's "time" field.
String _hhmm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// Parse the model-supplied `time` into a fire `DateTime`.
/// Accepts "+30m"/"+2h" (relative), "HH:MM" (today, or tomorrow if past), or
/// a full ISO-8601 timestamp. Returns null when it can't be understood.
DateTime? _parseWhen(String raw) {
  final t = raw.trim();
  // Relative: +30m / +2h / +90 (minutes).
  final rel = RegExp(r'^\+?\s*(\d+)\s*([mhd]?)$', caseSensitive: false)
      .firstMatch(t);
  if (rel != null) {
    final n = int.parse(rel.group(1)!);
    final unit = (rel.group(2) ?? 'm').toLowerCase();
    final dur = switch (unit) {
      'h' => Duration(hours: n),
      'd' => Duration(days: n),
      _ => Duration(minutes: n),
    };
    return DateTime.now().add(dur);
  }
  // HH:MM today (roll to tomorrow if already past).
  final hm = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(t);
  if (hm != null) {
    final h = int.parse(hm.group(1)!);
    final m = int.parse(hm.group(2)!);
    final now = DateTime.now();
    var when = DateTime(now.year, now.month, now.day, h, m);
    if (!when.isAfter(now)) when = when.add(const Duration(days: 1));
    return when;
  }
  // Full ISO timestamp.
  return DateTime.tryParse(t);
}

/// Short Thai phrasing of when the reminder fires, for the feedback line.
String _whenLabel(DateTime when, bool daily) {
  if (daily) return 'ทุกวันเวลา ${_hhmm(when)} น.';
  final now = DateTime.now();
  final sameDay =
      when.year == now.year && when.month == now.month && when.day == now.day;
  if (sameDay) return 'วันนี้ ${_hhmm(when)} น.';
  return '${when.year}-${when.month.toString().padLeft(2, '0')}-'
      '${when.day.toString().padLeft(2, '0')} ${_hhmm(when)} น.';
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
  final when = rawTime.isEmpty ? null : _parseWhen(rawTime);
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
    'time': _hhmm(when),
    'text': text,
    'repeat': repeat,
    'kind': kind,
    'at': when.millisecondsSinceEpoch,
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

  // Agentic jobs need to run when the app is closed. iOS: register a server APNs
  // wake (no-op without a push token). Android: arm an exact on-device alarm.
  // Both no-op on the other platform; both fall back to the on-open runner.
  if (kind == 'agentic') {
    await devProxy().scheduleRegister(
      jobId: id,
      nextDue: when.millisecondsSinceEpoch / 1000,
      repeat: repeat,
      device: PushService.instance.deviceToken,
    );
    final rid = await _room();
    if (rid != null) await AndroidJobAlarm.armAll(rid);
  }

  final lead = kind == 'agentic' ? 'ตั้งงานอัตโนมัติ' : 'ตั้งเตือน';
  return (true, "$lead '$text' ${_whenLabel(when, daily)} แล้ว");
}

/// Resolve the ปิ่น DM room id; null when there's no room yet.
Future<String?> _room() => MatrixService.instance.pinRoomId();

/// A confirmation card for things that land in the "ตอนนี้" drawer. Its footer
/// is tappable → `open:now`, which the chat scaffold turns into openDrawer().
Map<String, dynamic> _nowCard(String detail) => {
      'header': {'icon': 'tasks', 'title': 'เพิ่มใน “ตอนนี้” แล้ว'},
      'body': [
        {'type': 'text', 'text': detail}
      ],
      'footer': {
        'icon': 'clock',
        'text': 'แตะเพื่อดูใน “ตอนนี้”',
        'trailing': 'เปิด →',
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
            'text': {'type': 'string', 'description': 'ข้อความที่จะเตือน'},
            'time': {
              'type': 'string',
              'description': 'เวลา: "HH:MM", "+30m"/"+2h" หรือ ISO-8601',
            },
            'repeat': {
              'type': 'string',
              'description': '"once" (ครั้งเดียว) หรือ "daily" (ทุกวัน)',
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
    ];
