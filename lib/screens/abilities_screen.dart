import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../agent/agent_config.dart';
import '../agent/catalog_client.dart';
import '../services/prefs.dart';
import '../theme/pin_theme.dart';

/// "ทีม$botName" — the assistants (specialist helpers) $botName can call on:
/// ติวและทบทวน, ดูแลบ้าน, งานครีเอทีฟ … Availability is admin-controlled (status
/// active / soon); the app just reflects it, so there's no per-user toggle to
/// drift out of sync. Plumbing (tools / skills / connectors) stays admin-only.
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
        title: Text('ทีม$botName',
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Text('หาคนช่วย$botName',
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
                Row(children: [
                  Flexible(
                    child: Text(label,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                  ),
                  if (ready) ...[
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
