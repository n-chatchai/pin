import 'package:flutter_test/flutter_test.dart';
import 'package:pin/agent/token_cost.dart';

void main() {
  group('TokenUsage', () {
    test('cost uses per-model rate, flash-lite default', () {
      const u = TokenUsage(
          inputTokens: 1000000,
          outputTokens: 1000000,
          model: 'gemini-flash-lite-latest');
      // 0.10 + 0.40 USD = 0.50 USD
      expect(u.costUsd, closeTo(0.50, 1e-9));
      expect(u.costThb, closeTo(0.50 * usdToThb, 1e-6));
    });

    test('unknown model falls back to default price', () {
      const u = TokenUsage(inputTokens: 1000000, model: 'mystery-model');
      expect(u.costUsd, closeTo(0.10, 1e-9));
    });

    test('+ sums tokens and keeps later model', () {
      const a = TokenUsage(inputTokens: 10, outputTokens: 5, model: 'a');
      const b = TokenUsage(inputTokens: 1, outputTokens: 2, model: 'b');
      final s = a + b;
      expect(s.inputTokens, 11);
      expect(s.outputTokens, 7);
      expect(s.model, 'b');
    });

    test('fromResponse parses usage + model', () {
      final u = TokenUsage.fromResponse({
        'model': 'gemini-flash-lite-latest',
        'usage': {'prompt_tokens': 42, 'completion_tokens': 7},
      });
      expect(u.inputTokens, 42);
      expect(u.outputTokens, 7);
      expect(u.model, 'gemini-flash-lite-latest');
    });

    test('fromResponse tolerates missing usage', () {
      final u = TokenUsage.fromResponse({'model': 'x'});
      expect(u.isEmpty, isTrue);
    });

    test('json round-trips', () {
      const u = TokenUsage(inputTokens: 3, outputTokens: 4, model: 'm');
      final back = TokenUsage.fromJson(u.toJson())!;
      expect(back.inputTokens, 3);
      expect(back.outputTokens, 4);
      expect(back.model, 'm');
    });
  });

  group('ledger aggregation', () {
    final now = DateTime(2026, 6, 29);
    final ledger = {
      'days': {
        '2026-06-29': {'in': 100, 'out': 50, 'cost': 0.5, 'n': 2}, // today
        '2026-06-25': {'in': 10, 'out': 5, 'cost': 0.1, 'n': 1}, // within 7d
        '2026-06-10': {'in': 1, 'out': 1, 'cost': 0.01, 'n': 1}, // within 30d
        '2026-04-01': {'in': 999, 'out': 999, 'cost': 9.9, 'n': 9}, // outside
      },
      'last': {'in': 30, 'out': 20, 'cost': 0.2},
    };

    test('today only', () {
      final s = sumUsage(ledger, now, 1);
      expect(s.totalTokens, 150);
      expect(s.turns, 2);
      expect(s.costThb, closeTo(0.5, 1e-9));
    });

    test('7 days includes today + the 25th', () {
      final s = sumUsage(ledger, now, 7);
      expect(s.totalTokens, 165);
      expect(s.turns, 3);
    });

    test('30 days excludes the April bucket', () {
      final s = sumUsage(ledger, now, 30);
      expect(s.turns, 4);
      expect(s.inputTokens, 111);
    });

    test('latest reads the last block', () {
      final l = latestUsage(ledger)!;
      expect(l.totalTokens, 50);
      expect(l.costThb, closeTo(0.2, 1e-9));
    });

    test('empty ledger is safe', () {
      expect(sumUsage(const {}, now, 7).totalTokens, 0);
      expect(latestUsage(const {}), isNull);
    });
  });
}
