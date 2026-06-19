import 'package:flutter/material.dart';

import '../services/api_log.dart';
import '../theme/pin_theme.dart';

/// Live list of recent API/network calls + their durations, so we can see which
/// call is slow (e.g. a 30s sync) right on the device. Newest first.
class ApiLogScreen extends StatelessWidget {
  const ApiLogScreen({super.key});

  static String _hhmmss(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  Color _color(int ms) => ms >= 3000
      ? Colors.red
      : ms >= 1000
          ? Colors.orange
          : PinPalette.ink2;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
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
        builder: (context, entries, _) {
          if (entries.isEmpty) {
            return const Center(
                child: Text('ยังไม่มี API call',
                    style: TextStyle(color: PinPalette.ink2)));
          }
          return ListView.separated(
            itemCount: entries.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, color: PinPalette.line),
            itemBuilder: (context, i) {
              final e = entries[i];
              return ListTile(
                dense: true,
                leading: Text(_hhmmss(e.at),
                    style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: PinPalette.ink3)),
                title: Text(e.name,
                    style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        color: e.ok ? PinPalette.ink : Colors.red)),
                trailing: Text('${e.ms} ms',
                    style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _color(e.ms))),
              );
            },
          );
        },
      ),
    );
  }
}
