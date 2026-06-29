/// Token usage + cost for one ปิ่น turn. Pure (no Flutter/rust) so it unit-tests
/// fast. The LLM response carries `usage` (prompt/completion tokens) and a
/// `model` id; this turns that into a raw token count and a Thai-baht estimate.
library;

/// USD → THB conversion. ponytail: a fixed rate is fine for a cost ESTIMATE in a
/// dev panel; bump it here if the baht drifts (no live FX lookup for a hint).
const usdToThb = 36.5;

/// Per-model price in USD per 1,000,000 tokens (input, output). Matched by
/// substring so "gemini-flash-lite-latest" hits the "flash-lite" row. ponytail:
/// approximate public list prices — tune as providers change. Order matters:
/// most specific substring first.
const _pricePer1M = <String, (double, double)>{
  'flash-lite': (0.10, 0.40),
  'gemini-2.5-flash': (0.30, 2.50),
  'gemini-flash': (0.30, 2.50),
  'gpt-4o-mini': (0.15, 0.60),
  'gpt-4o': (2.50, 10.0),
};

/// Fallback when the model id matches nothing above (free-tier flash-lite rate).
const _defaultPrice = (0.10, 0.40);

(double, double) _priceFor(String? model) {
  final m = (model ?? '').toLowerCase();
  for (final e in _pricePer1M.entries) {
    if (m.contains(e.key)) return e.value;
  }
  return _defaultPrice;
}

class TokenUsage {
  final int inputTokens;
  final int outputTokens;
  final String? model;

  const TokenUsage(
      {this.inputTokens = 0, this.outputTokens = 0, this.model});

  int get totalTokens => inputTokens + outputTokens;
  bool get isEmpty => totalTokens == 0;

  /// Cost in USD from the per-model rate.
  double get costUsd {
    final (inUsd, outUsd) = _priceFor(model);
    return inputTokens / 1e6 * inUsd + outputTokens / 1e6 * outUsd;
  }

  double get costThb => costUsd * usdToThb;

  /// Sum two usages (the agent loop calls the model several times per turn).
  /// Keeps the later model id when set.
  TokenUsage operator +(TokenUsage o) => TokenUsage(
        inputTokens: inputTokens + o.inputTokens,
        outputTokens: outputTokens + o.outputTokens,
        model: o.model ?? model,
      );

  /// Parse an OpenAI/Gemini chat-completions response's `usage` block.
  static TokenUsage fromResponse(Map<String, dynamic> resp) {
    final u = resp['usage'];
    if (u is! Map) return TokenUsage(model: resp['model'] as String?);
    int n(String k) => (u[k] as num?)?.toInt() ?? 0;
    return TokenUsage(
      inputTokens: n('prompt_tokens'),
      outputTokens: n('completion_tokens'),
      model: resp['model'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'in': inputTokens,
        'out': outputTokens,
        if (model != null) 'model': model,
      };

  static TokenUsage? fromJson(dynamic v) {
    if (v is! Map) return null;
    int n(String k) => (v[k] as num?)?.toInt() ?? 0;
    final u = TokenUsage(
        inputTokens: n('in'), outputTokens: n('out'), model: v['model'] as String?);
    return u.isEmpty && u.model == null ? null : u;
  }

  /// "1,234 โทเค็น · ฿0.0021" — raw count + baht for the message footer.
  String get label => '${_thousands(totalTokens)} โทเค็น · ${thb(costThb)}';
}

/// Group digits with commas: 12345 → "12,345".
String _thousands(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// One aggregated slice of the usage ledger (a day, a week, a month, …).
class UsageStat {
  final int inputTokens;
  final int outputTokens;
  final double costThb;
  final int turns;
  const UsageStat(
      {this.inputTokens = 0,
      this.outputTokens = 0,
      this.costThb = 0,
      this.turns = 0});

  int get totalTokens => inputTokens + outputTokens;

  UsageStat operator +(UsageStat o) => UsageStat(
        inputTokens: inputTokens + o.inputTokens,
        outputTokens: outputTokens + o.outputTokens,
        costThb: costThb + o.costThb,
        turns: turns + o.turns,
      );
}

/// Sum the ledger's daily buckets over the [days] most recent days (inclusive of
/// today), relative to [now]. days=1 → today, 7 → this week, 30 → this month.
UsageStat sumUsage(Map<String, dynamic> ledger, DateTime now, int days) {
  final buckets = (ledger['days'] as Map?) ?? const {};
  final cutoff = DateTime(now.year, now.month, now.day)
      .subtract(Duration(days: days - 1));
  var acc = const UsageStat();
  for (final e in buckets.entries) {
    final d = DateTime.tryParse('${e.key}');
    if (d == null || d.isBefore(cutoff)) continue;
    final m = e.value;
    if (m is! Map) continue;
    int n(String k) => (m[k] as num?)?.toInt() ?? 0;
    acc = acc +
        UsageStat(
            inputTokens: n('in'),
            outputTokens: n('out'),
            costThb: (m['cost'] as num?)?.toDouble() ?? 0,
            turns: n('n'));
  }
  return acc;
}

/// The most recent turn from the ledger's `last` block (null if none).
UsageStat? latestUsage(Map<String, dynamic> ledger) {
  final m = ledger['last'];
  if (m is! Map) return null;
  int n(String k) => (m[k] as num?)?.toInt() ?? 0;
  return UsageStat(
      inputTokens: n('in'),
      outputTokens: n('out'),
      costThb: (m['cost'] as num?)?.toDouble() ?? 0,
      turns: 1);
}

/// Format baht with enough precision for tiny per-turn costs.
String thb(double v) {
  if (v == 0) return '฿0';
  if (v < 0.01) return '฿${v.toStringAsFixed(4)}';
  if (v < 1) return '฿${v.toStringAsFixed(3)}';
  return '฿${v.toStringAsFixed(2)}';
}
