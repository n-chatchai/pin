import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:image_picker/image_picker.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:image/image.dart' as img;
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../config.dart';

import '../services/auth_service.dart';
import '../services/matrix_service.dart';
import 'auth_screen.dart';
import '../services/prefs.dart';
import '../theme/pin_theme.dart';
import '../widgets/pin_toast.dart';
import '../widgets/recovery_qr.dart';
import '../widgets/pin_button.dart';
import '../widgets/pin_field.dart';
import '../widgets/pin_route.dart';
import '../theme/theme_controller.dart';

/// Onboarding. New users (signup=true): welcome → naming → theme → SIGNUP →
/// recovery key → ready (account created mid-flow, before recovery which needs
/// it). Returning/persona (signup=false): welcome → naming → theme → recovery →
/// ready. Dots top, full-width button bottom.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  final bool signup; // include the create-account step (new users)
  const OnboardingScreen(
      {super.key, required this.onDone, this.signup = false});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _page = PageController();
  int _index = 0;
  // Each persona picker = a preset chip selection + a custom input ("ใส่เอง").
  // The custom text wins when non-empty.
  final _nameCtl = TextEditingController();
  final _userCtl = TextEditingController();
  final _endCtl = TextEditingController();
  final _selfCtl = TextEditingController(text: 'ปิ่น');
  String _namePreset = 'ปิ่น';
  String _userPreset = 'พี่';
  String _endPreset = 'ครับ';
  bool _recoverySaved = false; // gate: next disabled until key is saved/restored

  _RecoveryStep get _recovery => _RecoveryStep(
      onSaved: () => setState(() => _recoverySaved = true),
      // Restore succeeded → nothing left to do on this step, advance for them.
      onRestored: _next);

  /// Steps + their bottom-button labels (Thai-only for now). Account-only:
  /// persona + theme are collected IN-CHAT after the account/room exist (so they
  /// sync to room state from the start). '' label = self-advancing.
  List<(Widget, String)> _stepList() => [
        if (widget.signup) (_SignupStep(onAuthed: _next), ''),
        (_recovery, 'ถัดไป'),
        (_ready(), 'เริ่มใช้ปิ่น'),
      ];

  List<String> get _labels => [for (final s in _stepList()) s.$2];

  int get _recoveryIndex =>
      _stepList().indexWhere((s) => s.$1 is _RecoveryStep);

  List<Widget> _steps() => [for (final s in _stepList()) s.$1];

  @override
  void dispose() {
    _nameCtl.dispose();
    _userCtl.dispose();
    _selfCtl.dispose();
    _endCtl.dispose();
    _page.dispose();
    super.dispose();
  }

  void _back() {
    if (_index > 0) {
      _page.previousPage(
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  void _next() {
    final last = _steps().length - 1;
    if (_index < last) {
      _page.nextPage(
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    } else {
      // Account onboarding done. Persona + theme are collected in-chat (after the
      // room exists) so they sync to room state; leave them at defaults for now.
      PrefsController.instance
          .update(PrefsController.instance.value.copyWith(onboarded: true));
      widget.onDone();
    }
  }

  @override
  Widget build(BuildContext context) {
    final steps = _steps();
    final hideButton = _labels[_index].isEmpty; // signup step drives itself
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Back arrow (hidden on the first step) + centered progress dots.
            SizedBox(
              height: 44,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  _Dots(count: steps.length, index: _index),
                  if (_index > 0)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        icon: const Icon(PhosphorIconsRegular.caretLeft),
                        color: PinPalette.ink2,
                        onPressed: _back,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: PageView(
                controller: _page,
                onPageChanged: (i) => setState(() => _index = i),
                physics: const NeverScrollableScrollPhysics(),
                children: steps,
              ),
            ),
            if (!hideButton)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: SizedBox(
                  width: double.infinity,
                  height: 58,
                  child: FilledButton(
                    // On the recovery step, stay disabled until the key is
                    // copied / saved (or restored).
                    onPressed: (_index == _recoveryIndex && !_recoverySaved)
                        ? null
                        : _next,
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      textStyle: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    child: Text(_labels[_index]),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _naming() => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('เรียกกันแบบไหนดี', style: PinPalette.brand(size: 27)),
            const SizedBox(height: 6),
            const Text('ปิ่นอยากเป็นกันเอง — เลือกแบบที่สบายใจ',
                style: TextStyle(color: PinPalette.ink2, fontSize: 13)),
            const SizedBox(height: 26),
            // Each = one horizontal row (chips + "ใส่เอง" input); scrolls
            // sideways if it doesn't fit.
            _pickRow('อยากเรียกปิ่นว่า', const ['น้อง', 'แก', 'เพื่อน', 'ปิ่น'],
                _nameCtl, _namePreset, (v) => setState(() => _namePreset = v)),
            const SizedBox(height: 22),
            _pickRow('ให้ปิ่นเรียกคุณว่า', const ['เธอ', 'นาย', 'พี่', 'คุณ'],
                _userCtl, _userPreset, (v) => setState(() => _userPreset = v)),
            const SizedBox(height: 22),
            _pickRow('ปิ่นลงท้ายว่า', const ['จ้ะ', 'ครับ', 'คะ', ''],
                _endCtl, _endPreset, (v) => setState(() => _endPreset = v)),
            const SizedBox(height: 24),
            const Row(children: [
              Icon(PhosphorIconsRegular.gearSix, size: 13, color: PinPalette.ink3),
              SizedBox(width: 6),
              Text('เปลี่ยนได้ภายหลังในการตั้งค่า',
                  style: TextStyle(fontSize: 12, color: PinPalette.ink3)),
            ]),
          ],
        ),
      );

  /// label + a single horizontal row: preset chips then a chip-sized custom
  /// input ("ใส่เอง"). Custom text wins; picking a chip clears the custom text.
  Widget _pickRow(String label, List<String> presets, TextEditingController ctl,
      String preset, ValueChanged<String> onPreset) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(label),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final v in presets) ...[
                _pickChip(v.isEmpty ? 'ไม่ลงท้าย' : v,
                    ctl.text.isEmpty && preset == v, () {
                  setState(() {
                    onPreset(v);
                    ctl.clear();
                  });
                }),
                const SizedBox(width: 8),
              ],
              _customChip(ctl),
            ],
          ),
        ),
      ],
    );
  }

  Widget _label(String t) =>
      Text(t, style: const TextStyle(color: PinPalette.ink2, fontSize: 13));

  /// Chip-sized text input that lives in the same row as the preset chips;
  /// typing deselects the presets. Highlighted when it holds a value.
  Widget _customChip(TextEditingController ctl) {
    final active = ctl.text.isNotEmpty;
    return SizedBox(
      width: 120,
      height: 38,
      child: TextField(
        controller: ctl,
        onChanged: (_) => setState(() {}),
        textAlignVertical: TextAlignVertical.center,
        style: const TextStyle(fontSize: 13.5, color: PinPalette.ink),
        decoration: InputDecoration(
          hintText: 'ใส่เอง',
          hintStyle: const TextStyle(fontSize: 13.5, color: Color(0xFFB7AE9A)),
          isDense: true,
          filled: true,
          fillColor: active ? const Color(0xFFE4EFDE) : Colors.white,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(
                color: active
                    ? const Color(0xFF34B06A)
                    : const Color(0xFFE7E0D1),
                width: active ? 1.4 : 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: const BorderSide(color: Color(0xFF34B06A), width: 1.4),
          ),
        ),
      ),
    );
  }

  Widget _pickChip(String label, bool selected, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFE4EFDE) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: selected
                    ? const Color(0xFF34B06A)
                    : const Color(0xFFE7E0D1),
                width: selected ? 1.4 : 1),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13.5,
                  color: selected ? const Color(0xFF34B06A) : PinPalette.ink,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
        ),
      );

  Widget _theme() => Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('เลือกธีมที่สบายใจ', style: PinPalette.brand(size: 27)),
            const SizedBox(height: 6),
            const Text('เปลี่ยนทีหลังได้ในการตั้งค่า',
                style: TextStyle(color: PinPalette.ink2, fontSize: 13)),
            const SizedBox(height: 20),
            ValueListenableBuilder<PinPalette>(
              valueListenable: ThemeController.instance,
              builder: (context, current, _) => LayoutBuilder(
                builder: (context, c) {
                  final w = (c.maxWidth - 14) / 2; // 2 columns
                  return Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: [
                      for (final p in PinPalette.all)
                        SizedBox(
                          width: w,
                          child: _ThemeTile(
                            palette: p,
                            selected: p.key == current.key,
                            onTap: () =>
                                ThemeController.instance.select(p.key),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      );

  Widget _ready() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 66,
            height: 66,
            decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.15),
                shape: BoxShape.circle),
            child: Icon(PhosphorIconsRegular.check, color: scheme.secondary, size: 32),
          ),
          const SizedBox(height: 16),
          Text('พร้อมแล้ว', style: PinPalette.brand(size: 30)),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              'เริ่มคุยได้เลย — ถามอะไรก็ได้ที่อยากให้ช่วย',
              textAlign: TextAlign.center,
              style: TextStyle(color: PinPalette.ink2, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

}

class _ThemeTile extends StatelessWidget {
  final PinPalette palette;
  final bool selected;
  final VoidCallback onTap;
  const _ThemeTile(
      {required this.palette, required this.selected, required this.onTap});

  Widget _line(double widthFactor, double alpha) => FractionallySizedBox(
        widthFactor: widthFactor,
        child: Container(
          height: 7,
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            color: palette.accent.withValues(alpha: alpha),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? palette.accent : const Color(0xFFEDE7DA),
            width: selected ? 2 : 1,
          ),
          boxShadow: const [
            BoxShadow(
                color: Color(0x0F282822),
                blurRadius: 10,
                offset: Offset(0, 3)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Mini-UI preview: a coloured dot + a few text lines on the theme's
            // soft surface.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              decoration: BoxDecoration(
                color: palette.pale,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                        color: palette.accent, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _line(1.0, 0.85),
                        _line(0.6, 0.4),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(palette.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, color: PinPalette.ink)),
                const Spacer(),
                if (selected)
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                        color: palette.accent, shape: BoxShape.circle),
                    child: const Icon(PhosphorIconsRegular.check,
                        size: 15, color: Colors.white),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Step 4: enables E2EE recovery and shows the recovery key to save.
class _RecoveryStep extends StatefulWidget {
  final VoidCallback? onSaved; // call when it's safe to advance (key saved)
  final VoidCallback? onRestored; // call to auto-advance after a successful restore
  const _RecoveryStep({this.onSaved, this.onRestored});

  @override
  State<_RecoveryStep> createState() => _RecoveryStepState();
}

class _RecoveryStepState extends State<_RecoveryStep> {
  // 'loading' | 'create' (first time) | 'restore' (returning) | 'restored'
  String _mode = 'loading';
  String? _key; // generated user recovery key (create) — shown as text
  String? _qrData; // combined QR payload (email + user key + ปิ่น key) JSON
  String? _error;
  final _restoreCtl = TextEditingController();
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _restoreCtl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      // Authoritative server check FIRST: if a backup already exists (e.g. set
      // up on another device), force RESTORE. The local recovery state is empty
      // before the first sync, so trusting it on a fresh device could send us
      // into "create" → which DELETES the existing backup and locks every other
      // device out.
      final hasBackup =
          await MatrixService.instance.backupExists().catchError((_) => false);
      final state = await MatrixService.instance.recoveryState();
      if (!mounted) return;
      if (hasBackup || state == 'enabled') {
        // Returning user on a new device → restore with the existing key
        // (generating a new one would overwrite the backup and lock them out).
        // "Next" stays gated until the restore actually succeeds (onSaved fires
        // in _restore), so a user can't silently skip past locked chats.
        setState(() => _mode = 'restore');
      } else {
        setState(() => _mode = 'create');
        // Full bootstrap (cross-signing + backup + recovery) with the signup
        // password, then the combined QR (email + user key + ปิ่น key). Plain
        // backup-only would leave cross-signing "not ready" / recovery incomplete.
        final payload = await MatrixService.instance.bootstrapE2eeQr();
        final m = jsonDecode(payload) as Map<String, dynamic>;
        if (mounted) {
          setState(() {
            _qrData = payload;
            _key = m['p'] != null ? '${m['u']}\n${m['p']}' : '${m['u']}';
          });
        }
      }
    } catch (e) {
      // The account already has a backup (recoveryState lagged) → don't show a
      // raw error; switch to restore so the user enters their existing key.
      if ('$e'.contains('backup already exists')) {
        if (mounted) {
          // Gated until a successful restore (onSaved fires in _restore).
          setState(() {
            _mode = 'restore';
            _error = null;
          });
        }
        return;
      }
      if (mounted) setState(() => _error = '$e');
      widget.onSaved?.call(); // don't trap the user if key setup failed
    }
  }

  /// Save the recovery QR (logo-branded PNG with the email shown as a visible
  /// caption) and open the share sheet → Files/Photos. The QR encodes the
  /// combined payload (email + user key + ปิ่น key); scanning it back restores
  /// both accounts (see _loadQr → restoreFromRecoveryQr).
  Future<void> _saveQr() async {
    if (_qrData == null && _key == null) return;
    await shareRecoveryQr(context, _qrData ?? _key!,
        caption: MatrixService.instance.userEmail);
    widget.onSaved?.call();
  }

  /// Pick a QR image from the gallery and decode it into the key field.
  Future<void> _loadQr() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (x == null) return;
      // Decode with ZXing (native) — far more tolerant of dense, logo-overlaid or
      // recompressed QRs than MLKit, which silently returns nothing on a shared
      // recovery image. The picture may hold ONE combined QR (older format) or
      // TWO tagged QRs (user + ปิ่น), so read them all.
      //
      // We decode the file to 8-bit RGB ourselves instead of using
      // readBarcodesImagePath: iOS image_picker can hand back 16-bit/channel PNGs,
      // and flutter_zxing's own path reader feeds those raw 16-bit samples to
      // ZXing as if they were 8-bit, so it finds nothing. Normalising here fixes
      // iOS while keeping Android's 8-bit jpgs working.
      final bytes = await x.readAsBytes();
      img.Image? im = img.decodeImage(bytes);
      if (im == null) {
        if (mounted) setState(() => _error = 'อ่านไฟล์รูปไม่ได้');
        return;
      }
      im = im.convert(format: img.Format.uint8, numChannels: 3);
      // Cap very large photos so decoding stays fast; keep module detail.
      if (im.width > 2000 || im.height > 2000) {
        im = img.copyResize(im,
            width: im.width >= im.height ? 2000 : null,
            height: im.height > im.width ? 2000 : null,
            interpolation: img.Interpolation.average);
      }
      final result = zx.readBarcodes(
        im.getBytes(order: img.ChannelOrder.rgb),
        DecodeParams(
          imageFormat: ImageFormat.rgb,
          format: Format.qrCode,
          width: im.width,
          height: im.height,
          tryHarder: true,
          tryInverted: true,
          tryRotate: true,
          isMultiScan: true,
          maxNumberOfSymbols: 5,
        ),
      );
      final codes = result.codes
          .where((c) => c.isValid)
          .map((c) => c.text)
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .toList();
      final combined = combineRecoveryQrCodes(codes);
      if (combined != null) {
        try {
          final m = jsonDecode(combined) as Map<String, dynamic>;
          final u = m['u'];
          final p = m['p'];
          setState(() => _restoreCtl.text = p != null ? '$u\n$p' : '$u');
        } catch (_) {
          setState(() => _restoreCtl.text = combined);
        }
        // Automatically start restoring so the user sees immediate feedback
        _restore();
      } else if (mounted) {
        setState(() => _error = 'อ่าน QR ไม่เจอในรูปนี้');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'โหลด QR ไม่ได้: $e');
    }
  }

  Future<void> _restore() async {
    final key = _restoreCtl.text.trim();
    if (key.isEmpty) return;
    setState(() {
      _restoring = true;
      _error = null;
    });
    try {
      // Accepts the combined QR JSON (user + ปิ่น keys + email) or a raw key.
      await MatrixService.instance.restoreFromRecoveryQr(key);
      if (mounted) setState(() => _mode = 'restored');
      widget.onSaved?.call(); // unlock "Next" only after a successful restore
      // Show "กู้คืนสำเร็จ" briefly, then advance for them — nothing left to do here.
      await Future.delayed(const Duration(milliseconds: 700));
      if (mounted) widget.onRestored?.call();
    } catch (e) {
      if (mounted) {
        setState(() => _error =
            'กุญแจไม่ถูกต้อง — ถ้าไม่มีกุญแจที่ถูกต้อง แชตเข้ารหัสเก่าจะกู้คืนไม่ได้ '
            'ลองกรอกกุญแจหรืออัพโหลด QR อีกครั้ง หรือกด ไม่มีกุญแจ เพื่อเริ่มใหม่');
      }
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final restore = _mode == 'restore' || _mode == 'restored';
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(restore ? 'กู้คืนแชตเข้ารหัส' : 'เก็บกุญแจกู้คืน',
              style: PinPalette.brand(size: 27)),
          const SizedBox(height: 18),
          if (restore) ...[
            const Text(
                'คุณเคยใช้บัญชีนี้มาก่อน แชตเก่าถูกเข้ารหัสไว้ — '
                'กรอกกุญแจกู้คืน หรืออัพโหลด QR ที่บันทึกไว้ตอนสมัคร เพื่อปลดล็อก\n'
                'กุญแจอยู่ที่คุณคนเดียว ระบบไม่บันทึก ถ้าไม่มีกุญแจที่ถูกต้อง แชตเก่าจะกู้คืนไม่ได้',
                style: TextStyle(color: PinPalette.ink2, height: 1.5)),
            const SizedBox(height: 16),
          ] else ...[
            Text.rich(
              TextSpan(
                style: const TextStyle(color: PinPalette.ink2, height: 1.5),
                children: [
                  const TextSpan(
                      text: 'เราเข้ารหัสแชตให้เพื่อความเป็นส่วนตัว '
                          'เปิดอ่านไม่ได้แม้แต่เรา — '),
                  TextSpan(
                      text: 'กุญแจอยู่ที่คุณคนเดียว',
                      style: TextStyle(
                          color: scheme.secondary,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            const SizedBox(height: 18),
          ],
          if (_mode == 'loading')
            const _Spinner('กำลังตรวจสอบ…')
          else if (_mode == 'restored')
            Row(children: [
              Icon(PhosphorIconsRegular.checkCircle, color: scheme.primary, size: 20),
              const SizedBox(width: 8),
              const Text('กู้คืนสำเร็จ', style: TextStyle(color: PinPalette.ink)),
            ])
          else if (_mode == 'restore')
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _restoreCtl,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    hintText: 'วางกุญแจกู้คืนที่นี่',
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _restoring ? null : _loadQr,
                  icon: const Icon(PhosphorIconsRegular.qrCode, size: 18),
                  label: const Text('โหลดจากรูป QR'),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!, style: TextStyle(color: scheme.error)),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _restoring ? null : _restore,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(_restoring ? 'กำลังกู้คืน…' : 'กู้คืน'),
                  ),
                ),
                TextButton(
                  onPressed: _restoring
                      ? null
                      : () async {
                          // No saved key → start fresh: rebuild the combined QR
                          // (resets both accounts' backups + new keys).
                          setState(() {
                            _mode = 'create';
                            _key = null;
                            _qrData = null;
                            _error = null;
                          });
                          try {
                            final payload = await MatrixService.instance
                                .bootstrapE2eeQr();
                            final m = jsonDecode(payload) as Map<String, dynamic>;
                            if (mounted) {
                              setState(() {
                                _qrData = payload;
                                _key = m['p'] != null ? '${m['u']}\n${m['p']}' : '${m['u']}';
                              });
                            }
                          } catch (e) {
                            if (mounted) setState(() => _error = '$e');
                          }
                        },
                  child: const Text('ไม่มีกุญแจ? เริ่มใหม่'),
                ),
              ],
            )
          else if (_error != null)
            Text('ตั้งกุญแจไม่สำเร็จ: $_error',
                style: TextStyle(color: scheme.error))
          else if (_key == null)
            const _Spinner('กำลังสร้างกุญแจ…')
          else
            Expanded(
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 28),
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 13, 10, 13),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SelectableText(
                    _key!,
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        letterSpacing: 0.5),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _key!));
                          PinToast.show(context, 'คัดลอกกุญแจแล้ว');
                          widget.onSaved?.call();
                        },
                        icon: const Icon(PhosphorIconsRegular.copy, size: 17),
                        label: const Text('คัดลอก'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                          foregroundColor: PinPalette.ink,
                          side: const BorderSide(color: PinPalette.line),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _saveQr,
                        icon: const Icon(PhosphorIconsRegular.downloadSimple, size: 17),
                        label: const Text('ดาวน์โหลด'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                          foregroundColor: PinPalette.ink,
                          side: const BorderSide(color: PinPalette.line),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                // Directly under the copy/download buttons.
                const Text.rich(
                  TextSpan(
                    style: TextStyle(
                        fontSize: 13, height: 1.45, color: PinPalette.ink),
                    children: [
                      TextSpan(
                          text:
                              'คัดลอกหรือดาวน์โหลดเก็บไว้ในที่ปลอดภัยและเป็นส่วนตัว — '),
                      TextSpan(
                          text: 'ถ้าหายเรากู้คืนไม่ได้',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                    ],
                  ),
                  textAlign: TextAlign.center,
                ),
                const Spacer(),
                // Plain note — nothing hidden, normal body text (no icon).
                const Text(
                  'ข้อความที่ส่งให้เอไอเช่น Google หรือ OpenAI ไม่รองรับ'
                  'การเข้ารหัสแบบต้นทางถึงปลายทาง (E2EE)',
                  style: TextStyle(
                      fontSize: 13, height: 1.45, color: PinPalette.ink),
                ),
              ],
            ),
            ),
        ],
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  final String label;
  const _Spinner(this.label);
  @override
  Widget build(BuildContext context) => Row(children: [
        const SizedBox(
            height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: PinPalette.ink2)),
      ]);
}

class _Dots extends StatelessWidget {
  final int count;
  final int index;
  const _Dots({required this.count, required this.index});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == index ? 18 : 7,
            height: 7,
            decoration: BoxDecoration(
              color: i == index ? scheme.primary : PinPalette.line,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}

/// Create-account step inside onboarding (new users). On success it calls
/// [onAuthed] to advance to the recovery-key step (which needs the account).
class _SignupStep extends StatefulWidget {
  final VoidCallback onAuthed;
  const _SignupStep({required this.onAuthed});

  @override
  State<_SignupStep> createState() => _SignupStepState();
}

class _SignupStepState extends State<_SignupStep> {
  static const _homeserver = kHomeserver;
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _auth = AuthService();
  bool _busy = false;
  String? _error;
  Timer? _debounce; // realtime username-availability check
  bool? _taken; // true = username already registered, null = unknown/typing

  @override
  void dispose() {
    _debounce?.cancel();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _onNameChanged(String v) {
    _debounce?.cancel();
    setState(() => _taken = null);
    final name = v.trim();
    if (name.length < 3) return;
    _debounce = Timer(const Duration(milliseconds: 600), () async {
      final free =
          await _auth.usernameAvailable(homeserver: _homeserver, username: name);
      if (mounted && _username.text.trim() == name) {
        setState(() => _taken = !free);
      }
    });
  }

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _auth.registerWithUsername(
        homeserver: _homeserver,
        username: _username.text.trim(),
        password: _password.text,
      );
      if (mounted) widget.onAuthed();
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('สร้างบัญชี', style: PinPalette.brand(size: 27)),
          const SizedBox(height: 8),
          const Text('ตั้งชื่อผู้ใช้ไว้เข้าสู่ระบบ',
              style: TextStyle(color: PinPalette.ink2)),
          const SizedBox(height: 24),
          PinField(
            controller: _username,
            enabled: !_busy,
            placeholder: 'ชื่อผู้ใช้',
            icon: PhosphorIconsLight.user,
            keyboardType: TextInputType.text,
            onChanged: _onNameChanged,
          ),
          // Realtime availability hint — fixed height so nothing shifts.
          SizedBox(
            height: 26,
            child: Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              // Only flag a problem (name taken). Nothing when free or typing.
              child: _taken == true
                  ? const Text('ชื่อนี้มีคนใช้แล้ว — เข้าสู่ระบบด้านล่าง',
                      style: TextStyle(fontSize: 12, color: Color(0xFFC0392B)))
                  : const SizedBox.shrink(),
            ),
          ),
          const SizedBox(height: 8),
          PinField(
            controller: _password,
            enabled: !_busy,
            placeholder: 'รหัสผ่าน',
            icon: PhosphorIconsLight.lockSimple,
            obscure: true,
            onSubmitted: () => (_busy || _taken == true) ? null : _go(),
          ),
          // Reserve a fixed slot for the error so the button never jumps.
          SizedBox(
            height: 34,
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _error == null
                  ? const SizedBox.shrink()
                  : Text(_error!,
                      style: const TextStyle(color: PinPalette.neg)),
            ),
          ),
          const SizedBox(height: 10),
          PinButton('สมัครและไปต่อ',
              busy: _busy, onTap: _taken == true ? null : _go),
          const SizedBox(height: 8),
          Center(
            child: PinButton.text('มีบัญชีอยู่แล้ว? เข้าสู่ระบบ',
                onTap: _busy
                    ? null
                    : () => Navigator.of(context)
                        .push(pinRoute(const AuthScreen()))),
          ),
        ],
      ),
    );
  }
}
