import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_log.dart';
import '../theme/pin_theme.dart';
import '../widgets/pin_toast.dart';

/// Lightweight Chuck-style HTTP inspector: a list of recent calls (method · path
/// · status · duration), tap one to read the full request / response. Plain
/// timed (rust) calls show as a single-line timing row.
class ApiLogScreen extends StatelessWidget {
  const ApiLogScreen({super.key});

  static String _hhmmss(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  static Color _statusColor(int? status) {
    if (status == null) return PinPalette.ink2;
    if (status >= 500) return const Color(0xFFC0392B);
    if (status >= 400) return const Color(0xFFE0A100);
    return const Color(0xFF2E9E63);
  }

  static Color _msColor(int ms) => ms >= 3000
      ? const Color(0xFFC0392B)
      : ms >= 1000
          ? const Color(0xFFE0A100)
          : PinPalette.ink2;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PinPalette.cream,
      appBar: AppBar(
        backgroundColor: PinPalette.cream,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('API call log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'ล้าง',
            onPressed: ApiLog.instance.clear,
          ),
        ],
      ),
      body: ValueListenableBuilder<List<ApiLogEntry>>(
        valueListenable: ApiLog.instance,
        builder: (context, items, _) {
          if (items.isEmpty) {
            return const Center(
                child: Text('ยังไม่มี call',
                    style: TextStyle(color: PinPalette.ink2)));
          }
          return ListView.separated(
            padding: EdgeInsets.only(
                bottom: 24 + MediaQuery.of(context).viewPadding.bottom),
            itemCount: items.length,
            separatorBuilder: (_, _) =>
                const Divider(height: 1, color: PinPalette.line),
            itemBuilder: (context, i) {
              final e = items[i];
              return ListTile(
                dense: true,
                leading: e.isHttp
                    ? Container(
                        width: 52,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(
                            vertical: 3, horizontal: 4),
                        decoration: BoxDecoration(
                          color: _statusColor(e.status).withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Text('${e.status}',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: _statusColor(e.status))),
                      )
                    : Icon(e.ok ? Icons.check : Icons.close,
                        size: 18,
                        color: e.ok
                            ? const Color(0xFF2E9E63)
                            : const Color(0xFFC0392B)),
                title: Text(e.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 14, color: PinPalette.ink)),
                subtitle: Text(_hhmmss(e.at),
                    style:
                        const TextStyle(fontSize: 11, color: PinPalette.ink3)),
                trailing: Text('${e.ms} ms',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _msColor(e.ms))),
                onTap: e.isHttp
                    ? () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => _CallDetail(e)))
                    : null,
              );
            },
          );
        },
      ),
    );
  }
}

class _CallDetail extends StatelessWidget {
  final ApiLogEntry e;
  const _CallDetail(this.e);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PinPalette.cream,
      appBar: AppBar(
        backgroundColor: PinPalette.cream,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(e.name, overflow: TextOverflow.ellipsis),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 12, 16, 24 + MediaQuery.of(context).viewPadding.bottom),
        children: [
          _kv('สถานะ', '${e.status} · ${e.ms} ms'),
          _kv('URL', e.url ?? '-'),
          _section(context, 'Request', e.reqBody),
          _section(context, 'Response', e.respBody),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 70,
                child: Text(k,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: PinPalette.ink2))),
            Expanded(
                child: SelectableText(v,
                    style:
                        const TextStyle(fontSize: 13, color: PinPalette.ink))),
          ],
        ),
      );

  Widget _section(BuildContext context, String title, String? body) {
    final text = (body == null || body.isEmpty) ? '(ว่าง)' : _pretty(body);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Row(
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: PinPalette.ink2)),
            const Spacer(),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: text));
                PinToast.show(context, 'คัดลอกแล้ว');
              },
            ),
          ],
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: PinPalette.line),
          ),
          child: SelectableText(text,
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 12, height: 1.45)),
        ),
      ],
    );
  }

  // Best-effort pretty-print JSON; fall back to raw on non-JSON.
  static String _pretty(String s) {
    final t = s.trim();
    if (!t.startsWith('{') && !t.startsWith('[')) return s;
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(t));
    } catch (_) {
      return s;
    }
  }
}
