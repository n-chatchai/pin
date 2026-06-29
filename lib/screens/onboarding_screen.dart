import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:image_picker/image_picker.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:image/image.dart' as img;
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../services/matrix_service.dart';
import '../services/prefs.dart';
import '../theme/pin_theme.dart';
import '../widgets/pin_button.dart';
import '../widgets/pin_field.dart';
import '../widgets/pin_toast.dart';
import '../widgets/recovery_qr.dart';
import 'welcome_screen.dart';

/// Onboarding. New users (signup=true): welcome → naming → theme → SIGNUP →
/// recovery key → ready (account created mid-flow, before recovery which needs
/// it). Returning/persona (signup=false): welcome → naming → theme → recovery →
/// ready. Dots top, full-width button bottom.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _page = PageController();
  int _index = 0;
  bool _recoverySaved = false; // gate: next disabled until key is saved/restored

  _RecoveryStep get _recovery => _RecoveryStep(
      onSaved: () => setState(() => _recoverySaved = true),
      // Restore succeeded → nothing left to do on this step, advance for them.
      onRestored: _next);

  /// Steps + their bottom-button labels (Thai-only for now). Account-only:
  /// persona + theme are collected IN-CHAT after the account/room exist (so they
  /// sync to room state from the start). '' label = self-advancing.
  List<(Widget, String)> _stepList() => [
        (_recovery, 'ถัดไป'),
        // Last step self-advances after a fade-in (label '' → no button).
        (_ReadyStep(active: _index == _readyIndex, onDone: _next), ''),
      ];

  // The celebratory last step is always last; animate it only once the user
  // actually reaches it (PageView builds pages eagerly).
  int get _readyIndex => 1;

  List<String> get _labels => [for (final s in _stepList()) s.$2];

  int get _recoveryIndex =>
      _stepList().indexWhere((s) => s.$1 is _RecoveryStep);

  List<Widget> _steps() => [for (final s in _stepList()) s.$1];

  @override
  void dispose() {
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
                // On the recovery step, stay disabled until the key is saved.
                child: PinButton(
                  _labels[_index],
                  onTap: (_index == _recoveryIndex && !_recoverySaved)
                      ? null
                      : _next,
                ),
              ),
          ],
        ),
      ),
    );
  }

}

/// Celebratory final onboarding step. Plays a pop-in once [active] flips true
/// (i.e. when the user lands on this page): the check badge springs in with an
/// expanding success ring, then the title and subtitle fade + rise.
class _ReadyStep extends StatefulWidget {
  final bool active;
  final VoidCallback onDone; // self-advance into the app once shown
  const _ReadyStep({required this.active, required this.onDone});
  @override
  State<_ReadyStep> createState() => _ReadyStepState();
}

class _ReadyStepState extends State<_ReadyStep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 500));
  bool _ran = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _run();
  }

  @override
  void didUpdateWidget(_ReadyStep old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _run();
  }

  // Fade in, hold briefly, then advance into the app on its own.
  void _run() {
    if (_ran) return;
    _ran = true;
    _c.forward();
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: FadeTransition(
        opacity: CurvedAnimation(parent: _c, curve: Curves.easeOut),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 66,
              height: 66,
              decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.15),
                  shape: BoxShape.circle),
              child: Icon(PhosphorIconsRegular.check,
                  color: scheme.secondary, size: 32),
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
    // Re-evaluate the "กู้คืน" enabled state as the key field fills (typed or
    // loaded from a QR image).
    _restoreCtl.addListener(() {
      if (mounted) setState(() {});
    });
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
      // Distinguish "definitely no backup" from "couldn't reach the server".
      // A FAILED check must never fall through to create: creating runs
      // resetRecovery, which DELETES the server backup and mints a new key —
      // destroying a backup that may well exist and locking other devices out.
      // BOUNDED: both are network/state queries with no internal deadline; on a
      // fresh post-login store one can stall and wedge this step ("sso loading"
      // forever). On timeout, degrade safely — unknown backup → restore (never
      // create, which would delete a real backup); unknown recovery state.
      bool? hasBackup;
      try {
        debugPrint('[onb] _init backupExists …');
        hasBackup = await MatrixService.instance
            .backupExists()
            .timeout(const Duration(seconds: 20));
        debugPrint('[onb] backupExists=$hasBackup');
      } catch (e) {
        debugPrint('[onb] backupExists failed/timeout: $e');
        hasBackup = null; // server unreachable → unknown, treat as "maybe yes"
      }
      debugPrint('[onb] _init recoveryState …');
      final state = await MatrixService.instance
          .recoveryState()
          .timeout(const Duration(seconds: 20), onTimeout: () => 'unknown')
          .catchError((_) => 'unknown');
      debugPrint('[onb] recoveryState=$state');
      if (!mounted) return;
      if (hasBackup == true || state == 'enabled') {
        // Returning user on a new device → restore with the existing key
        // (generating a new one would overwrite the backup and lock them out).
        // "Next" stays gated until the restore actually succeeds (onSaved fires
        // in _restore), so a user can't silently skip past locked chats.
        setState(() => _mode = 'restore');
      } else if (hasBackup == null) {
        // Couldn't verify → refuse to create (would risk deleting a real
        // backup). Send to restore and explain; the user can retry once online.
        setState(() {
          _mode = 'restore';
          _error = 'เชื่อมต่อเซิร์ฟเวอร์ไม่ได้ ตรวจสอบกุญแจสำรองไม่สำเร็จ';
        });
      } else {
        // hasBackup == false, definitively → safe to create a fresh key.
        setState(() => _mode = 'create');
        // Full bootstrap (cross-signing + backup + recovery) with the signup
        // password, then the combined QR (email + user key + ปิ่น key). Plain
        // backup-only would leave cross-signing "not ready" / recovery incomplete.
        // This is ALSO where the SSO companion is born (the ปิ่น pw is derived
        // from the recovery key here) — so verify it actually came up before
        // letting the user through, or they land in a local-only chat with no
        // ปิ่น account. bootstrap can miss silently (ensurePinSession swallows
        // its own errors), so check + retry rather than trust the return.
        final payload = await MatrixService.instance.bootstrapE2eeQr();
        if (!MatrixService.instance.companionReady) {
          await MatrixService.instance.ensurePinSession();
        }
        if (!MatrixService.instance.companionReady) {
          throw 'เชื่อมต่อบัญชี ปิ่น ไม่สำเร็จ — แตะ "ลองอีกครั้ง"';
        }
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
      // Only let them past once ปิ่น is actually up. For password users the
      // companion comes up from their password independently, so an E2EE-key
      // hiccup shouldn't trap them. For SSO users the companion IS this step —
      // advancing without it strands them in a local-only chat with no ปิ่น
      // account, so keep them here to retry instead.
      if (MatrixService.instance.companionReady) widget.onSaved?.call();
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
        // Auto-fire the restore when a QR code is successfully loaded.
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
      await Future.delayed(const Duration(milliseconds: 300));
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

  Future<void> _logout() async {
    setState(() => _restoring = true);
    await MatrixService.instance.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (_) => false,
    );
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
                PinField(
                  controller: _restoreCtl,
                  placeholder: 'วางกุญแจกู้คืนที่นี่',
                  minLines: 2,
                  maxLines: 5,
                  monospace: true,
                ),
                const SizedBox(height: 8),
                PinButton.outlined(
                  'โหลดจากรูป QR',
                  onTap: _restoring ? null : _loadQr,
                  icon: const Icon(PhosphorIconsRegular.qrCode,
                      size: 18, color: PinPalette.ink2),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!, style: TextStyle(color: scheme.error)),
                  ),
                const SizedBox(height: 12),
                // Disabled until a key is present (typed or QR-loaded).
                PinButton(
                  'กู้คืน',
                  busy: _restoring,
                  onTap:
                      _restoreCtl.text.trim().isEmpty ? null : _restore,
                ),
                const SizedBox(height: 4),
                PinButton.text(
                  'ไม่มีกุญแจ? เริ่มใหม่',
                  onTap: _restoring
                      ? null
                      : () async {
                          // No saved key → start fresh (old chat is abandoned).
                          // For SSO (no account password) the old ปิ่น pw is tied
                          // to the discarded recovery key, so a plain bootstrap
                          // would leave the companion LOCKED → a useless user-only
                          // QR. Recreate the companion instead → fresh pw stored in
                          // 4S → the new QR carries BOTH codes. Password users do
                          // the password-backed full reset.
                          setState(() {
                            _mode = 'create';
                            _key = null;
                            _qrData = null;
                            _error = null;
                          });
                          try {
                            final m2 = MatrixService.instance;
                            final String payload;
                            if (m2.hasUserPassword) {
                              payload = await m2.bootstrapE2eeQr();
                            } else {
                              final key = await m2.resetAndRecreateCompanion();
                              payload = await m2.packRecoveryQr(key);
                            }
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
                ),
                const SizedBox(height: 4),
                // Escape hatch: a user with no recovery key who doesn't want to
                // start fresh can still log out (e.g. to sign in to a different
                // account) instead of being trapped on this step.
                PinButton.text(
                  'ออกจากระบบ',
                  onTap: _restoring ? null : _logout,
                ),
              ],
            )
          else if (_error != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('ตั้งกุญแจไม่สำเร็จ: $_error',
                    style: TextStyle(color: scheme.error)),
                const SizedBox(height: 14),
                PinButton('ลองอีกครั้ง', onTap: () {
                  setState(() => _error = null);
                  _init();
                }),
              ],
            )
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
                      child: PinButton.key(
                        'คัดลอก',
                        icon: const Icon(PhosphorIconsRegular.copy),
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: _key!));
                          PinToast.show(context, 'คัดลอกกุญแจแล้ว');
                          widget.onSaved?.call();
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: PinButton.key(
                        'บันทึกรูป',
                        icon: const Icon(PhosphorIconsRegular.image),
                        onTap: _saveQr,
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
