import 'dart:convert';
import 'dart:io';

import '../services/prefs.dart';
import 'agent_reply.dart';
import 'agent_config.dart';
import 'catalog_client.dart';
import 'device_brain.dart';
import 'now_tools.dart';
import 'proxy_client.dart';
import 'abilities.dart';
import 'agent_store.dart';
import 'remote_tools.dart';
import 'subagent.dart';
import 'tools.dart';
import '../services/matrix_service.dart';

/// Drives the device brain for one room. Builds the system prompt (persona +
/// capabilities), exposes the stateless tools, and runs a turn. The transcript
/// is the encrypted DM room (source of truth) — held in memory here as model
/// context only; there is no on-device chat/memory copy.
class AgentSession {
  final String room;
  final ProxyClient proxy;

  /// Extra tools fetched from the proxy `/catalog` at runtime (incl. MCP).
  /// Empty until [loadCatalog] completes; merged into the registry per turn.
  List<AgentTool> _catalogTools = const [];
  Map<String, Map<String, dynamic>> _catalogSkills = const {}; // name->manifest
  List<SubagentSpec> _catalogSubagents = const [];
  DateTime? _catalogAt; // last successful/attempted catalog load
  int _catalogRev = -1; // capabilitiesRevision seen at the last catalog load
  Set<String> _optedOut = const {}; // capabilities the user turned off
  List<String> _facts = const []; // remembered facts, injected into the prompt

  /// Model-context transcript, held in memory only — the encrypted DM room is the
  /// source of truth. Seeded from the DM at boot ([seedTurns]) and appended each
  /// turn; never written to the local AgentStore (no on-device chat copy that can
  /// diverge across devices). Each entry is `{role, content}`.
  final List<Map<String, dynamic>> _turns = <Map<String, dynamic>>[];

  /// Replace the in-memory model transcript with the DM-derived turns (called
  /// after the chat screen paginates the room). Keeps the LLM's context in sync
  /// with the authoritative room without persisting a local copy.
  void seedTurns(List<Map<String, dynamic>> turns) {
    _turns
      ..clear()
      ..addAll(turns);
  }

  AgentSession({
    required this.room,
    required this.proxy,
  });

  Future<void> loadCatalog() async {
    final optedOut = <String>{};
    if (room.startsWith('!')) {
      // Best-effort: pre-login (or transient) reads throw "user not logged in" —
      // an unhandled async error if not caught. Fall back to no opt-outs.
      try {
        final rawList = await MatrixService.instance
            .loadListFromRoom(room, 'io.tokens2.opted_out_capabilities');
        optedOut.addAll(rawList.map((e) => '${e['name']}'));
      } catch (_) {/* not logged in yet / offline → assume none opted out */}
    }
    _optedOut = optedOut;
    // Remembered facts → injected into the system prompt so ปิ่น actually uses
    // what the user told it to remember (facts have no recall tool).
    if (room.startsWith('!')) {
      try {
        _facts = await AgentStore().loadFacts(room);
      } catch (_) {/* keep last */}
    }
    final r = await CatalogClient(proxy).fetch(optedOut: optedOut);
    // Only overwrite when we actually got something (or it's the first load) —
    // a transient network failure shouldn't wipe a good catalog.
    if (_catalogAt == null ||
        r.tools.isNotEmpty || r.skills.isNotEmpty || r.subagents.isNotEmpty) {
      _catalogTools = r.tools;
      _catalogSkills = r.skills;
      _catalogSubagents = r.subagents;
    }
    _catalogAt = DateTime.now();
    _catalogRev = capabilitiesRevision.value;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  String _system() {
    final now = DateTime.now();
    const days = ['', 'จันทร์', 'อังคาร', 'พุธ', 'พฤหัส', 'ศุกร์', 'เสาร์', 'อาทิตย์'];
    final dt =
        '${now.year}-${_two(now.month)}-${_two(now.day)} ${_two(now.hour)}:${_two(now.minute)}';
    final p = PrefsController.instance.value;
    final persona = kPinSystemFor(
      name: p.pinName,
      userCall: p.userCall,
      self: p.pinSelf,
      tone: p.tone,
      lang: p.lang,
      persona: p.personaMode,
      customCall: p.customCall,
      customSelf: p.customSelf,
    );
    // Match the language the user writes in; fall back to their setting. Applies
    // to everything incl. card titles/tables. Proper nouns/code/URLs stay as-is.
    final langName = p.lang == 'en' ? 'English' : 'Thai';
    var s = 'Reply in the same language the user writes in (Thai or English), '
        'including card titles and tables. If unclear, default to $langName. '
        'Keep proper nouns, code and URLs in their original language.\n'
        'เวลาปัจจุบันบนเครื่องผู้ใช้: $dt น. วัน${days[now.weekday]} '
        '(เขตเวลา Asia/Bangkok). ใช้เวลานี้อ้างอิงเสมอเมื่อบอกเวลา.\n'
        // One tool-call discipline rule instead of a paragraph per tool: when a
        // request matches a tool, CALL it — never just acknowledge or promise.
        'เมื่อคำขอตรงกับเครื่องมือที่มี ให้เรียกเครื่องมือนั้นทันที ห้ามแค่รับปาก/'
        'พิมพ์ผลลัพธ์เป็นข้อความแทน (ถ้ายังไม่เรียก ถือว่ายังไม่ได้ทำ). โดยเฉพาะ: '
        'วาด/แก้รูป (รวมสั่งอ้อม เช่น "ไม่ใช่ เอาผู้ชาย")→generate_image; '
        'เตือน/นัดเวลา→schedule_reminder; "จำไว้"→remember_fact/save_knowledge; '
        'งานที่ต้องติดตาม→add_task; ถ้ามีคำว่า "ตาม...", "เฝ้า...", หรือให้ติดตามเรื่องใดต่อเนื่อง '
        '→ บังคับเรียก add_watch ทันที (ห้ามตอบรับปากเปล่าๆ เด็ดขาด); เลิกตาม→remove_watch; ถาม "ทำอะไรได้บ้าง"→list_capabilities. '
        'ถ้าผู้ใช้ขอ "ต่อ/เชื่อม/เข้าถึง/ใช้" บริการหรือแอปภายนอกที่ไม่มีเครื่องมือ '
        '(Gmail, LINE, Facebook, ปฏิทิน ฯลฯ) หรือถาม "ต่อ X ได้ไหม"→request_capability '
        '(อย่าตอบ "ได้เลย/โอเค" ลอย ๆ) แล้วบอกตามตรงว่าตอนนี้ยังทำไม่ได้ '
        'แต่บันทึกคำขอไว้ให้แล้ว.\n\n$persona';
    // The proactive watch-offer policy now lives in the admin-managed "watch"
    // skill (injected via _catalogSkills below) — toggleable, no rebuild.
    // Remembered facts about the user — always in context so ปิ่น uses them
    // (e.g. ชื่อ/สิ่งที่ชอบ) without being asked to recall.
    if (_facts.isNotEmpty) {
      s += '\n\nสิ่งที่ผู้ใช้เคยบอกให้จำ (ใช้ประกอบการตอบเมื่อเกี่ยวข้อง '
          'โดยไม่ต้องถามซ้ำ):\n${_facts.map((f) => '- $f').join('\n')}';
    }
    // Catalog skill instructions. Capabilities the user opted out of are already
    // filtered upstream (CatalogClient.fetch), so _catalogSkills holds only the
    // ones in effect for this user.
    final blocks = <String>[
      for (final e in _catalogSkills.entries) '${e.value['instructions']}',
    ];
    if (blocks.isNotEmpty) {
      s += '\n\nความสามารถที่เปิดไว้:\n'
          '${blocks.map((b) => '- $b').join('\n')}';
    }
    // Capabilities the user switched OFF. Removing the tool isn't enough — the
    // model will otherwise fake the result itself (e.g. "ดูดวง" via render_html).
    // Tell it explicitly to refuse, not improvise.
    if (_optedOut.isNotEmpty) {
      final names =
          _optedOut.map(abilityLabel).where((s) => s.isNotEmpty).join(', ');
      s += '\n\nความสามารถที่ผู้ใช้ปิดไว้: $names. '
          'ห้ามทำสิ่งเหล่านี้เองเด็ดขาด — รวมถึงห้ามแต่งผลลัพธ์เป็นข้อความ ตาราง '
          'การ์ด หรือ HTML. ถ้าผู้ใช้ขอ ให้บอกสั้น ๆ ว่าความสามารถนี้ถูกปิดอยู่ '
          'เปิดใหม่ได้ที่หน้า "ความสามารถ".';
    }
    return s;
  }

  ToolRegistry _registry() {
    final base = <AgentTool>[
        // Remote, minimal-arg tools (weather / currency / web_search).
        ...remoteTools(proxy),
        // On-device "ตอนนี้" tools: reminders / jobs / tasks / memory, all
        // written through to the ปิ่น DM room state (source of truth).
        ...nowTools(),
        // On-device rich render: HTML card shown as-is (terminal).
        AgentTool(
          fnDecl('render_html',
              'แสดงเนื้อหาเป็น HTML ในการ์ด (ตาราง/เลย์เอาต์ที่ข้อความทำไม่ได้). '
              'ข้อความในการ์ด รวมหัวข้อ/title ใช้ภาษาเดียวกับบทสนทนา '
              '(ยกเว้นชื่อเฉพาะ/โค้ด/URL คงภาษาเดิม)',
              properties: {
                'html': {'type': 'string', 'description': 'HTML body'},
                'title': {'type': 'string'},
              },
              required: ['html']),
          (args) async => ToolResult.terminal(AgentReply(flex: {
                'header': {'title': '${args['title'] ?? 'เนื้อหา'}'},
                'body': [
                  {'type': 'html', 'html': '${args['html'] ?? ''}'}
                ],
              })),
        ),
        feedbackTool(
          fnDecl('get_time', 'เวลาปัจจุบันบนเครื่องผู้ใช้'),
          (_) => DateTime.now().toString(),
        ),
    ];
    // Merge runtime catalog tools (skip any name a built-in already covers).
    final names = base.map((t) => t.name).toSet();
    base.addAll(_catalogTools.where((t) => !names.contains(t.name)));
    // The capability list used to be dumped into the system prompt every turn
    // (bloat that grew with every tool). Now it's behind a tool the model calls
    // only when the user asks "ทำอะไรได้บ้าง". Build it from the current tools.
    final capText = _capabilityText(base);
    base.add(feedbackTool(
      fnDecl('list_capabilities',
          'แสดงรายการความสามารถทั้งหมดที่ปิ่นทำได้ตอนนี้. เรียกเมื่อผู้ใช้ถามว่า '
          '"ทำอะไรได้บ้าง/ช่วยอะไรได้/มีความสามารถอะไร"'),
      (_) async => capText,
    ));
    // Wrap base tools in a registry the subagents are sandboxed against, then
    // expose `delegate` on top (it isn't in any subset ⇒ no recursion).
    final baseReg = ToolRegistry(base);
    return ToolRegistry([...base, delegateTool(proxy, baseReg, _subagents())]);
  }

  /// The "ทำอะไรได้บ้าง" answer, built from the live tool registry so it stays in
  /// sync. Deduped by friendly label; internal tools (delegate / request_capability
  /// / list_capabilities itself) are omitted.
  static String _capabilityText(List<AgentTool> tools) {
    final caps = <String>[];
    final seen = <String>{};
    void add(String label, String desc) {
      if (seen.add(label)) caps.add('- $label: $desc');
    }
    // Plumbing the user never thinks of as a "capability" — keep it out of the
    // answer (live-data tools like weather/currency DO count and stay).
    const hide = {
      'delegate', 'request_capability', 'list_capabilities',
      'get_time', 'render_html',
    };
    for (final t in tools) {
      final n = t.name;
      if (hide.contains(n)) continue;
      final fn = t.declaration['function'] as Map;
      add(abilityLabel(n), '${fn['description']}');
    }
    add('วาดรูป', 'เนรมิตรูปจากคำบรรยาย แก้/วาดใหม่ได้');
    return 'ความสามารถทั้งหมดที่ปิ่นทำได้ตอนนี้:\n${caps.join('\n')}\n'
        'ไล่ตอบให้ครบทุกข้อ จัดเป็นหมวดอ่านง่าย ภาษาไทย ปิดท้ายชวนให้เปิดหน้า '
        '"ความสามารถ" เพื่อเพิ่มทักษะใหม่ ๆ.';
  }

  List<SubagentSpec> _subagents() {
    final names = _builtinSubagents.map((s) => s.name).toSet();
    // Built-in first; catalog (developer-published) subagents merged in.
    return [
      ..._builtinSubagents,
      ..._catalogSubagents.where((s) => !names.contains(s.name)),
    ];
  }

  static const _builtinSubagents = <SubagentSpec>[
        SubagentSpec(
          name: 'researcher',
          description: 'ค้นคว้าเชิงลึกหลายแหล่งแล้วสรุป',
          system:
              'คุณคือผู้ช่วยค้นคว้าของปิ่น. ค้นเว็บ (web_search) และความรู้ที่เก็บไว้ '
              '(recall_knowledge) หลายรอบถ้าจำเป็น แล้วสรุปคำตอบที่ครบถ้วน ตรวจสอบได้ '
              'ภาษาไทย กระชับ. ห้ามมโน ถ้าไม่เจอให้บอกตรง ๆ.',
          toolNames: ['web_search', 'recall_knowledge'],
        ),
        SubagentSpec(
          name: 'planner',
          description: 'จัดทำแผน/สรุปออกมาเป็นการ์ดสวยงาม',
          system:
              'คุณคือผู้ช่วยวางแผนของปิ่น. รับโจทย์แล้วเรียบเรียงเป็น "การ์ด" ด้วย '
              'เครื่องมือ render_html เพียงครั้งเดียว (หัวข้อชัด + รายการเป็นข้อ ๆ '
              'หรือ ตาราง). จบด้วยการ์ดเดียวที่อ่านง่าย ภาษาไทย.',
          toolNames: ['render_html'],
        ),
      ];

  /// [persistUser] = false for internal triggers (e.g. a scheduled job) — the
  /// trigger text isn't something the user typed, so it must NOT be stored as a
  /// user turn (it would render as a user bubble on reload). The reply is still
  /// stored so the card survives.
  Future<AgentReply> send(String userText,
      {String? imagePath,
      bool persistUser = true,
      String? recordText,
      String? imageRecordPath}) async {
    // Refresh the catalog if it's stale, or if the user just changed which
    // capabilities are opted in (so an opt-out drops the tool this turn — not up
    // to 30s later), so a just-published/just-disabled capability takes effect
    // without a restart.
    if (_catalogAt == null ||
        _catalogRev != capabilitiesRevision.value ||
        DateTime.now().difference(_catalogAt!) > const Duration(seconds: 30)) {
      await loadCatalog();
    }
    final brain = DeviceBrain(
      // Fresh each turn so the user's OpenRouter on/off + model take effect
      // immediately (no relaunch). Only inference uses this; catalog/tools keep
      // using `proxy` (our gateway) via its baseUrl — infer() is the only call
      // that branches direct→OpenRouter.
      proxy: devProxy(),
      tools: _registry(),
      system: _system(),
    );
    String? b64;
    if (imagePath != null) {
      b64 = base64Encode(await File(imagePath).readAsBytes());
    }
    var reply = await brain.reply(_turns, userText, imageB64: b64);
    final hints = <String>[]; // capability labels for the hint (deduped later)

    // (a) model self-tag "[ใช้: ดูดวง] …" → hint + strip it from the text.
    // Strip EVERY occurrence (the model sometimes drops it mid-text, not only
    // at the start) so the raw tag never leaks into the bubble.
    if (reply.text != null) {
      final re = RegExp(r'\[\s*ใช้\s*[:：]\s*([^\]]+)\]');
      for (final m in re.allMatches(reply.text!)) {
        hints.addAll(m.group(1)!.split(',').map((s) => s.trim()));
      }
      final cleaned = reply.text!.replaceAll(re, '').trim();
      if (cleaned != reply.text) {
        reply = AgentReply(
            text: cleaned,
            flex: reply.flex,
            usedTools: reply.usedTools,
            trace: reply.trace,
            usage: reply.usage);
      }
    }
    // (b) credit a skill when one of its required tools fired this turn.
    final usedSet = reply.usedTools.toSet();
    for (final e in _catalogSkills.entries) {
      final req = ((e.value['requires'] as Map?)?['tools'] as List?)
              ?.map((x) => '$x')
              .toSet() ??
          const <String>{};
      if (req.intersection(usedSet).isNotEmpty) {
        hints.add('${e.value['label'] ?? e.key}');
      }
    }
    if (hints.isNotEmpty) {
      // Skill/model labels first, then tool names — deduped, order preserved.
      reply = reply.withTools(
          <String>{...hints, ...reply.usedTools}.toList());
    }
    // Persist a clean transcript. For a sent photo we keep the durable image
    // path (UI-only — stripped before going back to the model) so the bubble
    // re-renders the photo after a restart, not a "[ส่งรูป]" marker. For a file
    // upload, [recordText] holds a short marker (e.g. "📄 name") so the giant
    // extracted body isn't shown in the bubble NOR resent to the model every
    // following turn — the assistant's summary in history already captures it.
    final userText2 = imagePath != null
        ? '[ส่งรูป] $userText'.trim()
        : (recordText ?? userText);
    final assistantText = reply.text?.isNotEmpty == true
        ? reply.text!
        : (reply.flex != null ? '(ส่งการ์ดให้แล้ว)' : '');
    // Append to the in-memory model transcript only (the DM room is the durable
    // store — the chat screen writes both turns to it). No local AgentStore copy.
    if (persistUser) {
      _turns.add({'role': 'user', 'content': userText2});
    }
    _turns.add({'role': 'assistant', 'content': assistantText});
    return reply;
  }
}
