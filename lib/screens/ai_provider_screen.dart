import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../services/ai_settings.dart';
import '../theme/pin_theme.dart';
import '../widgets/pin_button.dart';
import '../widgets/pin_field.dart';
import '../widgets/pin_toast.dart';

/// Pick the AI provider ปิ่น uses. 'ปิ่น' = the free built-in (our proxy). The
/// rest are "bring your own key": the device calls the provider DIRECTLY — the
/// key stays on this device only and never touches our servers.
class AiProviderScreen extends StatefulWidget {
  const AiProviderScreen({super.key});

  @override
  State<AiProviderScreen> createState() => _AiProviderScreenState();
}

class _Provider {
  final String id, name, desc, modelDefault, modelHint;
  final bool needsKey, needsBaseUrl, hasFreePicker, enabled;
  const _Provider(this.id, this.name, this.desc,
      {this.modelDefault = '',
      this.modelHint = '',
      this.needsKey = false,
      this.needsBaseUrl = false,
      this.hasFreePicker = false,
      this.enabled = true});
}

// OpenRouter / OpenAI-compatible / Claude are built but held back for now
// (enabled:false) — the adapter code stays; flip the flag to ship them.
const _providers = <_Provider>[
  _Provider('pin', 'ปิ่น', 'โมเดลฟรีของปิ่น — ไม่ต้องตั้งค่าอะไร'),
  _Provider('gemini', 'Gemini', 'คีย์ Google AI Studio',
      needsKey: true,
      modelDefault: 'gemini-2.0-flash',
      modelHint: 'เช่น gemini-2.0-flash · gemini-1.5-pro'),
  _Provider('openrouter', 'OpenRouter', 'คีย์ OpenRouter · โมเดลอะไรก็ได้',
      needsKey: true,
      modelDefault: 'openai/gpt-4o',
      modelHint: 'เช่น anthropic/claude-3.5-sonnet · openai/gpt-4o',
      hasFreePicker: true,
      enabled: false),
  _Provider('openai', 'OpenAI-compatible', 'ใส่ endpoint เอง (OpenAI/Groq/Ollama/…)',
      needsKey: true,
      needsBaseUrl: true,
      modelDefault: 'gpt-4o-mini',
      modelHint: 'ชื่อโมเดลตามผู้ให้บริการ',
      enabled: false),
  _Provider('claude', 'Claude', 'คีย์ Anthropic',
      needsKey: true,
      modelDefault: 'claude-3-5-sonnet-latest',
      modelHint: 'เช่น claude-3-5-sonnet-latest',
      enabled: false),
];

class _AiProviderScreenState extends State<AiProviderScreen> {
  late String _provider;
  final _key = TextEditingController();
  final _model = TextEditingController();
  final _baseUrl = TextEditingController();
  bool _obscure = true, _saving = false;

  @override
  void initState() {
    super.initState();
    final ai = AiSettings.instance.value;
    _provider = ai.provider;
    _key.text = ai.key ?? '';
    _model.text = ai.model;
    _baseUrl.text = ai.baseUrl ?? '';
  }

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    _baseUrl.dispose();
    super.dispose();
  }

  _Provider get _p => _providers.firstWhere((p) => p.id == _provider,
      orElse: () => _providers.first);

  void _select(String id) {
    setState(() {
      _provider = id;
      final p = _providers.firstWhere((x) => x.id == id);
      // Seed a sensible default model when switching to an empty/foreign one.
      if (p.modelDefault.isNotEmpty && _model.text.trim().isEmpty) {
        _model.text = p.modelDefault;
      }
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await AiSettings.instance.save(
      provider: _provider,
      key: _key.text,
      model: _model.text,
      baseUrl: _baseUrl.text,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    PinToast.show(context, 'ใช้ ${AiSettings.instance.value.label}');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final p = _p;
    return Scaffold(
      backgroundColor: PinPalette.cream,
      appBar: AppBar(
        backgroundColor: PinPalette.cream,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('ผู้ให้บริการเอไอ',
            style: TextStyle(
                fontSize: 19, fontWeight: FontWeight.w600, color: PinPalette.ink)),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 8, 16, 24 + MediaQuery.of(context).viewPadding.bottom),
        children: [
          // Provider chooser.
          Container(
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: PinPalette.line)),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < _providers.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, thickness: 1, color: PinPalette.line),
                  RadioListTile<String>(
                    value: _providers[i].id,
                    groupValue: _provider,
                    // Disabled providers are visible but not selectable yet.
                    onChanged:
                        _providers[i].enabled ? (v) => _select(v!) : null,
                    activeColor: accent,
                    controlAffinity: ListTileControlAffinity.trailing,
                    title: Text(_providers[i].name,
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: _providers[i].enabled
                                ? PinPalette.ink
                                : PinPalette.ink3)),
                    subtitle: Text(
                        _providers[i].enabled
                            ? _providers[i].desc
                            : '${_providers[i].desc} · เร็วๆนี้',
                        style: const TextStyle(
                            fontSize: 12.5, color: PinPalette.ink3)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),

          // Config fields for the chosen provider.
          if (p.needsBaseUrl) ...[
            PinField(
              controller: _baseUrl,
              placeholder: 'Base URL (เช่น https://api.openai.com/v1)',
              icon: PhosphorIconsRegular.link,
            ),
            const SizedBox(height: 8),
          ],
          if (p.needsKey) ...[
            PinField(
              controller: _key,
              placeholder: 'API Key',
              icon: PhosphorIconsRegular.key,
              obscure: _obscure,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: PinButton.text(_obscure ? 'แสดงคีย์' : 'ซ่อนคีย์',
                  height: 38, onTap: () => setState(() => _obscure = !_obscure)),
            ),
            const SizedBox(height: 8),
            PinField(
              controller: _model,
              placeholder: p.modelDefault,
              icon: PhosphorIconsRegular.cpu,
            ),
            if (p.modelHint.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Text(p.modelHint,
                    style: const TextStyle(fontSize: 12.5, color: PinPalette.ink2)),
              ),
          ],
          if (p.hasFreePicker) ...[
            const SizedBox(height: 12),
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
                  shape:
                      RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
          ],
          if (p.id != 'pin') ...[
            const SizedBox(height: 22),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: accent.withValues(alpha: 0.16)),
              ),
              child: const Text(
                'คีย์เก็บไว้ในเครื่องนี้เท่านั้น (ไม่ซิงก์ข้ามอุปกรณ์) และแอปจะเรียก '
                'ผู้ให้บริการโดยตรง ไม่ผ่านเซิร์ฟเวอร์ของปิ่น — เราจึงมองไม่เห็น'
                'คีย์หรือบทสนทนาในโหมดนี้.',
                style: TextStyle(fontSize: 13, height: 1.5, color: PinPalette.ink),
              ),
            ),
          ],
          const SizedBox(height: 28),
          PinButton('บันทึก', busy: _saving, onTap: _save),
        ],
      ),
    );
  }

  // --- OpenRouter free-model picker (public list, no key needed) ---
  Future<List<({String id, String name})>> _fetchFreeModels() async {
    final r = await http
        .get(Uri.parse('https://openrouter.ai/api/v1/models'))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) return const [];
    final data = (jsonDecode(r.body)['data'] as List?) ?? const [];
    final free = <({String id, String name})>[];
    for (final m in data) {
      final id = '${(m as Map)['id']}';
      if (id.endsWith(':free')) free.add((id: id, name: '${m['name'] ?? id}'));
    }
    free.sort((a, b) => a.name.compareTo(b.name));
    return free;
  }

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
                        setState(() => _model.text = list[i].id);
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
}
