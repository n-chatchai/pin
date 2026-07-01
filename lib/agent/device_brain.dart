import 'dart:convert';

import 'agent_reply.dart';
import 'proxy_client.dart';
import 'token_cost.dart';
import 'tools.dart';

/// On-device agent loop. Owns orchestration; all state stays on the phone and
/// is passed in as `history`. Calls the blind LLM proxy and dispatches tool
/// calls to the on-device registry (later: remote minimal-arg tool APIs).
class DeviceBrain {
  final ProxyClient proxy;
  final ToolRegistry tools;
  final String system;
  final int maxSteps;

  const DeviceBrain({
    required this.proxy,
    required this.tools,
    required this.system,
    this.maxSteps = 6,
  });

  /// Run one user turn. `history` is OpenAI-shaped prior messages (kept on
  /// device). Returns the assistant's final text.
  Future<AgentReply> reply(
    List<Map<String, dynamic>> history,
    String userText, {
    String? imageB64, // jpeg base64 → multimodal (Gemini sees the image)
  }) async {
    final userMsg = imageB64 == null
        ? {'role': 'user', 'content': userText}
        : {
            'role': 'user',
            'content': [
              {
                'type': 'text',
                'text': userText.isEmpty ? 'ดูรูปนี้ให้หน่อยค่ะ' : userText
              },
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,$imageB64'}
              },
            ],
          };
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': system},
      // Strip UI-only extras (e.g. a persisted flex card) — the provider only
      // accepts role/content.
      for (final h in history) {'role': h['role'], 'content': h['content']},
      userMsg,
    ];

    final used = <String>[]; // tool names called this turn (for the UI hint)
    final trace = <String>[]; // debug-bot: every step of the agent loop
    var usage = const TokenUsage(); // tokens summed over every model call
    Map<String, dynamic>? pendingFlex; // a card shown; ปิ่น still adds a caption
    var nudgedCommit = false; // fired the "you promised but didn't create it" nudge once
    for (var step = 0; step < maxSteps; step++) {
      final resp = await proxy.infer(
        messages: messages,
        tools: tools.declarations(),
      );
      usage = usage + TokenUsage.fromResponse(resp);
      final choice =
          (resp['choices'] as List).first['message'] as Map<String, dynamic>;
      final calls = choice['tool_calls'] as List?;

      if (calls == null || calls.isEmpty) {
        final content = (choice['content'] as String?)?.trim() ?? '';
        // Salvage: the model sometimes PROMISES to draw and narrates a
        // {"prompt": "..."} blob instead of calling generate_image (esp. on an
        // indirect "วาดใหม่"). Detect the leaked JSON, run the tool for real,
        // and return its card with the surrounding sentence as the caption.
        if (pendingFlex == null && !used.contains('generate_image')) {
          final p = _leakedPrompt(content);
          if (p != null) {
            trace.add('🛟 กู้คืน: เรียก generate_image จาก prompt ที่หลุดมาเป็นข้อความ');
            used.add('generate_image');
            final res = await tools.dispatch('generate_image', {'prompt': p});
            if (res.reply?.flex != null) {
              return AgentReply(
                  text: _stripJson(content),
                  flex: res.reply!.flex,
                  usedTools: used,
                  trace: trace,
                  usage: usage);
            }
          }
        }
        // Commitment guard: ปิ่น "รับปาก" to remind/watch but never called the
        // tool → nudge it ONCE to actually create it (or ask for the missing
        // time). Lets the model opt out if it wasn't a real commitment, so a
        // stray "เตือน" in advice doesn't force an unwanted reminder.
        const commitTools = {'schedule_reminder', 'add_watch', 'schedule_job'};
        if (!nudgedCommit &&
            _promisesNotify(content) &&
            !used.any(commitTools.contains)) {
          nudgedCommit = true;
          trace.add('🛟 รับปากจะเตือน/เฝ้า แต่ยังไม่สร้าง — ย้ำให้ลงมือ');
          messages.add(choice); // the toolless reply, so the model sees what it said
          messages.add({
            'role': 'user',
            'content': 'ระบบ: ข้อความก่อนหน้าดูเหมือนรับปากว่าจะเตือน/เฝ้า/แจ้งให้. '
                'ถ้าตั้งใจจริงและข้อมูลครบ ให้เรียก schedule_reminder หรือ add_watch '
                'เดี๋ยวนี้; ถ้าขาดเวลา/รายละเอียด ให้ถามผู้ใช้สั้น ๆ; ถ้าเป็นแค่คำพูด '
                'ทั่วไปไม่ได้จะตั้งเตือนจริง ตอบตามเดิมได้เลย. ห้ามยืนยันว่าเตือน/เฝ้าแล้ว '
                'ถ้ายังไม่ได้สร้าง.',
          });
          continue;
        }
        trace.add(used.isEmpty
            ? '💬 ตอบข้อความ (ไม่เรียกเครื่องมือ)'
            : '💬 สรุปเป็นข้อความ');
        // Global JSON guard: the model sometimes narrates a tool call as a raw
        // {"summary":…} / {"reading":…} blob (or a ```fenced``` block) in its own
        // text instead of calling the tool. Strip it so the bubble never shows
        // raw JSON — covers every tool, not just generate_image.
        var shown = _stripJson(content);
        if (shown.isEmpty && pendingFlex == null) shown = content;
        // Caption (if any) + the card from the terminal tool.
        return AgentReply(
            text: shown,
            flex: pendingFlex,
            usedTools: used,
            trace: trace,
            usage: usage);
      }

      // Record the assistant turn (with tool_calls) then each tool result.
      messages.add(choice);
      var gotCard = false;
      for (final call in calls) {
        final fn = call['function'] as Map<String, dynamic>;
        final name = '${fn['name']}';
        if (!used.contains(name)) used.add(name);
        final args = _parseArgs(fn['arguments']);
        trace.add('→ เรียก $name(${_short(jsonEncode(args))})');
        final result = await tools.dispatch(name, args);
        if (result.reply != null) {
          final r = result.reply!;
          // A card → ปิ่น should ALSO say a line. Keep the card, tell the model
          // it was shown, and loop once more for a short caption.
          if (r.flex != null) {
            pendingFlex = r.flex;
            gotCard = true;
            trace.add('← $name: การ์ด ✓ (ให้ปิ่นทักสั้น ๆ)');
            messages.add({
              'role': 'tool',
              'tool_call_id': call['id'],
              'content': 'แสดงการ์ดให้ผู้ใช้แล้ว ตอบกลับสั้น ๆ 1–2 ประโยคที่ '
                  '"มีคุณค่า" — ชี้จุดที่น่าสนใจในการ์ด แล้วเพิ่มคำแนะนำหรือ '
                  'ข้อสังเกตที่ใช้ได้จริง (อากาศ→เตือนพกร่ม/แต่งตัวตามอุณหภูมิ, '
                  'ค่าเงิน→แนวโน้มน่าซื้อ/รอ, ข่าว→ไฮไลต์ที่ควรอ่าน, '
                  'ดูดวง→ข้อควรระวัง). ห้ามพูดลอย ๆ ว่า "ตามนี้เลยค่ะ" หรือ '
                  '"นี่คือข้อมูล" และห้ามเอ่ยชื่อฟังก์ชัน.',
            });
            break; // re-infer for the caption
          }
          // Non-card terminal (e.g. plain reply) → done.
          trace.add('← $name: ผลลัพธ์ ✓');
          return AgentReply(
              text: r.text,
              flex: r.flex,
              usedTools: used,
              trace: trace,
              usage: usage);
        }
        trace.add('← $name: ${_short(result.feedback ?? "done")}');
        messages.add({
          'role': 'tool',
          'tool_call_id': call['id'],
          'content': result.feedback ?? 'done',
        });
      }
      if (gotCard) continue; // back to the model for the caption
    }
    trace.add('⚠️ ครบ $maxSteps ขั้นแล้วยังไม่จบ');
    return AgentReply(
        text: 'ขอโทษค่ะ ตอนนี้ตอบไม่ได้ ลองใหม่อีกที',
        usedTools: used,
        trace: trace,
        usage: usage);
  }

  static String _short(String s) =>
      s.length > 80 ? '${s.substring(0, 80)}…' : s;

  /// Find a `"prompt": "…"` the model narrated instead of calling the tool.
  static String? _leakedPrompt(String text) {
    final m = RegExp(r'"prompt"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(text);
    if (m == null) return null;
    final raw = m.group(1)!;
    if (raw.trim().length < 3) return null;
    return raw.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
  }

  /// Drop any leaked JSON the model narrated instead of calling a tool — a
  /// ```fenced``` block or a standalone `{…}` object carrying a quoted key
  /// (e.g. the {"summary":…,"content":…} it prints in place of save_knowledge,
  /// or {"prompt":…} for generate_image). ปิ่น never shows raw JSON to the user,
  /// whatever tool leaked it. Leaves normal Thai prose untouched.
  static String _stripJson(String text) {
    var t = text.replaceAll(RegExp(r'```[\s\S]*?```'), ''); // whole fenced block
    // Flat JSON object with at least one "key": — string values may span lines
    // (dotAll). Two passes clear adjacent blobs.
    final obj = RegExp(r'\{[^{}]*"[^"]+"\s*:[^{}]*\}', dotAll: true);
    t = t.replaceAll(obj, '').replaceAll(obj, '');
    return t.replaceAll('```', '').trim();
  }

  static Map<String, dynamic> _parseArgs(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is String && raw.isNotEmpty) {
      try {
        return jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {}
    }
    return {};
  }

  // Detects a reply that commits to remind/watch/notify the user later, so the
  // loop can verify a matching tool actually fired (schedule_reminder/add_watch).
  static final RegExp _notifyRe = RegExp(
      r'เตือน|แจ้ง|คอยดู|เฝ้า|ไว้จะ|เดี๋ยว.{0,12}ให้|remind|notif|keep an eye',
      caseSensitive: false);
  static bool _promisesNotify(String s) => _notifyRe.hasMatch(s);
}
