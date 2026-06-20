import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../agent/agent_config.dart';
import '../services/prefs.dart';
import '../theme/pin_theme.dart';
import '../widgets/pin_toast.dart';

/// Settings → "บุคลิกพิเศษ": opt-in role-play personas (friend / butler / mom /
/// cute / custom). Applying one overlays how ปิ่น addresses you + its voice; it
/// stays the working assistant. Mirrors design/chat-onboarding/pin-special-personas.html.
class SpecialPersonasScreen extends StatefulWidget {
  final Future<void> Function(PinPrefs) onSave;
  const SpecialPersonasScreen({super.key, required this.onSave});

  @override
  State<SpecialPersonasScreen> createState() => _SpecialPersonasScreenState();
}

class _SpecialPersonasScreenState extends State<SpecialPersonasScreen> {
  static const _icons = {
    'friend': PhosphorIconsRegular.users,
    'butler': PhosphorIconsRegular.crown,
    'mom': PhosphorIconsRegular.house,
    'cute': PhosphorIconsRegular.heart,
  };

  final _cuCall = TextEditingController();
  final _cuSelf = TextEditingController();
  bool _customOpen = false;

  @override
  void initState() {
    super.initState();
    final p = PrefsController.instance.value;
    if (p.personaMode == 'custom') {
      _cuCall.text = p.customCall;
      _cuSelf.text = p.customSelf;
      _customOpen = true;
    }
  }

  @override
  void dispose() {
    _cuCall.dispose();
    _cuSelf.dispose();
    super.dispose();
  }

  void _apply(String mode, String name, {String? call, String? self}) {
    final p = PrefsController.instance.value;
    widget.onSave(p.copyWith(
      personaMode: mode,
      customCall: call ?? p.customCall,
      customSelf: self ?? p.customSelf,
    ));
    PinToast.show(context, 'เปิดบุคลิก "$name" แล้ว');
  }

  void _revert() {
    final p = PrefsController.instance.value;
    widget.onSave(p.copyWith(personaMode: 'basic'));
    PinToast.show(context, 'กลับเป็นบุคลิกปกติแล้ว');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: PinPalette.cream,
      appBar: AppBar(
        backgroundColor: PinPalette.cream,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('บุคลิกพิเศษ',
            style: TextStyle(
                fontSize: 19, fontWeight: FontWeight.w600, color: PinPalette.ink)),
      ),
      body: ValueListenableBuilder<PinPrefs>(
        valueListenable: PrefsController.instance,
        builder: (context, p, _) {
          final active = p.personaMode;
          return ListView(
            padding: EdgeInsets.fromLTRB(
                16, 8, 16, 24 + MediaQuery.of(context).viewPadding.bottom),
            children: [
              const Text(
                  'เปลี่ยนผู้ช่วยให้สวมบทตัวละคร — เปลี่ยนแค่คำเรียกและน้ำเสียง '
                  'ยังช่วยงานเหมือนเดิม เปิด/ปิดทีหลังได้ตลอด',
                  style: TextStyle(
                      fontSize: 14, height: 1.5, color: PinPalette.ink2)),
              const SizedBox(height: 16),
              if (active != 'basic') _activeBar(context, p),
              for (final sp in kSpecialPersonas)
                _personaCard(context, sp, active == sp.key),
              _customCard(context, scheme, active == 'custom'),
            ],
          );
        },
      ),
    );
  }

  Widget _activeBar(BuildContext context, PinPrefs p) {
    final scheme = Theme.of(context).colorScheme;
    final name = p.personaMode == 'custom'
        ? 'กำหนดเอง'
        : (specialPersona(p.personaMode)?.name ?? p.personaMode);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(PhosphorIconsRegular.sparkle, size: 20, color: scheme.secondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(TextSpan(
                style: const TextStyle(fontSize: 14.5, color: PinPalette.ink),
                children: [
                  const TextSpan(text: 'กำลังใช้ '),
                  TextSpan(
                      text: name,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ])),
          ),
          GestureDetector(
            onTap: _revert,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: scheme.primary.withValues(alpha: 0.4)),
              ),
              child: Text('กลับเป็นปกติ',
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.secondary)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _personaCard(BuildContext context, SpecialPersona sp, bool on) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: on ? null : () => _apply(sp.key, sp.name),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: on ? scheme.primary : PinPalette.line,
              width: on ? 1.8 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(14)),
                  child: Icon(_icons[sp.key] ?? PhosphorIconsRegular.user,
                      size: 24, color: scheme.secondary),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(sp.name,
                          style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: PinPalette.ink)),
                      const SizedBox(height: 2),
                      Text(sp.sub,
                          style: const TextStyle(
                              fontSize: 13, color: PinPalette.ink2)),
                    ],
                  ),
                ),
                if (on)
                  Icon(PhosphorIconsFill.checkCircle,
                      size: 24, color: scheme.primary),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                  color: const Color(0xFFF6F8F6),
                  borderRadius: BorderRadius.circular(12)),
              child: Text('"${sp.sample}"',
                  style: const TextStyle(
                      fontSize: 14.5,
                      fontStyle: FontStyle.italic,
                      color: Color(0xFF3A443E))),
            ),
          ],
        ),
      ),
    );
  }

  Widget _customCard(BuildContext context, ColorScheme scheme, bool on) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: on ? scheme.primary : PinPalette.line, width: on ? 1.8 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => setState(() => _customOpen = !_customOpen),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                      color: const Color(0xFFEEF1F5),
                      borderRadius: BorderRadius.circular(14)),
                  child: const Icon(PhosphorIconsRegular.pencilSimple,
                      size: 22, color: Color(0xFF5A665E)),
                ),
                const SizedBox(width: 13),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('กำหนดเอง',
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: PinPalette.ink)),
                      SizedBox(height: 2),
                      Text('เลือกคำเรียก 2 ฝั่งด้วยตัวเอง',
                          style:
                              TextStyle(fontSize: 13, color: PinPalette.ink2)),
                    ],
                  ),
                ),
                Icon(
                    _customOpen
                        ? PhosphorIconsRegular.caretUp
                        : PhosphorIconsRegular.caretDown,
                    size: 18,
                    color: PinPalette.ink3),
              ],
            ),
          ),
          if (_customOpen) ...[
            const SizedBox(height: 14),
            const Divider(color: PinPalette.line, height: 1),
            const SizedBox(height: 14),
            _cuField('ให้เรียกคุณว่า', _cuCall, 'เช่น เจ้านาย, พี่, มิ้น'),
            const SizedBox(height: 12),
            _cuField('ผู้ช่วยแทนตัวเองว่า', _cuSelf, 'เช่น หนู, เรา, ชื่อผู้ช่วย'),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: () {
                  final u = _cuCall.text.trim(), s = _cuSelf.text.trim();
                  if (u.isEmpty || s.isEmpty) {
                    PinToast.show(context, 'กรอกคำเรียกให้ครบทั้ง 2 ช่อง');
                    return;
                  }
                  _apply('custom', 'กำหนดเอง', call: u, self: s);
                },
                style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(13))),
                child: const Text('เปิดใช้',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _cuField(String label, TextEditingController c, String hint) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 13, color: PinPalette.ink2)),
          const SizedBox(height: 5),
          TextField(
            controller: c,
            maxLength: 14,
            style: const TextStyle(fontSize: 16, color: PinPalette.ink),
            decoration: InputDecoration(
              hintText: hint,
              counterText: '',
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
              filled: true,
              fillColor: const Color(0xFFFAFBFA),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: PinPalette.line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                    color: Theme.of(context).colorScheme.primary, width: 1.5),
              ),
            ),
          ),
        ],
      );
}
