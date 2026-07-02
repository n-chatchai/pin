import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../agent/agent_config.dart';
import '../agent/catalog_client.dart';
import '../services/prefs.dart';
import '../theme/pin_theme.dart';

/// "บ้านปิ่น" — the family of น้อง (assistants ปิ่น hands work to): อุ่น/หยิบ/
/// ชั้น/ปั้น/หยอด. Read-only catalog; availability is admin-controlled (status
/// active / soon) so there's no per-user toggle to drift. Copy is canonical
/// (character bible) — sibling tag + quote come from the catalog metadata.
class AbilitiesScreen extends StatefulWidget {
  const AbilitiesScreen({super.key});

  @override
  State<AbilitiesScreen> createState() => _AbilitiesScreenState();
}

class _AbilitiesScreenState extends State<AbilitiesScreen> {
  List<Map<String, dynamic>> _items = const []; // assistants (from catalog)
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await CatalogClient(devProxy()).fetchAssistants();
    // Sort by sibling rank (order) so the house always reads eldest → youngest.
    items.sort((a, b) => ((a['order'] as num?)?.toInt() ?? 99)
        .compareTo((b['order'] as num?)?.toInt() ?? 99));
    if (!mounted) return;
    setState(() {
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
        title: Text('บ้าน$botName',
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: _houseHello(),
                  ),
                ),
                if (_items.isEmpty)
                  const SliverFillRemaining(
                    child: Center(
                      child: Text('ยังไม่มีใครในบ้าน',
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

  /// ปิ่น introduces the house — sets the "you talk to ปิ่น, น้อง help behind
  /// the scenes" mental model (character bible).
  Widget _houseHello() {
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 10, 13, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: PinPalette.line),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Text(
        'นี่บ้านของ$botNameเองนะ$userCall — น้อง ๆ ถนัดคนละเรื่อง '
        '${userCall}ไม่ต้องจำว่าใครทำอะไร บอก${botName}มาเหมือนเดิม '
        'เดี๋ยว${botName}ส่งต่อให้เอง',
        style: const TextStyle(fontSize: 12.5, height: 1.55, color: PinPalette.ink),
      ),
    );
  }

  Widget _card(Map<String, dynamic> a) {
    final primary = Theme.of(context).colorScheme.primary;
    final name = '${a['name']}';
    // Fill {ชื่อปิ่น}/{คำเรียกผู้ใช้} in the canonical catalog copy with the
    // user's persona (น้อง names + their own honorific stay literal).
    final label = personaFill('${a['label'] ?? name}');
    final desc = personaFill('${a['description'] ?? ''}');
    final sibling = personaFill('${a['sibling'] ?? ''}');
    final quote = personaFill('${a['quote'] ?? ''}');
    final handoff = '${a['interaction_mode'] ?? 'delegation'}' == 'handoff';
    // Admin is the single source: active = ready; soon/off both show as "เร็วๆนี้".
    final ready = '${a['status'] ?? 'active'}' == 'active';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PinPalette.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                color: primary.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(12)),
            child: Icon(_icon('${a['icon'] ?? ''}'), size: 22, color: primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                  Text(label,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
                  if (sibling.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(sibling,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11.5, color: PinPalette.ink3)),
                    ),
                  ],
                  if (ready) ...[
                    const SizedBox(width: 6),
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
                  const SizedBox(height: 3),
                  Text(desc,
                      style: const TextStyle(
                          color: PinPalette.ink2, fontSize: 12.5, height: 1.4)),
                ],
                if (quote.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(quote,
                      style: const TextStyle(
                          color: PinPalette.ink3,
                          fontSize: 12,
                          height: 1.5,
                          fontStyle: FontStyle.italic)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (!ready)
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
            Icon(PhosphorIconsFill.checkCircle, size: 24, color: primary),
        ],
      ),
    );
  }

  // Map an assistant's icon name (set in admin/metadata) to a Phosphor glyph —
  // one per use-case so cards don't all share the same icon. Falls back to a star.
  static IconData _icon(String n) {
    switch (n) {
      case 'briefcase':
        return PhosphorIconsRegular.briefcase;
      case 'books':
        return PhosphorIconsRegular.books;
      case 'graduationCap':
        return PhosphorIconsRegular.graduationCap;
      case 'house':
        return PhosphorIconsRegular.house;
      case 'penNib':
        return PhosphorIconsRegular.penNib;
      case 'storefront':
        return PhosphorIconsRegular.storefront;
      default:
        return PhosphorIconsRegular.sparkle;
    }
  }
}
