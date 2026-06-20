import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../services/prefs.dart';
import '../theme/pin_theme.dart';
import '../widgets/pin_toast.dart';

/// Settings → "บุคลิกของผู้ช่วย": edit the persona with a LIVE preview of how ปิ่น
/// will speak. Mirrors design/chat-onboarding/pin-settings-personality.html.
/// On save, persists to prefs + the ปิ่น room (via [onSave]).
class PersonalityScreen extends StatefulWidget {
  /// Persist a changed persona (settings_screen wires this to _updatePersona,
  /// which writes prefs + room state).
  final Future<void> Function(PinPrefs) onSave;
  const PersonalityScreen({super.key, required this.onSave});

  @override
  State<PersonalityScreen> createState() => _PersonalityScreenState();
}

class _PersonalityScreenState extends State<PersonalityScreen> {
  static const _tones = ['male', 'female', 'casual', 'neutral'];
  static const _toneLabel = {
    'male': 'สุภาพ (ครับ)',
    'female': 'สุภาพ (ค่ะ)',
    'casual': 'เป็นกันเอง (จ๊ะ)',
    'neutral': 'เป็นกลาง',
  };

  late final TextEditingController _asst;
  late final TextEditingController _user;
  late String _tone;
  String? _addr; // userCall; null = first option
  String? _selfKey; // name|pee|nong|noo; null = auto-suggest

  @override
  void initState() {
    super.initState();
    final p = PrefsController.instance.value;
    _asst = TextEditingController(text: p.pinName);
    _user = TextEditingController(text: p.userName);
    _tone = p.tone;
    _addr = p.userCall.isEmpty ? null : p.userCall;
    _selfKey = _keyForSelf(p.pinSelf, p.pinName);
  }

  @override
  void dispose() {
    _asst.dispose();
    _user.dispose();
    super.dispose();
  }

  // ----- persona logic (mirrors the prototype) -----
  String get _userName => _user.text.trim().isEmpty ? 'คุณ' : _user.text.trim();
  String get _asstName => _asst.text.trim().isEmpty ? 'ผู้ช่วย' : _asst.text.trim();

  List<String> _addrOptions() {
    final n = _userName;
    switch (_tone) {
      case 'casual':
        return [n, 'แก', 'นาย', 'เพื่อน'];
      case 'neutral':
        return [n, 'คุณ$n'];
      default:
        return [n, 'คุณ$n', 'พี่$n', 'น้อง$n'];
    }
  }

  String get _addrValue => _addr ?? _addrOptions().first;

  /// The address tells the assistant's role → its default self-reference.
  String _suggestSelfKey() {
    final a = _addrValue;
    if (a.startsWith('พี่')) return 'nong'; // user senior → bot junior
    if (a.startsWith('น้อง')) return 'pee'; // user junior → bot senior
    return 'name';
  }

  List<({String k, String label})> _selfOptions() => [
        (k: 'name', label: _asstName),
        (k: 'pee', label: 'พี่$_asstName'),
        (k: 'nong', label: 'น้อง$_asstName'),
        (k: 'noo', label: 'หนู'),
      ];

  String get _selfKeyEff => _selfKey ?? _suggestSelfKey();

  String _selfDisplay() {
    switch (_selfKeyEff) {
      case 'pee':
        return 'พี่$_asstName';
      case 'nong':
        return 'น้อง$_asstName';
      case 'noo':
        return 'หนู';
      default:
        return _asstName;
    }
  }

  // Reverse: a stored pinSelf string → its option key (for initial selection).
  String? _keyForSelf(String self, String name) {
    if (self == 'หนู') return 'noo';
    if (self == 'พี่$name') return 'pee';
    if (self == 'น้อง$name') return 'nong';
    if (self == name) return 'name';
    return null; // custom → fall back to auto
  }

  void _save() {
    final p = PrefsController.instance.value;
    widget.onSave(p.copyWith(
      pinName: _asstName,
      userName: _user.text.trim(),
      tone: _tone,
      pinEnding: toneParticle(_tone),
      userCall: _addrValue,
      pinSelf: _selfDisplay(),
    ));
    PinToast.show(context, 'บันทึกบุคลิกแล้ว');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final particle = toneParticle(_tone);
    final call = _addrValue;
    final self = _selfDisplay();
    return Scaffold(
      backgroundColor: PinPalette.cream,
      appBar: AppBar(
        backgroundColor: PinPalette.cream,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('บุคลิกของผู้ช่วย',
            style: TextStyle(
                fontSize: 19, fontWeight: FontWeight.w600, color: PinPalette.ink)),
      ),
      body: ListView(
        // + the system nav-bar inset (3-button bar / gesture pill / none) so the
        // last control clears it under Android edge-to-edge.
        padding: EdgeInsets.fromLTRB(
            16, 8, 16, 24 + MediaQuery.of(context).viewPadding.bottom),
        children: [
          // Live preview.
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(PhosphorIconsRegular.sparkle, size: 14, color: scheme.secondary),
                  const SizedBox(width: 6),
                  Text('ตัวอย่างการพูด',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: scheme.secondary)),
                ]),
                const SizedBox(height: 12),
                _previewBubble('${self}ตั้งเตือนให้$call'
                    'แล้ว${particle.isEmpty ? '' : particle}'),
                const SizedBox(height: 8),
                _previewBubble(
                    'สวัสดี$call ${self}พร้อมช่วยแล้ว${particle.isEmpty ? '' : particle}'),
              ],
            ),
          ),
          const SizedBox(height: 22),
          _label('ชื่อผู้ช่วย'),
          _field(_asst, onChanged: (_) => setState(() {})),
          const SizedBox(height: 18),
          _label('ชื่อของคุณ'),
          _field(_user,
              sub: 'ใช้สร้างตัวเลือกคำเรียกด้านล่าง',
              onChanged: (_) => setState(() => _addr = null)),
          const SizedBox(height: 18),
          _label('น้ำเสียง'),
          _toneGrid(scheme),
          const SizedBox(height: 18),
          _label('ให้เรียกคุณว่า'),
          _card(Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _pills(_addrOptions(), _addrValue,
                  (o) => setState(() {
                        _addr = o;
                        _selfKey = null;
                      })),
              if (_roleHint() != null) ...[
                const SizedBox(height: 10),
                _roleHint()!,
              ],
            ],
          )),
          const SizedBox(height: 18),
          _label('ผู้ช่วยแทนตัวเองว่า'),
          _card(Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _pills([for (final o in _selfOptions()) o.label], _selfDisplayLabel(),
                  (label) => setState(() => _selfKey = _keyForLabel(label))),
              const SizedBox(height: 8),
              const Text('ปรับอัตโนมัติตามคำเรียก แต่เปลี่ยนเองได้',
                  style: TextStyle(fontSize: 12.5, color: PinPalette.ink2)),
            ],
          )),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton(
              onPressed: _save,
              style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16))),
              child: const Text('บันทึก',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  String _selfDisplayLabel() {
    // The currently-selected self option's display label (to mark the pill).
    final k = _selfKeyEff;
    return _selfOptions().firstWhere((o) => o.k == k).label;
  }

  String? _keyForLabel(String label) =>
      _selfOptions().where((o) => o.label == label).map((o) => o.k).firstOrNull;

  Widget? _roleHint() {
    final a = _addrValue;
    String? role;
    if (a.startsWith('พี่')) role = 'น้อง';
    if (a.startsWith('น้อง')) role = 'พี่';
    if (role == null) return null;
    return Text.rich(
      TextSpan(
        style: const TextStyle(fontSize: 12.5, color: PinPalette.ink2),
        children: [
          TextSpan(text: 'เรียกคุณว่า "$a" → ผู้ช่วยจะวางตัวเป็น '),
          TextSpan(
              text: role,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.secondary,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  // ----- small UI helpers -----
  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(t,
            style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: PinPalette.ink2)),
      );

  Widget _card(Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: PinPalette.line),
        ),
        child: child,
      );

  Widget _field(TextEditingController c,
          {String? sub, required ValueChanged<String> onChanged}) =>
      _card(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: c,
            onChanged: onChanged,
            maxLength: 20,
            style: const TextStyle(fontSize: 17, color: PinPalette.ink),
            decoration: const InputDecoration(
              isDense: true,
              counterText: '',
              border: InputBorder.none,
            ),
          ),
          if (sub != null)
            Text(sub,
                style: const TextStyle(fontSize: 12.5, color: PinPalette.ink2)),
        ],
      ));

  Widget _previewBubble(String t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(5),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          ),
        ),
        child: Text(t,
            style: const TextStyle(
                fontSize: 16, height: 1.4, color: PinPalette.ink)),
      );

  Widget _toneGrid(ColorScheme scheme) => GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 2.7,
        children: [
          for (final k in _tones)
            GestureDetector(
              onTap: () => setState(() {
                _tone = k;
                _addr = null;
                _selfKey = null;
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                decoration: BoxDecoration(
                  color: _tone == k ? scheme.primary.withValues(alpha: 0.08) : Colors.white,
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(
                      color: _tone == k ? scheme.primary : PinPalette.line,
                      width: _tone == k ? 1.6 : 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('ตั้งเตือนให้แล้ว${toneParticle(k)}',
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: PinPalette.ink)),
                    const SizedBox(height: 3),
                    Text(_toneLabel[k]!,
                        style: const TextStyle(
                            fontSize: 11.5, color: PinPalette.ink2)),
                  ],
                ),
              ),
            ),
        ],
      );

  Widget _pills(List<String> opts, String selected, ValueChanged<String> onTap) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 9,
      runSpacing: 9,
      children: [
        for (final o in opts)
          GestureDetector(
            onTap: () => onTap(o),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                color: o == selected
                    ? scheme.primary.withValues(alpha: 0.08)
                    : const Color(0xFFFAFBFA),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                    color: o == selected ? scheme.primary : PinPalette.line,
                    width: o == selected ? 1.6 : 1),
              ),
              child: Text(o,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: o == selected ? scheme.secondary : PinPalette.ink)),
            ),
          ),
      ],
    );
  }
}
