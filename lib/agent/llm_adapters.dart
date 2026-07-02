import 'dart:convert';

/// Translate between the OpenAI chat-completions shape (what the agent loop in
/// device_brain speaks) and the native request/response shapes of Gemini and
/// Anthropic. OpenAI-compatible providers (our proxy, OpenRouter, OpenAI, Groq,
/// Together, Ollama, …) need no translation — only these two do.
///
/// Pure map transforms → unit-testable without a network. Tool-use is the whole
/// point: the agent is tool-heavy, so both directions must carry tool calls and
/// their results, not just text.

// ─────────────────────────────── Gemini ───────────────────────────────

/// OpenAI messages+tools → a Gemini `generateContent` request body.
Map<String, dynamic> openAiToGemini(
  List<Map<String, dynamic>> messages,
  List<Map<String, dynamic>>? tools,
) {
  final sys = <String>[];
  final contents = <Map<String, dynamic>>[];
  // Gemini's functionResponse needs the function NAME, but an OpenAI tool
  // message only carries tool_call_id → remember id→name from assistant turns.
  final idToName = <String, String>{};

  for (final m in messages) {
    final role = '${m['role']}';
    if (role == 'system') {
      sys.add('${m['content'] ?? ''}');
      continue;
    }
    if (role == 'tool') {
      final id = '${m['tool_call_id'] ?? ''}';
      contents.add({
        'role': 'user',
        'parts': [
          {
            'functionResponse': {
              'name': idToName[id] ?? '${m['name'] ?? 'tool'}',
              'response': {'result': '${m['content'] ?? ''}'},
            }
          }
        ],
      });
      continue;
    }
    // user / assistant
    final parts = <Map<String, dynamic>>[];
    final content = m['content'];
    if (content is String && content.isNotEmpty) {
      parts.add({'text': content});
    } else if (content is List) {
      // OpenAI multimodal parts → keep the text pieces (images handled elsewhere).
      for (final p in content) {
        if (p is Map && p['type'] == 'text') parts.add({'text': '${p['text']}'});
      }
    }
    final calls = m['tool_calls'] as List?;
    if (calls != null) {
      for (final c in calls) {
        final fn = (c as Map)['function'] as Map? ?? const {};
        final id = '${c['id'] ?? ''}';
        final name = '${fn['name'] ?? ''}';
        if (id.isNotEmpty) idToName[id] = name;
        parts.add({
          'functionCall': {'name': name, 'args': _decodeArgs(fn['arguments'])}
        });
      }
    }
    if (parts.isEmpty) continue;
    contents.add({'role': role == 'assistant' ? 'model' : 'user', 'parts': parts});
  }

  final body = <String, dynamic>{'contents': contents};
  if (sys.isNotEmpty) {
    body['systemInstruction'] = {
      'parts': [
        {'text': sys.join('\n\n')}
      ]
    };
  }
  if (tools != null && tools.isNotEmpty) {
    body['tools'] = [
      {
        'functionDeclarations': [
          for (final t in tools)
            if ((t['function'] as Map?) != null)
              _geminiFnDecl(t['function'] as Map)
        ]
      }
    ];
  }
  return body;
}

Map<String, dynamic> _geminiFnDecl(Map fn) {
  final decl = <String, dynamic>{'name': '${fn['name']}'};
  if (fn['description'] != null) decl['description'] = '${fn['description']}';
  final params = fn['parameters'];
  // Gemini rejects an empty-property object schema; omit params when there are none.
  if (params is Map && (params['properties'] as Map?)?.isNotEmpty == true) {
    decl['parameters'] = _cleanSchema(params);
  }
  return decl;
}

/// Strip JSON-Schema keywords Gemini's function schema doesn't accept.
dynamic _cleanSchema(dynamic node) {
  if (node is Map) {
    final out = <String, dynamic>{};
    for (final e in node.entries) {
      if (const {'\$schema', 'additionalProperties', 'default'}
          .contains(e.key)) {
        continue;
      }
      out[e.key] = _cleanSchema(e.value);
    }
    return out;
  }
  if (node is List) return [for (final v in node) _cleanSchema(v)];
  return node;
}

/// A Gemini `generateContent` response → the OpenAI choices shape.
Map<String, dynamic> geminiToOpenAi(Map<String, dynamic> resp) {
  final candidates = resp['candidates'] as List?;
  final parts = (candidates != null && candidates.isNotEmpty)
      ? (((candidates.first as Map)['content'] as Map?)?['parts'] as List?) ??
          const []
      : const [];
  final buf = StringBuffer();
  final toolCalls = <Map<String, dynamic>>[];
  for (var i = 0; i < parts.length; i++) {
    final p = parts[i] as Map;
    if (p['text'] != null) buf.write(p['text']);
    final fc = p['functionCall'] as Map?;
    if (fc != null) {
      toolCalls.add({
        'id': 'call_gm_$i',
        'type': 'function',
        'function': {
          'name': '${fc['name']}',
          'arguments': jsonEncode(fc['args'] ?? const {}),
        },
      });
    }
  }
  final message = <String, dynamic>{
    'role': 'assistant',
    'content': buf.isEmpty ? null : buf.toString(),
    if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
  };
  final um = resp['usageMetadata'] as Map?;
  return {
    'choices': [
      {'message': message}
    ],
    if (um != null)
      'usage': {
        'prompt_tokens': (um['promptTokenCount'] as num?)?.toInt() ?? 0,
        'completion_tokens':
            (um['candidatesTokenCount'] as num?)?.toInt() ?? 0,
      },
  };
}

// ────────────────────────────── Anthropic ─────────────────────────────

/// OpenAI messages+tools → an Anthropic `/v1/messages` request body (model +
/// max_tokens filled by the caller).
Map<String, dynamic> openAiToClaude(
  List<Map<String, dynamic>> messages,
  List<Map<String, dynamic>>? tools,
) {
  final sys = <String>[];
  final out = <Map<String, dynamic>>[];

  for (final m in messages) {
    final role = '${m['role']}';
    if (role == 'system') {
      sys.add('${m['content'] ?? ''}');
      continue;
    }
    if (role == 'tool') {
      out.add({
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': '${m['tool_call_id'] ?? ''}',
            'content': '${m['content'] ?? ''}',
          }
        ],
      });
      continue;
    }
    final blocks = <Map<String, dynamic>>[];
    final content = m['content'];
    if (content is String && content.isNotEmpty) {
      blocks.add({'type': 'text', 'text': content});
    } else if (content is List) {
      for (final p in content) {
        if (p is Map && p['type'] == 'text') {
          blocks.add({'type': 'text', 'text': '${p['text']}'});
        }
      }
    }
    final calls = m['tool_calls'] as List?;
    if (calls != null) {
      for (final c in calls) {
        final fn = (c as Map)['function'] as Map? ?? const {};
        blocks.add({
          'type': 'tool_use',
          'id': '${c['id'] ?? ''}',
          'name': '${fn['name'] ?? ''}',
          'input': _decodeArgs(fn['arguments']),
        });
      }
    }
    if (blocks.isEmpty) continue;
    out.add({'role': role == 'assistant' ? 'assistant' : 'user', 'content': blocks});
  }

  final body = <String, dynamic>{'messages': out};
  if (sys.isNotEmpty) body['system'] = sys.join('\n\n');
  if (tools != null && tools.isNotEmpty) {
    body['tools'] = [
      for (final t in tools)
        if ((t['function'] as Map?) != null)
          {
            'name': '${(t['function'] as Map)['name']}',
            if ((t['function'] as Map)['description'] != null)
              'description': '${(t['function'] as Map)['description']}',
            'input_schema': (t['function'] as Map)['parameters'] ??
                {'type': 'object', 'properties': {}},
          }
    ];
  }
  return body;
}

/// An Anthropic `/v1/messages` response → the OpenAI choices shape.
Map<String, dynamic> claudeToOpenAi(Map<String, dynamic> resp) {
  final content = resp['content'] as List? ?? const [];
  final buf = StringBuffer();
  final toolCalls = <Map<String, dynamic>>[];
  for (final b in content) {
    final block = b as Map;
    if (block['type'] == 'text') buf.write(block['text']);
    if (block['type'] == 'tool_use') {
      toolCalls.add({
        'id': '${block['id']}',
        'type': 'function',
        'function': {
          'name': '${block['name']}',
          'arguments': jsonEncode(block['input'] ?? const {}),
        },
      });
    }
  }
  final message = <String, dynamic>{
    'role': 'assistant',
    'content': buf.isEmpty ? null : buf.toString(),
    if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
  };
  final u = resp['usage'] as Map?;
  return {
    'choices': [
      {'message': message}
    ],
    if (u != null)
      'usage': {
        'prompt_tokens': (u['input_tokens'] as num?)?.toInt() ?? 0,
        'completion_tokens': (u['output_tokens'] as num?)?.toInt() ?? 0,
      },
  };
}

/// Tool-call arguments arrive as a JSON string (OpenAI) — decode to a map for
/// the native shapes. Tolerates an already-decoded map or malformed string.
Map<String, dynamic> _decodeArgs(dynamic raw) {
  if (raw is Map) return raw.cast<String, dynamic>();
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      final d = jsonDecode(raw);
      if (d is Map) return d.cast<String, dynamic>();
    } catch (_) {/* fall through */}
  }
  return {};
}
