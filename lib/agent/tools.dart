import 'dart:async';

import 'agent_reply.dart';

/// On-device tool: an OpenAI function `declaration` + a handler returning a
/// ToolResult — either feedback text (fed back to the model) or a terminal rich
/// reply (shown as-is). State/PII tools live here (on device); network tools
/// (web_search/weather) call our minimal-arg remote APIs — the dispatch layer
/// must never put identity/conversation/prefs into args.
class AgentTool {
  final Map<String, dynamic> declaration; // {type:function, function:{name,...}}
  final FutureOr<ToolResult> Function(Map<String, dynamic> args) handler;
  final String kind; // 'local' (PII ok) | 'remote' (blind) | 'subagent'
  const AgentTool(this.declaration, this.handler, {this.kind = 'local'});

  String get name => declaration['function']['name'] as String;

  /// The keys declared in this tool's JSON schema — the PII allowlist. The
  /// dispatch layer strips args down to these before running the tool, so the
  /// model can't smuggle identity/conversation/prefs into (esp. remote) calls.
  Set<String> get argKeys {
    final props = declaration['function']?['parameters']?['properties'];
    return props is Map ? props.keys.map((e) => '$e').toSet() : const <String>{};
  }
}

/// Convenience: a tool whose result is text fed back to the model.
AgentTool feedbackTool(
  Map<String, dynamic> decl,
  FutureOr<String> Function(Map<String, dynamic>) fn,
) =>
    AgentTool(decl, (args) async => ToolResult.feedback(await fn(args)));

Map<String, dynamic> fnDecl(
  String name,
  String description, {
  Map<String, dynamic> properties = const {},
  List<String> required = const [],
}) =>
    {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': properties,
          if (required.isNotEmpty) 'required': required,
        },
      },
    };

/// Registry of on-device tools the brain can call.
class ToolRegistry {
  final Map<String, AgentTool> _byName;
  ToolRegistry(List<AgentTool> tools)
      : _byName = {for (final t in tools) t.name: t};

  List<Map<String, dynamic>> declarations() =>
      _byName.values.map((t) => t.declaration).toList();

  bool has(String name) => _byName.containsKey(name);

  /// A registry holding only the named tools — the sandbox a subagent runs in.
  /// Names not present are simply dropped (e.g. `delegate` ⇒ no recursion).
  ToolRegistry subset(List<String> names) {
    final set = names.toSet();
    return ToolRegistry(
        _byName.values.where((t) => set.contains(t.name)).toList());
  }

  Future<ToolResult> dispatch(String name, Map<String, dynamic> args) async {
    final t = _byName[name];
    if (t == null) return ToolResult.feedback('unknown tool: $name');
    // PII gate: keep only the keys this tool declared, before it runs.
    final allowed = t.argKeys;
    final clean = <String, dynamic>{
      for (final e in args.entries)
        if (allowed.contains(e.key)) e.key: e.value,
    };
    try {
      return await t.handler(clean);
    } catch (e) {
      return ToolResult.feedback('tool error: $e');
    }
  }
}
