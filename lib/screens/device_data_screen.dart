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
  // Room-store dumps (verification that data lives in Matrix, not local).
  final Map<String, int> _storeCounts = {};
  int? _memFacts;
  int? _memKnow;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final m = MatrixService.instance;
    final roomId = await m.pinRoomId();
    Map<String, String>? rp;
    _storeCounts.clear();
    _memFacts = _memKnow = null;
    if (roomId != null) {
      rp = await m.loadPrefsFromRoom(roomId);
      for (final t in const [
        'io.tokens2.reminders',
        'io.tokens2.tasks',
        'io.tokens2.events',
        'io.tokens2.files',
      ]) {
        _storeCounts[t] = (await m.loadListFromRoom(roomId, t)).length;
      }
      final mem = await m.loadEncryptedBlob(roomId, 'io.tokens2.memory');
      if (mem != null) {
        _memFacts = _countNested(mem['facts']);
        _memKnow = _countNested(mem['knowledge']);
      }
    }
    if (!mounted) return;
    setState(() {
      _roomId = roomId;
      _roomPrefs = rp;
      _loading = false;
    });
  }

  // facts/knowledge are per-room maps {roomId: [...]} → total across rooms.
  static int _countNested(dynamic v) {
    if (v is List) return v.length;
    if (v is Map) {
      var n = 0;
      for (final e in v.values) {
        if (e is List) n += e.length;
      }
      return n;
    }
    return 0;
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
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewPadding.bottom),
        children: [
          _label('บัญชี'),
          _kv('user', m.userId ?? '—'),
          _kv('ปิ่น', m.pinUserId ?? '—'),
          _kv('room', _roomId ?? '—'),
          const SizedBox(height: 16),

          _label('เทียบ persona · ROOM (source) ↔ LOCAL (in-memory)'),
          if (_loading)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: CircularProgressIndicator())
          else if (_roomPrefs == null)
            const Text('ยังไม่มี persona ใน room (จะถูกตั้งตอน setup ในแชต)',
                style: TextStyle(color: PinPalette.ink2))
          else ...[
            _cmpHeader(),
            for (final c in _comparisons(p)) _cmp(c.$1, c.$2, c.$3),
            const SizedBox(height: 6),
            Builder(builder: (_) {
              final diff = _comparisons(p)
                  .where((c) => (_roomPrefs![c.$2] ?? '') != c.$3)
                  .length;
              return Text(
                  diff == 0 ? '✓ ตรงกันทุกฟิลด์' : '✗ ต่างกัน $diff ฟิลด์',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: diff == 0
                          ? const Color(0xFF2E9E63)
                          : const Color(0xFFC0392B)));
            }),
          ],
          const SizedBox(height: 16),

          _label('ROOM STORES · ของที่ปิ่นเก็บบน Matrix (source of truth)'),
          if (_loading)
            const SizedBox.shrink()
          else if (_roomId == null)
            const Text('ยังไม่มีห้องปิ่น', style: TextStyle(color: PinPalette.ink2))
          else ...[
            _kv('reminders', '${_storeCounts['io.tokens2.reminders'] ?? 0} รายการ'),
            _kv('tasks', '${_storeCounts['io.tokens2.tasks'] ?? 0} รายการ'),
            _kv('events', '${_storeCounts['io.tokens2.events'] ?? 0} รายการ'),
            _kv('files', '${_storeCounts['io.tokens2.files'] ?? 0} รายการ'),
            _kv('memory',
                _memFacts == null ? '— (ยังไม่มี/E2EE)' : '$_memFacts facts · $_memKnow knowledge (E2EE)'),
          ],
          const SizedBox(height: 16),

          _label('LOCAL-ONLY · device settings (ไม่อยู่ใน room)'),
          _kv('lang', p.lang),
          _kv('onboarded', p.onboarded ? '1' : '0'),
          _kv('personaSetup', p.personaSetup ? '1' : '0'),
          _kv('debugBot', p.debugBot ? '1' : '0'),
        ],
      ),
    );
  }

  /// (display key, room-state key, local in-memory value) for each persona
  /// field that lives in the room. Room is the source; local should match.
  List<(String, String, String)> _comparisons(PinPrefs p) => [
        ('pin_name', 'pin_name', p.pinName),
        ('user_name', 'user_name', p.userName),
        ('user_call', 'user_call', p.userCall),
        ('pin_self', 'pin_self', p.pinSelf),
        ('tone', 'tone', p.tone),
        ('pin_ending', 'pin_ending', p.pinEnding),
        ('persona_mode', 'persona_mode', p.personaMode),
        ('custom_call', 'custom_call', p.customCall),
        ('custom_self', 'custom_self', p.customSelf),
        ('theme', 'theme', ThemeController.instance.value.key),
      ];

  static const _mono = TextStyle(fontSize: 11, fontFamily: 'monospace');

  Widget _cmpHeader() => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          const SizedBox(
              width: 84, child: Text('field', style: _mono)),
          const Expanded(child: Text('room', style: _mono)),
          const Expanded(child: Text('local', style: _mono)),
          const SizedBox(width: 18),
        ]),
      );

  Widget _cmp(String label, String roomKey, String localVal) {
    final roomVal = _roomPrefs?[roomKey] ?? '—';
    final match = roomVal == localVal;
    const bad = Color(0xFFC0392B);
    const good = Color(0xFF2E9E63);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 84,
            child: Text(label, style: _mono.copyWith(color: PinPalette.ink2))),
        Expanded(
            child:
                Text(roomVal, style: _mono.copyWith(color: PinPalette.ink))),
        Expanded(
            child: Text(localVal.isEmpty ? '∅' : localVal,
                style: _mono.copyWith(color: match ? PinPalette.ink : bad))),
        SizedBox(
            width: 18,
            child: Icon(match ? Icons.check : Icons.close,
                size: 14, color: match ? good : bad)),
      ]),
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
