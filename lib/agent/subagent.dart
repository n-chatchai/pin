import 'agent_reply.dart';
import 'device_brain.dart';
import 'proxy_client.dart';
import 'tools.dart';

/// A focused on-device helper: its own system prompt + a *subset* of tools.
/// Same Claude-Code subagent shape (name/description/tools/system); runs as a
/// child DeviceBrain so it stays on the phone and sees no more than the parent.
class SubagentSpec {
  final String name;
  final String description; // when to delegate (shown to the main brain)
  final String system;
  final List<String> toolNames; // the sandbox allowlist
  final int maxSteps;
  const SubagentSpec({
    required this.name,
    required this.description,
    required this.system,
    this.toolNames = const [],
    this.maxSteps = 6,
  });
}

/// Builds the on-device `delegate` tool. The main brain calls it to hand a
/// multi-step task to a subagent, which runs a bounded loop in a **sandboxed**
/// child registry (`base.subset(spec.toolNames)`) — so it can only touch its
/// declared tools, and never `delegate` (no recursion), and returns text.
AgentTool delegateTool(
    ProxyClient proxy, ToolRegistry base, List<SubagentSpec> subs) {
  final byName = {for (final s in subs) s.name: s};
  final decl = fnDecl(
    'delegate',
    'มอบงานซับซ้อนหลายขั้นให้ผู้ช่วยเฉพาะทาง ใช้เมื่อต้องค้น/ประมวลหลายรอบกว่าจะได้คำตอบ. '
        'ผู้ช่วยที่มี: ${subs.map((s) => '${s.name} (${s.description})').join('; ')}',
    properties: {
      'subagent': {
        'type': 'string',
        'enum': subs.map((s) => s.name).toList(),
        'description': 'ชื่อผู้ช่วย',
      },
      'task': {'type': 'string', 'description': 'โจทย์/งานที่มอบหมาย'},
    },
    required: ['subagent', 'task'],
  );
  return AgentTool(decl, kind: 'subagent', (args) async {
    final spec = byName['${args['subagent']}'];
    if (spec == null) return ToolResult.feedback('ยังไม่มีผู้ช่วยนั้น');
    final child = DeviceBrain(
      proxy: proxy,
      tools: base.subset(spec.toolNames), // sandbox enforced here
      system: spec.system,
      maxSteps: spec.maxSteps,
    );
    final reply = await child.reply(const [], '${args['task']}');
    // If the subagent built a card (flex/html), show it as-is; else feed text.
    if (reply.flex != null) return ToolResult.terminal(reply);
    final text = (reply.text ?? '').trim();
    return ToolResult.feedback(
        text.isEmpty ? 'ค้นแล้วยังไม่ได้คำตอบชัด ลองถามใหม่อีกที' : text);
  });
}
