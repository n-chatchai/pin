import 'package:flutter/material.dart';

import '../agent/token_cost.dart';
import '../services/matrix_service.dart';
import '../theme/pin_theme.dart';

/// Token-usage + cost panel (เครื่องมือพัฒนา). Reads the account-data ledger
/// MatrixService keeps and shows latest / today / this week / this month.
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key});
  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  Map<String, dynamic>? _ledger;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final led = await MatrixService.instance.loadUsageLedger();
    if (!mounted) return;
    setState(() {
      _ledger = led;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final led = _ledger ?? const {};
    final now = DateTime.now();
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('การใช้งาน · ค่าใช้จ่าย'),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                  16, 16, 16, 16 + MediaQuery.of(context).viewPadding.bottom),
              children: [
                _card('ล่าสุด', latestUsage(led)),
                _card('วันนี้', sumUsage(led, now, 1)),
                _card('7 วัน', sumUsage(led, now, 7)),
                _card('30 วัน', sumUsage(led, now, 30)),
                const SizedBox(height: 16),
                Text(
                    'ค่าใช้จ่ายเป็นค่าประมาณ (อัตรา ~$usdToThb บาท/ดอลลาร์, '
                    'ราคาโมเดลโดยประมาณ). โทเค็นนับจริงจากผู้ให้บริการ.',
                    style: const TextStyle(
                        fontSize: 11, color: PinPalette.ink3, height: 1.4)),
              ],
            ),
    );
  }

  Widget _card(String title, UsageStat? s) {
    final stat = s ?? const UsageStat();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PinPalette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: PinPalette.ink2)),
              Text(thb(stat.costThb),
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: Theme.of(context).colorScheme.primary)),
            ],
          ),
          const SizedBox(height: 8),
          _row('โทเค็นรวม', _n(stat.totalTokens)),
          _row('เข้า (input)', _n(stat.inputTokens)),
          _row('ออก (output)', _n(stat.outputTokens)),
          _row('จำนวนครั้ง', _n(stat.turns)),
        ],
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k,
                style: const TextStyle(fontSize: 12, color: PinPalette.ink2)),
            Text(v,
                style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: PinPalette.ink)),
          ],
        ),
      );

  static String _n(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }
}
