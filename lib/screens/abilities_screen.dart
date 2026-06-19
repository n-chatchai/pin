import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../agent/abilities.dart';
import '../agent/agent_config.dart';
import '../agent/agent_store.dart';
import '../agent/catalog_client.dart';
import '../services/prefs.dart';
import '../theme/pin_theme.dart';
import '../widgets/pin_toast.dart';

/// "ความสามารถของปิ่น" — plain-language capability screen. Hides all the
/// tool/skill/mcp/subagent machinery: users just see what ปิ่น can do, flip it
/// on/off, or connect an account.
class AbilitiesScreen extends StatefulWidget {
  const AbilitiesScreen({super.key});

  @override
  State<AbilitiesScreen> createState() => _AbilitiesScreenState();
}

class _AbilitiesScreenState extends State<AbilitiesScreen> {
  final _store = AgentStore();
  final _byCat = <String, List<Ability>>{};
  List<Ability> _free = const [];
  List<Ability> _soon = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _store.load();
    final manifests = await CatalogClient(devProxy()).fetchManifests();
    // Show every capability the server publishes (friendly copy where we have
    // it; otherwise fall back to the entry's own name/description).
    // Subagents are internal (invoked via delegate) — not user-facing abilities.
    final fromCatalog = [
      for (final m in manifests)
        if (m['kind'] != 'subagent') Ability.fromManifest(m)
    ];
    final all = [...kBuiltinAbilities, ...fromCatalog];
    // De-dup by name (built-in wins), then group by category.
    final seen = <String>{};
    _byCat.clear();
    for (final a in all) {
      if (seen.add(a.name)) {
        _byCat.putIfAbsent(a.category, () => []).add(a);
      }
    }
    // Free add-ons the user can switch on (skip any already live in catalog).
    _free = kFreeAbilities.where((a) => !seen.contains(a.name)).toList();
    // Coming-soon teasers, minus anything already live or free.
    final taken = {...seen, ..._free.map((a) => a.name)};
    _soon =
        kComingSoonAbilities.where((a) => !taken.contains(a.name)).toList();
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('ความสามารถของ$botName'),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 14),
                  child: Text('เปิดสิ่งที่อยากให้${botName}ช่วย ปิดอันที่ไม่ใช้ได้ตลอด',
                      style: const TextStyle(color: PinPalette.ink2, fontSize: 13)),
                ),
                for (final cat in _byCat.keys) ...[
                  _label(cat),
                  _card([
                    for (final a in _byCat[cat]!)
                      a.needsConnect ? _connectRow(a) : _readyRow(a)
                  ]),
                  const SizedBox(height: 18),
                ],
                if (_free.isNotEmpty) ...[
                  _label('ฟรี · เปิดเพิ่มเองได้'),
                  _card([for (final a in _free) _freeRow(a)]),
                  const SizedBox(height: 18),
                ],
                if (_soon.isNotEmpty) ...[
                  _label('มาเร็ว ๆ นี้'),
                  _card([for (final a in _soon) _soonRow(a)]),
                ],
              ],
            ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(t.toUpperCase(),
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                color: PinPalette.ink2)),
      );

  Widget _card(List<Widget> rows) {
    final out = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) {
        out.add(const Divider(height: 1, indent: 60, color: PinPalette.line));
      }
      out.add(rows[i]);
    }
    return Container(
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: out),
    );
  }

  Widget _leading(Ability a) => Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(10)),
        child: Icon(a.icon,
            size: 19, color: Theme.of(context).colorScheme.primary),
      );

  /// Blurb + where it comes from ("…  ·  ในแอป" / "เซิร์ฟเวอร์ปิ่น" / provider),
  /// plus provider attribution for hosted tools ("โดย Google").
  Widget _subtitle(Ability a) {
    final parts = <String>[
      a.blurb,
      a.sourceLabel,
      if (a.provider.isNotEmpty && a.source != 'mcp') 'โดย ${a.provider}',
    ];
    return Text(
      parts.where((s) => s.isNotEmpty).join(' · '),
      style: const TextStyle(color: PinPalette.ink2, fontSize: 12.5),
    );
  }

  Widget _readyRow(Ability a) {
    final on = _store.isSkillOn(a.name);
    return SwitchListTile(
      secondary: _leading(a),
      title: Text(a.label,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
      subtitle: _subtitle(a),
      value: on,
      onChanged: (v) async {
        await _store.setSkill(a.name, v);
        setState(() {});
      },
    );
  }

  Widget _freeRow(Ability a) {
    final added = _store.isAdded(a.name);
    return ListTile(
      leading: _leading(a),
      title: Text(a.label,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
      subtitle: _subtitle(a),
      trailing: added
          ? IconButton(
              icon: const Icon(LucideIcons.checkCircle),
              color: Theme.of(context).colorScheme.primary,
              tooltip: 'นำออก',
              onPressed: () async {
                await _store.setAdded(a.name, false);
                setState(() {});
              },
            )
          : FilledButton.tonal(
              onPressed: () async {
                await _store.setAdded(a.name, true);
                if (mounted) {
                  PinToast.show(context, 'เพิ่ม "${a.label}" แล้ว');
                  setState(() {});
                }
              },
              child: const Text('+ เพิ่ม'),
            ),
    );
  }

  Widget _soonRow(Ability a) => Opacity(
        opacity: 0.8,
        child: ListTile(
          leading: _leading(a),
          title: Text(a.label,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
          subtitle: _subtitle(a),
          trailing: FilledButton.tonal(
            onPressed: () =>
                PinToast.show(context, 'กำลังจะเปิดให้ใช้เร็ว ๆ นี้'),
            child: Text(a.pricing.tier == 'subscription'
                ? 'สมัคร · ${a.pricing.label}'
                : a.pricing.isFree
                    ? 'เร็ว ๆ นี้'
                    : 'ซื้อ · ${a.pricing.label}'),
          ),
        ),
      );

  Widget _connectRow(Ability a) => ListTile(
        leading: _leading(a),
        title: Text(a.label,
            style:
                const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
        subtitle: _subtitle(a),
        trailing: OutlinedButton(
          onPressed: () =>
              PinToast.show(context, 'การเชื่อมบัญชีกำลังจะมา เร็ว ๆ นี้'),
          child: Text(
              a.pricing.isFree ? 'เชื่อม' : 'เชื่อม · ${a.pricing.label}'),
        ),
      );
}
