import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

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
  // All known abilities, split by install type. `ของฉัน` vs `ร้านค้า` is then a
  // live partition over these by store state (so a toggle re-buckets instantly).
  List<Ability> _ready = const []; // toggle-on (built-in + catalog), default on
  List<Ability> _free = const []; //  opt-in free add-ons, default off
  List<Ability> _connect = const []; // need an account (Gmail/ปฏิทิน/…)
  List<Ability> _soon = const []; // paid teasers, not live yet
  final _freeNames = <String>{};
  final _soonNames = <String>{};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _store.load();
    final manifests = await CatalogClient(devProxy()).fetchManifests();
    // Subagents are internal (invoked via delegate) — not user-facing abilities.
    final fromCatalog = [
      for (final m in manifests)
        if (m['kind'] != 'subagent') Ability.fromManifest(m)
    ];
    final seen = <String>{};
    final ready = <Ability>[], connect = <Ability>[];
    for (final a in [...kBuiltinAbilities, ...fromCatalog]) {
      if (seen.add(a.name)) (a.needsConnect ? connect : ready).add(a);
    }
    final free = kFreeAbilities.where((a) => !seen.contains(a.name)).toList();
    final taken = {...seen, ...free.map((a) => a.name)};
    final soon = <Ability>[];
    for (final a in kComingSoonAbilities) {
      if (taken.contains(a.name)) continue;
      (a.needsConnect ? connect : soon).add(a); // email/ปฏิทิน → connect shelf
    }
    _ready = ready;
    _connect = connect;
    _free = free;
    _soon = soon;
    _freeNames
      ..clear()
      ..addAll(free.map((a) => a.name));
    _soonNames
      ..clear()
      ..addAll(soon.map((a) => a.name));
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    // ของฉัน = ready abilities left on + free add-ons the user added. Everything
    // else (ready turned off, free not added, connect, soon) is ร้านค้า.
    final mine = [
      ..._ready.where((a) => _store.isSkillOn(a.name)),
      ..._free.where((a) => _store.isAdded(a.name)),
    ];
    final shopReady = _ready.where((a) => !_store.isSkillOn(a.name));
    final shopFree = _free.where((a) => !_store.isAdded(a.name));
    final shop = [...shopReady, ...shopFree, ..._connect, ..._soon];
    final shopByCat = <String, List<Ability>>{};
    for (final a in shop) {
      shopByCat.putIfAbsent(a.category, () => []).add(a);
    }
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
              padding: EdgeInsets.fromLTRB(
                  16, 8, 16, 40 + MediaQuery.of(context).viewPadding.bottom),
              children: [
                if (mine.isNotEmpty) ...[
                  _label('ของฉัน · ใช้ได้เลย'),
                  _card([for (final a in mine) _readyRow(a)]),
                  const SizedBox(height: 22),
                ],
                _label('ร้านค้า'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                  child: Text('เพิ่มความสามารถใหม่ให้${botName} — ฟรี เชื่อมบัญชี หรือซื้อเพิ่ม',
                      style: const TextStyle(
                          color: PinPalette.ink2, fontSize: 13)),
                ),
                for (final cat in shopByCat.keys) ...[
                  _label(cat),
                  _card([for (final a in shopByCat[cat]!) _storeRow(a)]),
                  const SizedBox(height: 18),
                ],
              ],
            ),
    );
  }

  /// Pick the right store row for an ability by its install type.
  Widget _storeRow(Ability a) {
    if (_soonNames.contains(a.name)) return _soonRow(a);
    if (a.needsConnect) return _connectRow(a);
    if (_freeNames.contains(a.name)) return _freeRow(a);
    return _readyRow(a); // a ready ability the user turned off → toggle back on
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
              icon: const Icon(PhosphorIconsRegular.checkCircle),
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
