import 'package:flutter/material.dart';

import '../services/matrix_service.dart';
import '../services/prefs.dart';
import '../theme/theme_controller.dart';
import '../theme/pin_theme.dart';

class DeviceDataScreen extends StatefulWidget {
  const DeviceDataScreen({super.key});
  @override
  State<DeviceDataScreen> createState() => _DeviceDataScreenState();
}

class _DeviceDataScreenState extends State<DeviceDataScreen> {
  Map<String, String>? _roomPrefs;
  String? _roomId;
  bool _loading = true;
  
  // Room-store raw lists
  final Map<String, List<dynamic>> _storeRaw = {};
  List<dynamic>? _memFacts;
  List<dynamic>? _memKnow;

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
    _storeRaw.clear();
    _memFacts = _memKnow = null;
    if (roomId != null) {
      rp = await m.loadPrefsFromRoom(roomId);
      for (final t in const [
        'io.tokens2.reminders',
        'io.tokens2.tasks',
        'io.tokens2.events',
        'io.tokens2.files',
        'io.tokens2.capability_requests',
      ]) {
        _storeRaw[t] = await m.loadListFromRoom(roomId, t);
      }
      final mem = await m.loadEncryptedBlob(roomId, 'io.tokens2.memory');
      if (mem != null) {
        _memFacts = _flattenFacts(mem['facts']);
        _memKnow = _flattenKnowledge(mem['knowledge']);
      }
    }
    if (!mounted) return;
    setState(() {
      _roomId = roomId;
      _roomPrefs = rp;
      _loading = false;
    });
  }

  List<dynamic> _flattenFacts(dynamic v) {
    if (v is! Map) return [];
    final res = [];
    for (final e in v.values) {
      if (e is List) {
        for (final item in e) {
          res.add({'fact': item.toString()});
        }
      }
    }
    return res;
  }

  List<dynamic> _flattenKnowledge(dynamic v) {
    if (v is! Map) return [];
    final res = [];
    for (final e in v.values) {
      if (e is List) res.addAll(e);
    }
    return res;
  }

  @override
  Widget build(BuildContext context) {
    final m = MatrixService.instance;
    final p = PrefsController.instance.value;
    
    return DefaultTabController(
      length: 8,
      child: Scaffold(
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
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'ทั่วไป'),
              Tab(text: 'Reminders'),
              Tab(text: 'Tasks'),
              Tab(text: 'Events'),
              Tab(text: 'Files'),
              Tab(text: 'Capabilities'),
              Tab(text: 'Facts (Memory)'),
              Tab(text: 'Knowledge (Memory)'),
            ],
          ),
        ),
        body: _loading 
            ? const Center(child: CircularProgressIndicator()) 
            : TabBarView(
                children: [
                  _buildOverviewTab(m, p),
                  _buildDataTable(_storeRaw['io.tokens2.reminders']),
                  _buildDataTable(_storeRaw['io.tokens2.tasks']),
                  _buildDataTable(_storeRaw['io.tokens2.events']),
                  _buildDataTable(_storeRaw['io.tokens2.files']),
                  _buildDataTable(_storeRaw['io.tokens2.capability_requests']),
                  _buildDataTable(_memFacts),
                  _buildDataTable(_memKnow),
                ],
              ),
      ),
    );
  }

  Widget _buildOverviewTab(MatrixService m, PinPrefs p) {
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewPadding.bottom),
      children: [
        _label('บัญชี'),
        _kv('user', m.userId ?? '—'),
        _kv('ปิ่น', m.pinUserId ?? '—'),
        _kv('room', _roomId ?? '—'),
        const SizedBox(height: 16),

        _label('เทียบ persona · ROOM (source) ↔ LOCAL (in-memory)'),
        if (_roomPrefs == null)
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

        _label('LOCAL-ONLY · device settings (ไม่อยู่ใน room)'),
        _kv('debugBot', p.debugBot ? '1' : '0'),
      ],
    );
  }

  Widget _buildDataTable(List<dynamic>? items) {
    if (items == null || items.isEmpty) {
      return const Center(
        child: Text('ไม่มีข้อมูล', style: TextStyle(color: PinPalette.ink2)),
      );
    }

    // Extract all unique keys to form columns
    final Set<String> keys = {};
    for (final item in items) {
      if (item is Map) {
        keys.addAll(item.keys.map((k) => k.toString()));
      }
    }
    
    if (keys.isEmpty) {
      // Not a list of maps, just list of values
      return ListView.builder(
        itemCount: items.length,
        itemBuilder: (context, index) => ListTile(
          title: Text(items[index].toString(), style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
        ),
      );
    }

    final columns = keys.toList();

    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          dataRowMinHeight: 48,
          dataRowMaxHeight: 120,
          columns: columns
              .map((c) => DataColumn(
                    label: Text(c, style: const TextStyle(fontWeight: FontWeight.bold, color: PinPalette.ink2)),
                  ))
              .toList(),
          rows: items.map((item) {
            final map = item is Map ? item : {};
            return DataRow(
              cells: columns.map((c) {
                final val = map[c];
                return DataCell(
                  Container(
                    constraints: const BoxConstraints(maxWidth: 300), // Prevent super wide columns
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        val?.toString() ?? '—',
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                      ),
                    ),
                  ),
                );
              }).toList(),
            );
          }).toList(),
        ),
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
        ('lang', 'lang', p.lang),
        ('onboarded', 'onboarded', p.onboarded ? '1' : '0'),
        ('personaSetup', 'persona_setup', p.personaSetup ? '1' : '0'),
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
