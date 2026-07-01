import 'package:flutter/material.dart';

import '../agent/abilities.dart' show capabilitiesRevision;
import '../agent/agent_config.dart';
import '../agent/catalog_client.dart';
import '../services/matrix_service.dart';
import '../services/prefs.dart';
import '../theme/pin_theme.dart';
import '../widgets/pin_toast.dart';

/// "ผู้ช่วย" — the assistants (ผู้ช่วยเฉพาะทาง) the user can turn on for $botName
/// to use: นักวิจัย, ผู้ช่วยช้อป, ติวเตอร์ … Delegation ones $botName uses behind
/// the scenes; handoff ones the user can talk to directly. Plumbing (tools /
/// skills / connectors) is hidden — that's admin-only.
class AbilitiesScreen extends StatefulWidget {
  const AbilitiesScreen({super.key});

  @override
  State<AbilitiesScreen> createState() => _AbilitiesScreenState();
}

class _AbilitiesScreenState extends State<AbilitiesScreen> {
  List<Map<String, dynamic>> _items = const []; // assistants
  bool _loading = true;
  String? _roomId;
  Set<String> _optedOut = {}; // assistants the user turned off

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final roomId = await MatrixService.instance.pinRoomId();
    final rawList = roomId != null
        ? await MatrixService.instance
            .loadListFromRoom(roomId, 'io.tokens2.opted_out_capabilities')
        : [];
    final items = await CatalogClient(devProxy()).fetchAssistants();
    if (!mounted) return;
    setState(() {
      _roomId = roomId;
      _optedOut = rawList.map((e) => '${e['name']}').toSet();
      _items = items;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 20,
        title: Text('ทีมของ$botName',
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Text(
                        'คนเก่ง ๆ ที่$botNameเรียกมาช่วยเรื่องที่ถนัด — ติว ดูแลบ้าน ครีเอทีฟ',
                        style: const TextStyle(
                            color: PinPalette.ink2, fontSize: 13.5)),
                  ),
                ),
                if (_items.isEmpty)
                  const SliverFillRemaining(
                    child: Center(
                      child: Text('ยังไม่มีใครในทีม',
                          style: TextStyle(color: PinPalette.ink2)),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16,
                        32 + MediaQuery.of(context).viewPadding.bottom),
                    sliver: SliverList.builder(
                      itemCount: _items.length,
                      itemBuilder: (_, i) => _card(_items[i]),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _card(Map<String, dynamic> a) {
    final primary = Theme.of(context).colorScheme.primary;
    final name = '${a['name']}';
    final label = '${a['label'] ?? name}';
    final desc = '${a['description'] ?? ''}';
    final handoff = '${a['interaction_mode'] ?? 'delegation'}' == 'handoff';
    final soon = '${a['status'] ?? 'active'}' == 'soon';
    final on = !_optedOut.contains(name);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PinPalette.line),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                color: primary.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(12)),
            child: Icon(handoff ? Icons.forum_outlined : Icons.auto_awesome,
                size: 22, color: primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(label,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                  ),
                  if (!soon) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 1),
                      decoration: BoxDecoration(
                          color: PinPalette.line,
                          borderRadius: BorderRadius.circular(9)),
                      child: Text(handoff ? 'คุยตรง' : 'ช่วยเบื้องหลัง',
                          style: const TextStyle(
                              fontSize: 11, color: PinPalette.ink2)),
                    ),
                  ],
                ]),
                if (desc.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(desc,
                      style: const TextStyle(
                          color: PinPalette.ink2, fontSize: 12.5)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (soon)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                  color: PinPalette.line,
                  borderRadius: BorderRadius.circular(20)),
              child: const Text('เร็วๆนี้',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: PinPalette.ink3)),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(on ? 'เปิดอยู่' : 'ปิดอยู่',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: on ? primary : PinPalette.ink3)),
                Switch.adaptive(
                  value: on,
                  activeTrackColor: primary,
                  onChanged: (_) => _toggle(name, label, on),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _toggle(String name, String label, bool currentlyOn) async {
    if (_roomId == null) return;
    setState(() {
      if (currentlyOn) {
        _optedOut.add(name);
      } else {
        _optedOut.remove(name);
      }
    });
    await MatrixService.instance.saveListToRoom(
        _roomId!,
        'io.tokens2.opted_out_capabilities',
        _optedOut.map((e) => {'name': e}).toList());
    capabilitiesRevision.value++;
    if (!mounted) return;
    PinToast.show(
        context,
        currentlyOn
            ? 'ปิด "$label" แล้ว — $botNameจะไม่เรียกใช้'
            : 'เปิดใช้ "$label" แล้ว');
  }
}
