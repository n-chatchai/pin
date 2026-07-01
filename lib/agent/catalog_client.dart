import 'dart:convert';

import 'package:http/http.dart' as http;

import 'abilities.dart';
import 'agent_reply.dart';
import 'news_tool.dart';
import 'proxy_client.dart';
import 'subagent.dart';
import 'tools.dart';

/// Fetches the proxy `/catalog` and turns each blind manifest into a remote
/// AgentTool, so new tools (incl. MCP-fronted) appear at runtime without an app
/// update. Best-effort: returns `[]` on any failure → the app keeps its
/// built-ins. The PII gate still applies (dispatch strips args to the declared
/// keys carried in each manifest's `parameters`).
/// Split catalog: callable tools + skills (name → full manifest, for
/// instructions + label + requires) + subagents.
class CatalogResult {
  final List<AgentTool> tools;
  final Map<String, Map<String, dynamic>> skills;
  final List<SubagentSpec> subagents;
  const CatalogResult(this.tools, this.skills, this.subagents);
}

class CatalogClient {
  final ProxyClient proxy;
  const CatalogClient(this.proxy);

  Future<List<AgentTool>> fetchTools() async {
    return (await fetch()).tools;
  }

  /// Fetch the catalog and split it: callable tools (remote/mcp) vs skills
  /// (instructions injected into the persona, not tools). Best-effort.
  Future<CatalogResult> fetch({Set<String> optedOut = const {}}) async {
    final manifests = await fetchManifests();
    // Map each capability's name → Thai label so the "ใช้: …" hint shows Thai.
    registerAbilityLabels({
      for (final m in manifests)
        '${m['name']}': '${m['label'] ?? ''}',
    });
    final tools = <AgentTool>[];
    final skills = <String, Map<String, dynamic>>{}; // name -> manifest
    final subagents = <SubagentSpec>[];
    for (final m in manifests) {
      final name = '${m['name']}';
      // Opt-out model: every catalog capability is available by default (so ปิ่น
      // can ดูดวง out of the box). The user disables the ones they don't want from
      // the abilities store; those names land in `optedOut` and drop out here.
      if (optedOut.contains(name)) continue;

      switch (m['kind']) {
        case 'skill':
          final ins = m['instructions'];
          if (ins is String && ins.isNotEmpty) skills[name] = m;
        case 'subagent':
          subagents.add(SubagentSpec(
            name: name,
            description: '${m['description'] ?? ''}',
            system: '${m['system'] ?? ''}',
            toolNames: (m['toolNames'] as List?)?.map((e) => '$e').toList() ??
                const [],
            maxSteps: (m['maxSteps'] is num) ? (m['maxSteps'] as num).toInt() : 6,
          ));
        default:
          tools.add(_fromManifest(m));
      }
    }
    return CatalogResult(tools, skills, subagents);
  }

  /// Raw catalog manifests (incl. consumer display fields label/blurb/icon/
  /// group/needs_connect). Empty on failure.
  Future<List<Map<String, dynamic>>> fetchManifests() async {
    try {
      final r = await http.get(
        Uri.parse('${proxy.baseUrl}/catalog'),
        headers: {'Authorization': 'Bearer ${proxy.token}'},
      ).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return const [];
      final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      return [
        for (final m in (body['tools'] as List? ?? const []))
          (m as Map).cast<String, dynamic>()
      ];
    } catch (_) {
      return const [];
    }
  }

  /// The assistants (ผู้ช่วย) — researcher/shopper/tutor etc, each with its
  /// interaction_mode + bound capabilities. Best-effort; empty on failure.
  Future<List<Map<String, dynamic>>> fetchAssistants() async {
    try {
      final r = await http.get(
        Uri.parse('${proxy.baseUrl}/catalog'),
        headers: {'Authorization': 'Bearer ${proxy.token}'},
      ).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return const [];
      final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      return [
        for (final a in (body['assistants'] as List? ?? const []))
          (a as Map).cast<String, dynamic>()
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Paid-store filter chips — [{id,label,count}] of paid categories. Best-effort.
  Future<List<Map<String, dynamic>>> fetchCategories() async {
    try {
      final r = await http.get(
        Uri.parse('${proxy.baseUrl}/catalog/categories'),
        headers: {'Authorization': 'Bearer ${proxy.token}'},
      ).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return const [];
      final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      return [
        for (final c in (body['categories'] as List? ?? const []))
          (c as Map).cast<String, dynamic>()
      ];
    } catch (_) {
      return const [];
    }
  }

  AgentTool _fromManifest(Map<String, dynamic> m) {
    final name = '${m['name']}';
    // Admin-set preferred rendering of the result: auto | card | text.
    final render = '${m['render'] ?? 'auto'}';
    // Params the user must choose before the tool runs (e.g. an enum like
    // ดูดวง system=thai/bazi) — the model asks instead of guessing.
    final askParams =
        (m['askParams'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
    // `news` runs on-device (RSS fetch + summarise); the manifest only carries
    // its config (admin-set sources per topic). Build the local tool, not a
    // remote proxy call.
    if (name == 'news') return newsTool(proxy, config: m['config']);
    final decl = <String, dynamic>{
      'type': 'function',
      'function': {
        'name': name,
        'description': '${m['description'] ?? ''}',
        'parameters': m['parameters'] ??
            <String, dynamic>{'type': 'object', 'properties': {}},
      },
    };
    return AgentTool(decl, kind: '${m['kind'] ?? 'remote'}', (args) async {
      // Force-ask: if a configured param is missing, ปิ่น asks the user first
      // (don't run the tool with a guessed enum).
      for (final p in askParams) {
        final v = args[p];
        if (v == null || '$v'.trim().isEmpty) {
          final opts = _enumOptions(decl, p);
          return ToolResult.feedback(
              'ก่อนใช้ "${abilityLabel(name)}" ต้องให้ผู้ใช้เลือก "$p" ก่อน'
              '${opts.isEmpty ? "" : " (ตัวเลือก: ${opts.join(" / ")})"} — '
              'ถามผู้ใช้ก่อน อย่าเดาเอง แล้วค่อยเรียกเครื่องมือนี้อีกครั้ง');
        }
      }
      final r = await http
          .post(
            Uri.parse('${proxy.baseUrl}/tool/$name'),
            headers: {
              'Authorization': 'Bearer ${proxy.token}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(args),
          )
          // Must clear the proxy's own MCP read timeout (90s) — some MCP tools
          // are LLM-backed and take ~35s+, and 35s here would cut them off.
          .timeout(const Duration(seconds: 100));
      if (r.statusCode != 200) {
        return ToolResult.feedback('เครื่องมือมีปัญหา (${r.statusCode})');
      }
      final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      if (d['flex'] is Map) {
        return ToolResult.terminal(
            AgentReply(flex: (d['flex'] as Map).cast<String, dynamic>()));
      }
      // Pull a clean human string out of whatever the tool returned (handles
      // {text}, {result}, {reading}, nested, or a JSON-string) — never let raw
      // JSON reach the model, which would echo it (e.g. ดูดวง's {"reading":…}).
      final text = _resultText(d);
      if (text.isEmpty) return ToolResult.feedback('ทำให้เรียบร้อยแล้ว');
      // Admin preference wins: card = always a card, text = always fed back for
      // ปิ่น to phrase, auto = card for a substantial answer (a reading) and
      // feed-back for short bits. Either way the model never sees raw JSON.
      final asCard =
          render == 'card' || (render != 'text' && text.length > 120);
      if (asCard) {
        return ToolResult.terminal(AgentReply(flex: {
          'header': {'icon': 'sparkles', 'title': abilityLabel(name)},
          'body': [
            {'type': 'text', 'text': text}
          ],
        }));
      }
      return ToolResult.feedback(text);
    });
  }

  /// Extract the readable text from a tool result of unknown shape — common text
  /// keys, nested maps, or a JSON-encoded string. Empty if nothing textual.
  static String _resultText(dynamic v) {
    if (v is String) {
      final t = v.trim();
      if ((t.startsWith('{') || t.startsWith('[')) && t.length > 1) {
        try {
          return _resultText(jsonDecode(t));
        } catch (_) {/* not JSON — use as-is */}
      }
      return t;
    }
    if (v is Map) {
      for (final k in const [
        'text', 'reading', 'result', 'answer', 'content', 'message', 'summary',
        'output', 'response'
      ]) {
        if (v.containsKey(k)) {
          final s = _resultText(v[k]);
          if (s.isNotEmpty) return s;
        }
      }
    }
    return '';
  }

  /// Declared enum options for param [p] (for the "ask first" prompt). Empty if
  /// the param has no enum.
  static List<String> _enumOptions(Map<String, dynamic> decl, String p) {
    final props = decl['function']?['parameters']?['properties'];
    if (props is Map && props[p] is Map) {
      final e = (props[p] as Map)['enum'];
      if (e is List) return e.map((x) => '$x').toList();
    }
    return const [];
  }
}
