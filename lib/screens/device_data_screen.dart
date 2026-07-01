import 'package:flutter/material.dart';

import '../services/matrix_service.dart';
import '../services/prefs.dart';
import '../theme/theme_controller.dart';
import '../theme/pin_theme.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../widgets/pin_toast.dart';
import '../agent/agent_store.dart';
import '../services/now_controllers.dart';
import '../services/notification_service.dart';

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

  void _refresh() {
    _load();
  }

  Future<void> _clearReminders() async {
    final s = AgentStore();
    await s.load();
    // Delete one by one to clear OS alarms and local cache too
    final list = JobsController.instance.value.toList();
    for (final j in list) {
      await s.removeReminder(j.id);
      final nid = int.tryParse(j.id);
      if (nid != null) await NotificationService.instance.cancel(nid);
    }
    
    // Fallback: forcefully clear room state in case AgentStore failed
    final m = MatrixService.instance;
    final rid = await m.pinRoomId();
    if (rid != null) {
      await m.saveListToRoom(rid, 'io.tokens2.reminders', []);
    }
    JobsController.instance.updateFromJson('[]');

    if (mounted) {
      PinToast.show(context, 'ลบ Reminders ทั้งหมดแล้ว');
      _refresh();
    }
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
        'io.tokens2.watches',
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

  /// All possible data sections in display order. Only the non-empty ones become
  /// tabs (ทั่วไป always shows); the label carries the row count so you see at a
  /// glance what's there. Tabs follow the data instead of a fixed list of 8.
  List<({String label, List<dynamic>? items})> _dataSections() => [
        (label: 'Watches', items: _storeRaw['io.tokens2.watches']),
        (label: 'Reminders', items: _storeRaw['io.tokens2.reminders']),
        (label: 'Tasks', items: _storeRaw['io.tokens2.tasks']),
        (label: 'Events', items: _storeRaw['io.tokens2.events']),
        (label: 'Files', items: _storeRaw['io.tokens2.files']),
        (
          label: 'Capabilities',
          items: _storeRaw['io.tokens2.capability_requests']
        ),
        (label: 'Facts', items: _memFacts),
        (label: 'Knowledge', items: _memKnow),
      ];

  @override
  Widget build(BuildContext context) {
    final m = MatrixService.instance;
    final p = PrefsController.instance.value;

    if (_loading) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: const Text('ข้อมูลห้องแชต / debug'),
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // ทั่วไป always present; data tabs only when they hold rows.
    final sections = _dataSections();
    final tabs = <Tab>[
      const Tab(text: 'ทั่วไป'),
      for (final s in sections) Tab(text: '${s.label} (${s.items?.length ?? 0})'),
    ];
    final views = <Widget>[
      _buildOverviewTab(m, p),
      for (final s in sections) _buildDataTable(s.items ?? []),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: const Text('ข้อมูลห้องแชต / debug'),
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          actions: [
            IconButton(
              icon: Icon(PhosphorIconsRegular.trash),
              tooltip: 'ลบ Reminders ทั้งหมด',
              onPressed: _clearReminders,
            ),
            IconButton(
              icon: Icon(PhosphorIconsRegular.arrowsClockwise),
              onPressed: _refresh,
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: tabs,
          ),
        ),
        body: TabBarView(children: views),
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

    final Set<String> keys = {};
    for (final item in items) {
      if (item is Map) {
        keys.addAll(item.keys.map((k) => k.toString()));
      }
    }
    
    if (keys.isEmpty) {
      return ListView.builder(
        itemCount: items.length,
        itemBuilder: (context, index) => ListTile(
          title: Text(items[index].toString(), style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
        ),
      );
    }

    final columns = keys.toList();
    
    // Format helper for human-readable values
    String _fmt(dynamic v) {
      if (v == null) return '—';
      if (v is num && v > 1000000000000) {
        // Likely ms timestamp
        final d = DateTime.fromMillisecondsSinceEpoch(v.toInt());
        return '${d.day}/${d.month} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
      }
      final s = v.toString();
      return s.length > 60 ? '${s.substring(0, 60)}…' : s;
    }

    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          dataRowMinHeight: 40,
          dataRowMaxHeight: 80,
          columnSpacing: 24,
          headingTextStyle: const TextStyle(fontWeight: FontWeight.bold, color: PinPalette.ink2, fontSize: 13),
          columns: columns.map((c) => DataColumn(label: Text(c))).toList(),
          rows: items.map((item) {
            final map = item is Map ? item : {};
            return DataRow(
              cells: columns.map((c) {
                final val = map[c];
                return DataCell(
                  Container(
                    constraints: const BoxConstraints(maxWidth: 240),
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      _fmt(val),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace', height: 1.3),
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
