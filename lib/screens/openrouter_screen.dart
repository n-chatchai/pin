import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../agent/proxy_client.dart';
import '../services/ai_settings.dart';
import '../theme/pin_theme.dart';
import '../widgets/pin_button.dart';
import '../widgets/pin_field.dart';
import '../widgets/pin_toast.dart';

/// "Bring your own model" — let the user point ปิ่น at any OpenRouter model with
/// their own key. When on, the device calls OpenRouter directly (never our
/// proxy); the key is stored only on this device.
class OpenRouterScreen extends StatefulWidget {
  const OpenRouterScreen({super.key});

  @override
  State<OpenRouterScreen> createState() => _OpenRouterScreenState();
}

class _OpenRouterScreenState extends State<OpenRouterScreen> {
  late bool _on;
  late final TextEditingController _key;
  late final TextEditingController _model;
  bool _obscure = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final ai = AiSettings.instance.value;
    _on = ai.enabled;
    _key = TextEditingController(text: ai.key ?? '');
    _model = TextEditingController(text: ai.model);
  }

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  /// Live list of OpenRouter's free models (the `:free` collection). Public
  /// endpoint, no key needed. The set rotates, so we fetch instead of hardcode.
  Future<List<({String id, String name})>> _fetchFreeModels() async {
    final r = await http
        .get(Uri.parse('https://openrouter.ai/api/v1/models'))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return const [];
    final data = (jsonDecode(r.body)['data'] as List?) ?? const [];
    final free = <({String id, String name})>[];
    for (final m in data) {
      final id = '${(m as Map)['id']}';
      if (id.endsWith(':free')) {
        free.add((id: id, name: '${m['name'] ?? id}'));
      }
    }
    free.sort((a, b) => a.name.compareTo(b.name));
    return free;
  }

  /// Bottom sheet to pick a free model → fills the field + turns the feature on
  /// (the user still adds their free OpenRouter key + saves).
  void _pickFree() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: PinPalette.cream,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        builder: (_, scroll) => Column(
          children: [
            Container(
              width: 34,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              decoration: BoxDecoration(
                  color: PinPalette.line,
                  borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Text('โมเดลฟรีบน OpenRouter',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: PinPalette.ink)),
            ),
            Expanded(
              child: FutureBuilder<List<({String id, String name})>>(
                future: _fetchFreeModels(),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final list = snap.data ?? const [];
                  if (list.isEmpty) {
                    return const Center(child: Text('โหลดรายการไม่ได้'));
                  }
                  return ListView.builder(
                    controller: scroll,
                    itemCount: list.length,
                    itemBuilder: (_, i) => ListTile(
                      title: Text(list[i].name),
                      subtitle: Text(list[i].id,
                          style: const TextStyle(
                              fontSize: 11, fontFamily: 'monospace')),
                      onTap: () {
                        setState(() {
                          _model.text = list[i].id;
                          _on = true;
                        });
                        Navigator.of(context).pop();
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await AiSettings.instance.save(
      enabled: _on,
      key: _key.text,
      model: _model.text,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    final ai = AiSettings.instance.value;
    PinToast.show(
        context,
        ai.enabled
            ? 'ใช้ OpenRouter แล้ว · ${ai.model}'
            : 'ใช้โมเดลฟรีของปิ่น');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final off = !_on;
    return Scaffold(
      backgroundColor: PinPalette.cream,
      appBar: AppBar(
        backgroundColor: PinPalette.cream,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('โมเดลเอไอ',
            style: TextStyle(
                fontSize: 19, fontWeight: FontWeight.w600, color: PinPalette.ink)),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 8, 16, 24 + MediaQuery.of(context).viewPadding.bottom),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(PhosphorIconsRegular.cpu, color: PinPalette.ink),
            title: const Text('ใช้คีย์ OpenRouter ของฉัน',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: PinPalette.ink)),
            subtitle: const Text(
                'เลือกโมเดลเองผ่าน OpenRouter (เรียกตรง ไม่ผ่านปิ่น)',
                style: TextStyle(color: PinPalette.ink2)),
            value: _on,
            onChanged: (v) async {
              setState(() => _on = v);
              // Turning OFF reverts to free ปิ่น — atomic + safe, so apply it
              // immediately (no need to hit บันทึก just to go back to free).
              // The key/model stay stored, so turning it back on is one tap away.
              // Turning ON stays form-mode: it needs a key + model, saved via บันทึก.
              if (!v) {
                await AiSettings.instance.save(
                    enabled: false, key: _key.text, model: _model.text);
                if (mounted) PinToast.show(context, 'ใช้โมเดลฟรีของปิ่น');
              }
            },
          ),
          const SizedBox(height: 20),
          PinField(
            controller: _key,
            placeholder: 'OpenRouter API Key (sk-or-…)',
            icon: PhosphorIconsRegular.key,
            obscure: _obscure,
            enabled: _on,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: PinButton.text(
              _obscure ? 'แสดงคีย์' : 'ซ่อนคีย์',
              height: 38,
              onTap: off ? null : () => setState(() => _obscure = !_obscure),
            ),
          ),
          const SizedBox(height: 8),
          PinField(
            controller: _model,
            placeholder: ProxyClient.defaultOpenRouterModel,
            icon: PhosphorIconsRegular.cpu,
            enabled: _on,
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text('เช่น anthropic/claude-3.5-sonnet · openai/gpt-4o',
                style: TextStyle(fontSize: 12.5, color: PinPalette.ink2)),
          ),
          const SizedBox(height: 12),
          // Secondary action: tonal-accent pill, matching the app's other
          // secondary buttons (visible on cream, quieter than the save primary).
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _pickFree,
              icon: const Icon(PhosphorIconsRegular.gift, size: 18),
              label: const Text('เลือกโมเดลฟรี'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: accent,
                backgroundColor: accent.withValues(alpha: 0.08),
                side: BorderSide(color: accent.withValues(alpha: 0.40)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: accent.withValues(alpha: 0.16)),
            ),
            child: const Text(
              'โมเดลฟรียังต้องใช้คีย์ OpenRouter (สมัครฟรีได้ มีลิมิตการใช้). '
              'คีย์เก็บไว้ในเครื่องนี้เท่านั้น (ไม่ซิงก์ข้ามอุปกรณ์) และแอปจะเรียก '
              'OpenRouter โดยตรง ไม่ผ่านเซิร์ฟเวอร์ของปิ่น — เราจึงมองไม่เห็นคีย์'
              'หรือบทสนทนาในโหมดนี้.',
              style: TextStyle(
                  fontSize: 13, height: 1.5, color: PinPalette.ink),
            ),
          ),
          const SizedBox(height: 28),
          PinButton('บันทึก', busy: _saving, onTap: _save),
        ],
      ),
    );
  }
}
