import 'package:flutter/material.dart';

import '../agent/abilities.dart';
import '../agent/agent_config.dart';
import '../agent/catalog_client.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = CatalogClient(devProxy());
    final manifests = await client.fetchManifests();
    final cats = await client.fetchCategories();
    final items = [
      for (final m in manifests)
        if (m['kind'] != 'subagent') Ability.fromManifest(m)
    ].where((a) => !a.pricing.isFree).toList(); // PAID only
    if (!mounted) return;
    setState(() {
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

  Widget _cta(Ability a) {
    final soon = a.status == 'soon';
    final trial = a.status == 'trial';
    final word = soon
        ? 'เร็ว ๆ นี้'
        : trial
            ? 'ทดลองฟรี'
            : a.needsConnect
                ? 'เชื่อม'
                : a.pricing.tier == 'subscription'
                    ? 'สมัคร'
                    : 'ซื้อ';
    // Trial → "ฟรี" up top + the post-trial price as the button caption hint.
    final priceLabel = trial ? 'ฟรี' : a.pricing.label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(priceLabel,
            style: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 13.5, color: PinPalette.ink)),
        const SizedBox(height: 6),
        FilledButton.tonal(
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            backgroundColor: trial
                ? Theme.of(context).colorScheme.primary
                : soon
                    ? PinPalette.line
                    : null,
            foregroundColor: trial ? Colors.white : null,
          ),
          onPressed: soon
              ? null
              : () => PinToast.show(
                  context,
                  trial
                      ? 'เริ่มทดลองฟรี "${a.label}" — เปิดให้ใช้เร็ว ๆ นี้'
                      : 'เปิดให้ใช้เร็ว ๆ นี้ — บันทึกความสนใจไว้แล้ว'),
          child: Text(word),
        ),
      ],
    );
  }
}
