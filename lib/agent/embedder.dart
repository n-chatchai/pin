import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;

import '../src/rust/api/embed.dart' as rust;

/// On-device text embeddings (multilingual, Thai-capable). Loads a bundled
/// sentence-transformer once and embeds entirely on the phone via the Rust FFI
/// (see rust/src/api/embed.rs) — plaintext never leaves the E2EE boundary, unlike
/// the old proxy /embed. Returns null whenever the model isn't provisioned, so
/// every caller transparently falls back to recency ranking.
///
/// Vectors are a disposable, derived cache: they live only in RAM (and the room
/// holds the source text), so a new device recomputes them from the room — no
/// embedding is ever persisted to disk or shipped to a server.
class Embedder {
  Embedder._();
  static final Embedder instance = Embedder._();

  bool _initTried = false;
  String? lastError;

  /// Lazily load the model+tokenizer assets into the Rust runtime. Idempotent;
  /// a missing asset (model not bundled yet) just leaves embeddings off.
  Future<bool> _ensure() async {
    if (rust.embedReady()) return true;
    if (_initTried) return false; // don't retry a missing/broken asset every call
    _initTried = true;
    try {
      final model = await rootBundle.load('assets/models/embed.onnx');
      final tok = await rootBundle.loadString('assets/models/tokenizer.json');
      await rust.embedInit(
        model: model.buffer.asUint8List(model.offsetInBytes, model.lengthInBytes),
        tokenizerJson: tok,
      );
      final r = rust.embedReady();
      if (!r) lastError = "Rust embedReady() returned false";
      return r;
    } catch (e) {
      print('Embedder init failed: $e');
      lastError = e.toString();
      return false; // asset missing / load failed → recency fallback
    }
  }

  /// True once the model is loaded (cheap, sync). Callers can gate UI on it.
  bool get ready => rust.embedReady();

  /// Embed a stored passage (e5 wants the "passage: " prefix). Null if no model.
  Future<List<double>?> embedPassage(String text) => _embed('passage: $text');

  /// Embed a search query (e5 wants the "query: " prefix). Null if no model.
  Future<List<double>?> embedQuery(String text) => _embed('query: $text');

  Future<List<double>?> _embed(String prefixed) async {
    if (prefixed.trim().isEmpty) return null;
    if (!await _ensure()) return null;
    try {
      final v = await rust.embedText(text: prefixed);
      return List<double>.generate(v.length, (i) => v[i].toDouble());
    } catch (_) {
      return null;
    }
  }
}

/// Cosine similarity. Vectors from [Embedder] are already L2-normalized, so this
/// reduces to a dot product, but we normalize defensively for mixed sources.
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
