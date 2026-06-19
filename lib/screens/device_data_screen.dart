import 'package:flutter/material.dart';

import '../services/matrix_service.dart';
import '../services/prefs.dart';
import '../theme/pin_theme.dart';
import '../theme/theme_controller.dart';

/// Settings → debug: the persona/theme now live in the ปิ่น ROOM STATE
/// (io.tokens2.prefs) as the single source of truth — this screen shows that
/// room copy next to the local PrefsController copy so any divergence is
/// obvious. The old on-device AgentStore was removed with the local-cut.
class DeviceDataScreen extends StatefulWidget {
  const DeviceDataScreen({super.key});

  @override
  State<DeviceDataScreen> createState() => _DeviceDataScreenState();
}

class _DeviceDataScreenState extends State<DeviceDataScreen> {
  Map<String, String>? _roomPrefs;
  String? _roomId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final roomId = await MatrixService.instance.pinRoomId();
    Map<String, String>? rp;
    if (roomId != null) {
      rp = await MatrixService.instance.loadPrefsFromRoom(roomId);
    }
    if (!mounted) return;
    setState(() {
      _roomId = roomId;
      _roomPrefs = rp;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = MatrixService.instance;
    final p = PrefsController.instance.value;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('ข้อมูล / debug'),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _label('บัญชี'),
          _kv('user', m.userId ?? '—'),
          _kv('ปิ่น', m.pinUserId ?? '—'),
          _kv('room', _roomId ?? '—'),
          const SizedBox(height: 16),

          _label('ROOM STATE · io.tokens2.prefs (source of truth)'),
          if (_loading)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: CircularProgressIndicator())
          else if (_roomPrefs == null)
            const Text('ยังไม่มี persona ใน room (จะถูกตั้งตอน setup ในแชต)',
                style: TextStyle(color: PinPalette.ink2))
          else
            for (final e in _roomPrefs!.entries) _kv(e.key, e.value),
          const SizedBox(height: 16),

          _label('LOCAL · PrefsController (cache)'),
          _kv('pin_name', p.pinName),
          _kv('user_call', p.userCall),
          _kv('pin_self', p.pinSelf),
          _kv('pin_ending', p.pinEnding),
          _kv('theme', ThemeController.instance.value.key),
          _kv('lang', p.lang),
          _kv('onboarded', p.onboarded ? '1' : '0'),
          _kv('personaSetup', p.personaSetup ? '1' : '0'),
          _kv('tourDone', p.tourDone ? '1' : '0'),
        ],
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t,
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: PinPalette.ink2)),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 96,
                child: Text(k,
                    style: const TextStyle(
                        color: PinPalette.ink2,
                        fontSize: 12,
                        fontFamily: 'monospace'))),
            Expanded(
                child: SelectableText(v,
                    style: const TextStyle(
                        fontSize: 12,
                        color: PinPalette.ink,
                        fontFamily: 'monospace'))),
          ],
        ),
      );
}
