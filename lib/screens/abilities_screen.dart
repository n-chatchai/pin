import 'package:flutter/material.dart';

import '../agent/abilities.dart';
import '../agent/agent_config.dart';
import '../agent/catalog_client.dart';
import '../services/matrix_service.dart';
import '../services/prefs.dart';
import '../theme/pin_theme.dart';
import '../widgets/pin_toast.dart';

/// "ร้านความสามารถ" — the PAID store. Only capabilities a bare LLM can't do
/// (ดูดวง, account connects, …); built-in/free things ปิ่น does aren't here.
/// Layout: title · category filter chips (from the admin catalog API) · cards.
class AbilitiesScreen extends StatefulWidget {
  const AbilitiesScreen({super.key});

  @override
  State<AbilitiesScreen> createState() => _AbilitiesScreenState();
}

class _AbilitiesScreenState extends State<AbilitiesScreen> {
  List<Ability> _items = const []; // paid capabilities only
  List<Map<String, dynamic>> _cats = const []; // [{id,label,count}]
  String? _sel; // selected category id; null = ทั้งหมด
  bool _loading = true;
  String? _roomId;
  Set<String> _optedOut = {}; // capabilities the user turned off (opt-out model)

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


    final client = CatalogClient(devProxy());
    final manifests = await client.fetchManifests();
    final cats = await client.fetchCategories();
    final items = [
      for (final m in manifests)
        if (m['kind'] != 'subagent') Ability.fromManifest(m)
    ].where((a) => !a.pricing.isFree).toList(); // PAID only
    if (!mounted) return;
    setState(() {
      _roomId = roomId;
      _optedOut = rawList.map((e) => '${e['name']}').toSet();
      _items = items;
      _cats = cats;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final shown = _sel == null
        ? _items
        : _items.where((a) => a.category == _sel).toList();
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 20,
        title: const Text('ร้านความสามารถ',
            style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Text('เพิ่มสิ่งที่$botNameทำเองไม่ได้ — เชื่อมบัญชี ดูดวง และอื่น ๆ',
                        style: const TextStyle(
                            color: PinPalette.ink2, fontSize: 13.5)),
                  ),
                ),
                if (_cats.isNotEmpty)
                  SliverToBoxAdapter(child: _chips()),
                if (shown.isEmpty)
                  const SliverFillRemaining(
                    child: Center(
                      child: Text('ยังไม่มีสินค้าในหมวดนี้',
                          style: TextStyle(color: PinPalette.ink2)),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                        16, 4, 16, 32 + MediaQuery.of(context).viewPadding.bottom),
                    sliver: SliverList.builder(
                      itemCount: shown.length,
                      itemBuilder: (_, i) => _card(shown[i]),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _chips() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        children: [
          _chip('ทั้งหมด', _sel == null, () => setState(() => _sel = null)),
          for (final c in _cats)
            _chip('${c['label']}', _sel == c['id'],
                () => setState(() => _sel = '${c['id']}')),
        ],
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: on,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        labelStyle: TextStyle(
            color: on ? Colors.white : PinPalette.ink,
            fontWeight: FontWeight.w600,
            fontSize: 13.5),
        selectedColor: primary,
        backgroundColor: Colors.white,
        side: BorderSide(color: on ? primary : PinPalette.line),
        shape: const StadiumBorder(),
      ),
    );
  }

  Widget _card(Ability a) {
    final primary = Theme.of(context).colorScheme.primary;
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
            child: Icon(a.icon, size: 22, color: primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(a.label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 2),
                Text(
                  [a.blurb, if (a.provider.isNotEmpty) 'โดย ${a.provider}']
                      .where((s) => s.isNotEmpty)
                      .join(' · '),
                  style: const TextStyle(color: PinPalette.ink2, fontSize: 12.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _cta(a),
        ],
      ),
    );
  }

  // Fixed CTA width so every card's trailing control lines up (and the trial
  // toggle doesn't change width when its label flips on↔off).
  static const double _ctaWidth = 116;

  Widget _cta(Ability a) {
    final soon = a.status == 'soon';
    final trial = a.status == 'trial';
    final primary = Theme.of(context).colorScheme.primary;

    // Trial = opt-out, on by default. A plain switch (like the ดีบักบอท toggle)
    // — clearest on/off, and its width is fixed so cards line up.
    if (trial) {
      final on = !_optedOut.contains(a.name);
      return Column(
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
            onChanged: (_) => _toggleTrial(a, on),
          ),
        ],
      );
    }

    final word = soon
        ? 'เร็ว ๆ นี้'
        : a.needsConnect
            ? 'เชื่อม'
            : a.pricing.tier == 'subscription'
                ? 'สมัคร'
                : 'ซื้อ';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(a.pricing.label,
            style: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 13.5, color: PinPalette.ink)),
        const SizedBox(height: 6),
        SizedBox(
          width: _ctaWidth,
          child: FilledButton.tonal(
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              backgroundColor: soon ? PinPalette.line : null,
            ),
            onPressed: soon
                ? null
                : () => PinToast.show(
                    context, 'เปิดให้ใช้เร็ว ๆ นี้ — บันทึกความสนใจไว้แล้ว'),
            child: Text(word),
          ),
        ),
      ],
    );
  }

  Future<void> _toggleTrial(Ability a, bool currentlyOn) async {
    if (_roomId == null) return;
    setState(() {
      if (currentlyOn) {
        _optedOut.add(a.name); // turn off (opt out)
      } else {
        _optedOut.remove(a.name); // turn on
      }
    });
    await MatrixService.instance.saveListToRoom(
        _roomId!,
        'io.tokens2.opted_out_capabilities',
        _optedOut.map((e) => {'name': e}).toList());
    // Live chat session + composer reload now (drops ดูดวง this turn, not 30s).
    capabilitiesRevision.value++;
    if (!mounted) return;
    PinToast.show(
        context,
        currentlyOn
            ? 'ปิด "${a.label}" แล้ว — $botNameจะไม่เรียกใช้'
            : 'เปิดใช้ "${a.label}" แล้ว');
  }
}
