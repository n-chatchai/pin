import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'proxy_client.dart';

/// Embeddings for on-device semantic memory, via the proxy's /embed (Gemini,
/// 256-dim). Returns null on failure so callers can fall back to keyword search.
class EmbedClient {
  final ProxyClient proxy;
  const EmbedClient(this.proxy);

  Future<List<double>?> embed(String text) async {
    try {
      final r = await http
          .post(
            Uri.parse('${proxy.baseUrl}/embed'),
            headers: {
              'Authorization': 'Bearer ${proxy.token}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'input': text}),
          )
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final v = (d['data'] as List).first['embedding'] as List;
      return v.map((e) => (e as num).toDouble()).toList();
    } catch (_) {
      return null;
    }
  }
}

double cosine(List<double> a, List<double> b) {
  if (a.isEmpty || b.isEmpty || a.length != b.length) return 0;
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}
