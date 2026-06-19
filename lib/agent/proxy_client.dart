import 'dart:convert';

import 'package:http/http.dart' as http;

/// Client for ปิ่น's blind LLM proxy. Speaks the OpenAI chat-completions schema;
/// the proxy routes free→Gemini (our key) / paid→OpenRouter (the user's key).
/// The provider key never lives in the app.
class ProxyClient {
  final String baseUrl; // e.g. https://proxy.tokens2.io  (or http://IP:8088 dev)
  final String token; // bearer (per-user later; dev: shared)
  final String tier; // 'free' | 'paid'
  final String? openrouterKey; // paid tier only
  final String? model;

  const ProxyClient({
    required this.baseUrl,
    required this.token,
    this.tier = 'free',
    this.openrouterKey,
    this.model,
  });

  /// One chat-completions round. `messages`/`tools` are OpenAI-shaped maps.
  /// Returns the parsed response; caller reads choices[0].message.
  Future<Map<String, dynamic>> infer({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
  }) async {
    final body = <String, dynamic>{
      'messages': messages,
      if (tools != null && tools.isNotEmpty) ...{
        'tools': tools,
        'tool_choice': 'auto',
      },
      if (model != null) 'model': model,
    };
    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
      'X-Pin-Tier': tier,
      if (tier == 'paid' && openrouterKey != null)
        'X-OpenRouter-Key': openrouterKey!,
    };
    final r = await http
        .post(Uri.parse('$baseUrl/infer'), headers: headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 90));
    if (r.statusCode != 200) {
      throw Exception('proxy ${r.statusCode}: ${r.body}');
    }
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// Upload a file (PDF/Word/audio/…) → Markdown text via the markitdown
  /// service. Returns {title, markdown} or {error}. The file is processed
  /// server-side and not stored.
  Future<Map<String, dynamic>?> convertFile(String path) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/convert'))
        ..headers['Authorization'] = 'Bearer $token'
        ..files.add(await http.MultipartFile.fromPath('file', path));
      final streamed = await req.send().timeout(const Duration(seconds: 120));
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode != 200) return null;
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Voice file → text via Gemini audio (blind). Returns the transcript or ''.
  Future<String> transcribe(String path) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/transcribe'))
        ..headers['Authorization'] = 'Bearer $token'
        ..files.add(await http.MultipartFile.fromPath('file', path));
      final streamed = await req.send().timeout(const Duration(seconds: 70));
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode != 200) return '';
      return '${(jsonDecode(body) as Map)['text'] ?? ''}'.trim();
    } catch (_) {
      return '';
    }
  }

  /// First-run greeting + quick replies (server-configurable). Returns null on
  /// any failure → the app falls back to its built-in greeting.
  Future<Map<String, dynamic>?> fetchWelcome() async {
    try {
      final r = await http.get(Uri.parse('$baseUrl/welcome'),
          headers: {'Authorization': 'Bearer $token'}).timeout(
          const Duration(seconds: 8));
      if (r.statusCode != 200) return null;
      return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Debug-bot: ship a conversation turn (user text + reply + agent trace) to
  /// the proxy debug log so the developer can review and improve ปิ่น. ONLY
  /// called when the user has turned on the "ดีบักบอท" toggle (explicit opt-in
  /// that overrides the blind model). Best-effort, fire-and-forget.
  Future<void> debugLog(Map<String, dynamic> turn) async {
    try {
      await http
          .post(Uri.parse('$baseUrl/debug/log'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode(turn))
          .timeout(const Duration(seconds: 8));
    } catch (_) {/* debug log is best-effort */}
  }

  /// Register a blind wake (metadata only — no content) for an agentic job, so a
  /// future APNs push can wake the device. Best-effort.
  Future<void> scheduleRegister({
    required String jobId,
    required double nextDue,
    required String repeat,
  }) async {
    try {
      await http
          .post(Uri.parse('$baseUrl/schedule/register'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({
                'job_id': jobId,
                'device': 'no-apns', // placeholder until APNs token wired
                'next_due': nextDue,
                'repeat': repeat,
              }))
          .timeout(const Duration(seconds: 10));
    } catch (_) {/* offline → still scheduled locally */}
  }
}
