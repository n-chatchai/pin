import 'dart:convert';

import 'package:http/http.dart' as http;

import 'abilities.dart';
import 'agent_reply.dart';
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
  Future<CatalogResult> fetch() async {
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
      switch (m['kind']) {
        case 'skill':
          final ins = m['instructions'];
          if (ins is String && ins.isNotEmpty) skills['${m['name']}'] = m;
        case 'subagent':
          subagents.add(SubagentSpec(
            name: '${m['name']}',
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

  AgentTool _fromManifest(Map<String, dynamic> m) {
    final name = '${m['name']}';
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
      final r = await http
          .post(
            Uri.parse('${proxy.baseUrl}/tool/$name'),
            headers: {
              'Authorization': 'Bearer ${proxy.token}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(args),
          )
          .timeout(const Duration(seconds: 35));
      if (r.statusCode != 200) {
        return ToolResult.feedback('เครื่องมือมีปัญหา (${r.statusCode})');
      }
      final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      if (d['flex'] is Map) {
        return ToolResult.terminal(
            AgentReply(flex: (d['flex'] as Map).cast<String, dynamic>()));
      }
      return ToolResult.feedback('${d['text'] ?? d['result'] ?? ''}');
    });
  }
}
