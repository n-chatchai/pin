import 'dart:convert';

import 'package:http/http.dart' as http;

import 'agent_reply.dart';
import 'proxy_client.dart';
import 'tools.dart';

/// Remote tools hosted on our proxy — minimal-arg, blind. The brain sends ONLY
/// the declared narrow args (place / base+quote / query); never identity,
/// conversation, or preferences. Result text is fed back to the model.
AgentTool _remote(ProxyClient proxy, Map<String, dynamic> decl) {
  final name = decl['function']['name'] as String;
  return AgentTool(decl, kind: 'remote', (args) async {
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
    // {flex} → a card shown as-is; else {text} fed back to the model.
    if (d['flex'] is Map) {
      return ToolResult.terminal(
          AgentReply(flex: (d['flex'] as Map).cast<String, dynamic>()));
    }
    return ToolResult.feedback('${d['text'] ?? d['result'] ?? ''}');
  });
}

List<AgentTool> remoteTools(ProxyClient proxy) => [
      _remote(
        proxy,
        fnDecl('get_weather', 'ดูพยากรณ์อากาศของเมืองที่ระบุ',
            properties: {
              'place': {'type': 'string', 'description': 'ชื่อเมือง'},
              'days': {'type': 'integer', 'description': 'จำนวนวัน 1-7'},
            },
            required: ['place']),
      ),
      _remote(
        proxy,
        fnDecl('get_currency', 'ดูอัตราแลกเปลี่ยน เช่น USD/THB',
            properties: {
              'base': {'type': 'string', 'description': 'สกุลฐาน'},
              'quote': {'type': 'string', 'description': 'สกุลเทียบ'},
            }),
      ),
      _remote(
        proxy,
        fnDecl('web_search', 'ค้นข้อมูลสด/ปัจจุบันจากเว็บ (ข่าว/ผลบอล/ราคา)',
            properties: {
              'query': {'type': 'string', 'description': 'คำค้น'},
            },
            required: ['query']),
      ),
    ];
