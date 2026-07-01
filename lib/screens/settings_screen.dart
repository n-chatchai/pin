import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/matrix_service.dart';
import 'api_log_screen.dart';
import 'watcher_debug_screen.dart';
import '../services/notification_service.dart';
import '../src/rust/api/matrix.dart' as rust;
import '../services/prefs.dart';
import '../theme/pin_theme.dart';
import '../theme/theme_controller.dart';
import '../widgets/pin_button.dart';
import '../widgets/pin_field.dart';
import '../widgets/theme_picker.dart';
import '../widgets/pin_toast.dart';
import '../widgets/recovery_qr.dart';
import '../agent/agent_config.dart';
import '../agent/agent_session.dart';
import '../agent/embedder.dart';
import '../widgets/flex_card_view.dart';
import 'abilities_screen.dart';
import 'openrouter_screen.dart';
import '../services/ai_settings.dart';
import 'device_data_screen.dart';
import 'device_verify_screen.dart';
import 'usage_screen.dart';
import 'local_chat_screen.dart' show debugForcePersonaSetup;
import 'personality_screen.dart';
import 'special_personas_screen.dart';
import 'welcome_screen.dart';

/// Dev-only debug tools (test runners) are gated behind this flag and stripped
/// from prod by const dead-code elimination. Build dev/test with
/// `--dart-define=PIN_DEBUG=true`; the prod/store build omits it.
const _kDebugTools = bool.fromEnvironment('PIN_DEBUG');

/// Apply a persona change locally AND push it (with the current theme) to the
/// ปิ่น room state so every device reads the same persona/theme (the room is the
/// source of truth — mirrors the chat transcript). The theme is included so this
/// write doesn't clobber the theme key already stored in the same state event.
Future<void> _updatePersona(PinPrefs np) async {
  await PrefsController.instance.update(np);
  final id = await MatrixService.instance.pinRoomId();
  if (id != null) {
    await MatrixService.instance.savePersonaToRoom(id, {
      'pin_name': np.pinName,
      'user_name': np.userName,
      'user_call': np.userCall,
      'pin_self': np.pinSelf,
      'tone': np.tone,
      'pin_ending': np.pinEnding,
      'persona_mode': np.personaMode,
      'custom_call': np.customCall,
      'custom_self': np.customSelf,
      'theme': ThemeController.instance.value.key,
      'lang': np.lang,
      'onboarded': np.onboarded ? '1' : '0',
      'persona_setup': np.personaSetup ? '1' : '0',
    });
  }
}

/// Settings screen, matching design/pin.html: persona names, reminders,
/// plugins, language, theme, account.
class SettingsScreen extends StatelessWidget {
  final String? userId;
  const SettingsScreen({super.key, this.userId});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('ตั้งค่า'),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: ValueListenableBuilder<PinPrefs>(
        valueListenable: PrefsController.instance,
        builder: (context, p, _) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(bottom: 96 + MediaQuery.of(context).viewPadding.bottom),
          children: [
            _section(p.pinName),
            _card([
              // 1) Persona — edited on a dedicated page with a live preview.
              _navRow(
                context,
                PhosphorIconsRegular.smiley,
                'บุคลิกของ${p.userCall}',
                '${p.pinName} · เรียก${p.userCall}',
                () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => PersonalityScreen(onSave: _updatePersona))),
              ),
              // 2) Capability — skills / tools.
              _navRow(
                context,
                PhosphorIconsRegular.sparkle,
                'ทีม$botName',
                'หาคนช่วย$botName — ติว ดูแลบ้าน ครีเอทีฟ',
                () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const AbilitiesScreen())),
              ),
              // 3) Special personas — opt-in role-play (18+).
              _navRow(
                context,
                PhosphorIconsRegular.maskHappy,
                'บุคลิกพิเศษ',
                'สวมบทตัวละคร',
                () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) =>
                        SpecialPersonasScreen(onSave: _updatePersona))),
              ),
            ]),
            _section('ทั่วไป'),
            // Language picker removed — Thai-only for now (English not ready);
            // locale is forced to Thai in PrefsController.
            _card([
              ValueListenableBuilder<PinPalette>(
                valueListenable: ThemeController.instance,
                builder: (context, palette, _) => ListTile(
                  leading: const Icon(PhosphorIconsRegular.palette),
                  title: const Text('ธีมสี'),
                  trailing: Text(palette.name,
                      style: const TextStyle(color: PinPalette.ink2)),
                  onTap: () => showThemePicker(context),
                ),
              ),
            ]),
            if (p.devUnlocked || _kDebugTools || kDebugMode) ...[
            _section('โมเดลเอไอ'),
            _card([
              ValueListenableBuilder<AiConfig>(
                valueListenable: AiSettings.instance,
                builder: (context, ai, _) => _navRow(
                  context,
                  PhosphorIconsRegular.cpu,
                  'โมเดลเอไอ',
                  ai.enabled
                      ? ai.model.split('/').last.replaceFirst(':free', '')
                      : 'ปิ่น (ฟรี)',
                  () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => const OpenRouterScreen())),
                ),
              ),
            ]),
            ],
            _section('สถานะความปลอดภัย'),
            _card([_SecurityStatus()]),
            if (p.devUnlocked || _kDebugTools || kDebugMode) ...[
            _section('เครื่องมือนักพัฒนา'),
            _card([
              SwitchListTile(
                secondary: const Icon(PhosphorIconsRegular.bug),
                title: const Text('ดีบักบอท'),
                subtitle: const Text(
                    'โชว์ขั้นตอนใต้คำตอบ + ส่งบทสนทนาให้ทีมพัฒนาดูเพื่อปรับปรุง '
                    '(ปิดการตาบอดชั่วคราว)'),
                value: p.debugBot,
                onChanged: (v) =>
                    PrefsController.instance.update(p.copyWith(debugBot: v)),
              ),
              ListTile(
                leading: const Icon(PhosphorIconsRegular.pulse),
                title: const Text('API call log'),
                subtitle: const Text('เวลาที่ใช้ของแต่ละ API (หา call ที่ช้า)'),
                trailing: const Icon(PhosphorIconsRegular.caretRight, size: 18),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const ApiLogScreen())),
              ),
              ListTile(
                leading: const Icon(PhosphorIconsRegular.binoculars),
                title: const Text('ดีบัก Watcher'),
                subtitle: const Text(
                    'ดู watch + งานเฝ้า (รันล่าสุด/ถึงเวลา) + รันเดี๋ยวนี้'),
                trailing: const Icon(PhosphorIconsRegular.caretRight, size: 18),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const WatcherDebugScreen())),
              ),
              // Merged into one card — was two separate boxes.
              _E2eeDebug(),
            ]),
            ],
            _section('บัญชี'),
            _card([
              if (userId != null)
                ListTile(
                  leading: const Icon(PhosphorIconsRegular.userCircle),
                  title: const Text('บัญชี'),
                  subtitle: Text(userId!,
                      style: const TextStyle(
                          color: PinPalette.ink2, fontSize: 12)),
                ),
              ListTile(
                leading: Icon(PhosphorIconsRegular.signOut, color: scheme.error),
                title: Text('ออกจากระบบ',
                    style: TextStyle(
                        color: scheme.error, fontWeight: FontWeight.w600)),
                onTap: () => _logout(context),
              ),
            ]),
            const _VersionTap(),
          ],
        ),
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 16, 8),
        child: Text(t.toUpperCase(),
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                color: PinPalette.ink2)),
      );

  /// White rounded card grouping a section's rows (design style).
  Widget _card(List<Widget> children) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(const Divider(
            height: 1, thickness: 1, indent: 0, endIndent: 0, color: PinPalette.line));
      }
      rows.add(children[i]);
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Color(0x0F282822), blurRadius: 10, offset: Offset(0, 3)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: rows),
    );
  }

  Widget _navRow(BuildContext context, IconData icon, String title,
          String value, VoidCallback onTap) =>
      ListTile(
        leading: Icon(icon),
        title: Text(title),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Bound + ellipsize: a long value (e.g. an OpenRouter model id) must
            // not steal the title's width and wrap it one char per line.
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.42),
              child: Text(value,
                  style: const TextStyle(color: PinPalette.ink2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right),
            ),
            const SizedBox(width: 4),
            const Icon(PhosphorIconsRegular.caretRight, size: 18),
          ],
        ),
        onTap: onTap,
      );

  Future<void> _logout(BuildContext context) async {
    await MatrixService.instance.logout();
    if (!context.mounted) return;
    // Land on the welcome landing (เริ่มใช้งาน = new signup flow / เข้าสู่ระบบ =
    // login), so a logged-out user can start a fresh account too.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (_) => false,
    );
  }
}

/// Clean, user-facing E2EE status (not the debug dump): one row per protection
/// with a green check when active — recovery, server key backup, cross-signing,
/// device verification.
/// App version footer. Tap 7× to reveal the developer-tools section (hidden by
/// default for the public release); long-press when unlocked to hide it again.
class _VersionTap extends StatefulWidget {
  const _VersionTap();
  @override
  State<_VersionTap> createState() => _VersionTapState();
}

class _VersionTapState extends State<_VersionTap> {
  int _taps = 0;
  String _ver = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((i) {
      if (mounted) {
        setState(() => _ver = 'เวอร์ชัน ${i.version} (${i.buildNumber})');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final unlocked = PrefsController.instance.value.devUnlocked;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (unlocked) return;
        _taps++;
        if (_taps >= 7) {
          _taps = 0;
          PrefsController.instance.update(
              PrefsController.instance.value.copyWith(devUnlocked: true));
          PinToast.show(context, 'เปิดโหมดนักพัฒนาแล้ว');
        } else if (_taps >= 4) {
          PinToast.show(context, 'อีก ${7 - _taps} ครั้ง');
        }
      },
      onLongPress: unlocked
          ? () {
              PrefsController.instance.update(PrefsController.instance.value
                  .copyWith(devUnlocked: false));
              PinToast.show(context, 'ปิดโหมดนักพัฒนาแล้ว');
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 26, 20, 34),
        child: Center(
          child: Text(
            _ver.isEmpty ? 'ปิ่น' : 'ปิ่น · $_ver',
            style: const TextStyle(color: PinPalette.ink3, fontSize: 12),
          ),
        ),
      ),
    );
  }
}

/// Placeholder row matching [_SecurityStatusState._row]'s height, shown while
/// the status loads so the card reserves its space (no layout shift).
class _LoadingRow extends StatelessWidget {
  final IconData icon;
  final String title;
  const _LoadingRow(this.icon, this.title);
  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon, color: PinPalette.ink3),
        title: Text(title),
        subtitle: const Text('กำลังตรวจสอบ…',
            style: TextStyle(color: PinPalette.ink3, fontSize: 12)),
        trailing: const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
}

class _SecurityStatus extends StatefulWidget {
  @override
  State<_SecurityStatus> createState() => _SecurityStatusState();
}

class _SecurityStatusState extends State<_SecurityStatus> {
  Future<rust.E2eeStatus>? _future;

  @override
  void initState() {
    super.initState();
    // Defer the FFI call to after the push transition (which takes ~300ms)
    // so the transition into settings doesn't stutter.
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) {
        setState(() => _future = MatrixService.instance.e2eeStatus());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<rust.E2eeStatus>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          // Reserve the final 4-row height while loading (same rows, muted +
          // spinner) so the card doesn't grow and shove the page down when the
          // real status arrives.
          return Column(children: const [
            _LoadingRow(PhosphorIconsRegular.key, 'สำรองกุญแจกู้คืน'),
            _LoadingRow(PhosphorIconsRegular.sealCheck, 'การลงนามข้ามอุปกรณ์'),
            _LoadingRow(PhosphorIconsRegular.deviceMobile, 'อุปกรณ์นี้ยืนยันแล้ว'),
            _LoadingRow(PhosphorIconsRegular.eyeSlash, 'ความเป็นส่วนตัวของเอไอ'),
          ]);
        }
        if (!snap.hasData) {
          return ListTile(
            dense: true,
            title: const Text('อ่านสถานะไม่ได้'),
            trailing: IconButton(
              icon: const Icon(PhosphorIconsRegular.arrowsClockwise, size: 18),
              onPressed: () => setState(
                  () => _future = MatrixService.instance.e2eeStatus()),
            ),
          );
        }
        final s = snap.data!;
        final hasRecovery = s.recovery == 'enabled';
        final incomplete = s.recovery == 'incomplete';
        return Column(children: [
          // Recovery key + server backup are one feature → one row. Tappable to
          // set it up when it's not on yet (no dead-end warning).
          _row(
            PhosphorIconsRegular.key,
            'สำรองกุญแจกู้คืน',
            hasRecovery
                ? 'เปิดอยู่ · กู้แชตคืนเมื่อเปลี่ยนเครื่องได้'
                : incomplete
                    ? 'ตั้งค่ายังไม่ครบ — แตะตั้งให้เสร็จ'
                    : 'ยังไม่เปิด — แตะเพื่อสำรองกุญแจ',
            hasRecovery,
            onTap: hasRecovery ? null : () => _setupRecovery(context),
          ),
          _row(PhosphorIconsRegular.sealCheck, 'การลงนามข้ามอุปกรณ์',
              s.crossSigningReady ? 'พร้อม' : 'ยังไม่พร้อม', s.crossSigningReady),
          _row(PhosphorIconsRegular.deviceMobile, 'อุปกรณ์นี้ยืนยันแล้ว',
              s.deviceVerified ? 'ยืนยันแล้ว' : 'ยังไม่ยืนยัน', s.deviceVerified),
          // Privacy is one more "protection" in the list — tap for the
          // explanation (blind proxy / PII-aware tools / on-device memory).
          _row(PhosphorIconsRegular.eyeSlash, 'ความเป็นส่วนตัวของเอไอ',
              'การเข้ารหัสแชทและการใช้งานเอไอ', true,
              onTap: () => _showPrivacy(context)),
        ]);
      },
    );
  }

  /// One status row: a topic icon (tinted by status), label + state, and either
  /// a chevron (actionable) or a check/warn badge (read-only).
  Widget _row(IconData icon, String title, String sub, bool ok,
          {VoidCallback? onTap}) =>
      Builder(builder: (context) {
        // "ok" tint = the active ปิ่น accent (the palette the user picked), so the
        // check matches the rest of the app — colorScheme.primary isn't it.
        final c =
            ok ? ThemeController.instance.value.accent : const Color(0xFFE0A100);
        return ListTile(
      // Plain icon (no tinted box) + default title weight, like every other
      // settings row. Status colour stays on the trailing check/warn badge.
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(sub,
          style: const TextStyle(color: PinPalette.ink2, fontSize: 12)),
      trailing: onTap != null
          ? const Icon(PhosphorIconsRegular.caretRight,
              size: 18, color: PinPalette.ink3)
          : Icon(
              ok
                  ? PhosphorIconsFill.checkCircle
                  : PhosphorIconsFill.warningCircle,
              color: c,
              size: 20),
      onTap: onTap,
        );
      });

  /// Full E2EE setup (cross-signing + key backup + recovery) — needs the account
  /// password (UIA). `enableRecovery` alone only does the backup and leaves
  /// cross-signing "not ready" → recovery stays "incomplete", so we use the
  /// full bootstrap screen here. Refresh the status card afterwards.
  Future<void> _setupRecovery(BuildContext context) async {
    await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const E2eeResetScreen()));
    if (mounted) {
      setState(() => _future = MatrixService.instance.e2eeStatus());
    }
  }

  void _showPrivacy(BuildContext context) {
    // Push (slide-left) to match the chevron affordance — same as every other
    // "›" row in Settings. (Was a slide-up sheet → inconsistent.)
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const _PrivacyScreen()));
  }
}

/// Full-screen privacy explanation (pushed, slide-left).
class _PrivacyScreen extends StatelessWidget {
  const _PrivacyScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ความเป็นส่วนตัวของเอไอ')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 24 + MediaQuery.of(context).viewPadding.bottom),
        children: const [
          _PrivacyItem(PhosphorIconsRegular.eyeSlash, 'AI ไม่เห็นตัวตนคุณ',
              'ข้อความวิ่งผ่านพร็อกซีแบบ "ตาบอด" — ส่งต่อไปยังโมเดลเท่านั้น '
                  'ไม่เก็บ ไม่บันทึก log เนื้อหาบทสนทนา'),
          _PrivacyItem(PhosphorIconsRegular.scissors, 'เครื่องมือเห็นแค่คำค้น',
              'tools / MCP / ผู้พัฒนาภายนอก ได้รับเฉพาะค่าที่จำเป็น '
                  '(เช่น ชื่อเมือง) ระบบตัดชื่อ บทสนทนา และการตั้งค่าส่วนตัว '
                  'ออกก่อนเสมอ'),
          _PrivacyItem(PhosphorIconsRegular.deviceMobile, 'ความจำอยู่บนเครื่อง',
              'ประวัติแชท ความจำ และความรู้ที่ปิ่นสรุป เก็บเข้ารหัสบนเครื่องคุณ '
                  'ไม่ขึ้นเซิร์ฟเวอร์'),
        ],
      ),
    );
  }
}

/// One explanation block inside the privacy screen.
class _PrivacyItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _PrivacyItem(this.icon, this.title, this.body);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: scheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 3),
                Text(body,
                    style: const TextStyle(
                        color: PinPalette.ink2, fontSize: 13, height: 1.45)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// E2EE diagnostics row (Settings debug): device, recovery, cross-signing,
/// verification — plus copy-all for support.
class _E2eeDebug extends StatefulWidget {
  @override
  State<_E2eeDebug> createState() => _E2eeDebugState();
}

typedef _DebugData = ({
  String appVersion,
  rust.E2eeStatus status,
  String? roomId,
  List<String> members,
  bool embedReady,
});

class _E2eeDebugState extends State<_E2eeDebug> {
  Future<_DebugData>? _future;

  @override
  void initState() {
    super.initState();
    // Defer PackageInfo + FFI off the transition animation (avoids the jank).
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) {
        setState(() {
          _future = _load();
        });
      }
    });
  }

  Future<_DebugData> _load() async {
    final info = await PackageInfo.fromPlatform();
    rust.E2eeStatus? status;
    String? roomId;
    List<String> members = [];
    
    try {
      status = await MatrixService.instance.e2eeStatus();
      roomId = await MatrixService.instance.pinRoomId();
      if (roomId != null) {
        members = await MatrixService.instance.roomMembers(roomId).catchError((_) => <String>[]);
      }
    } catch (_) {
      // Ignored: happens in mock/preview mode where Matrix isn't authenticated
    }

    // Actually run an embed → proves the ONNX lib loaded + model infers on this
    // device (not just that the asset is bundled). Null = recency fallback.
    final embedReady = (await Embedder.instance.embedQuery('ทดสอบ')) != null;
    return (
      appVersion: '${info.version} (${info.buildNumber})',
      status: status ?? const rust.E2eeStatus(userId: '', deviceId: '', recovery: '', crossSigningReady: false, deviceVerified: false),
      roomId: roomId,
      members: members,
      embedReady: embedReady,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_DebugData>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const ListTile(title: Text('กำลังอ่านสถานะ E2EE…'));
        }
        if (!snap.hasData) {
          return ListTile(
            title: const Text('อ่านสถานะไม่ได้'),
            trailing: IconButton(
              icon: const Icon(PhosphorIconsRegular.arrowsClockwise, size: 18),
              onPressed: () => setState(() => _future = _load()),
            ),
          );
        }
        final d = snap.data!;
        // Every row navigates (slide-left) to a full screen — no dialogs/sheets.
        // Status itself lives in the "สถานะความปลอดภัย" card above.
        Future<void> push(Widget screen) => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => screen));
        return Column(children: [
          _tile(
            PhosphorIconsRegular.info,
            'เวอร์ชัน · สถานะระบบ',
            'รุ่น ${d.appVersion} · E2EE '
                '${d.status.crossSigningReady ? "พร้อม" : "ยังไม่พร้อม"}'
                ' · Embed ${d.embedReady ? "พร้อม" : "ปิด ${Embedder.instance.lastError ?? ""}"}',
            nav: true,
            onTap: () => push(_DiagnosticsScreen(d)),
          ),
          if (_kDebugTools) ...[
          _div(),
          _tile(
            PhosphorIconsRegular.cpu,
            'ทดสอบสมองในเครื่อง',
            'ลองถาม "อากาศเชียงใหม่" แล้วดูการ์ดผลลัพธ์',
            nav: true,
            onTap: () => push(_DebugActionScreen(
              title: 'ทดสอบสมองในเครื่อง',
              desc: 'ส่งคำถาม "อากาศเชียงใหม่" ผ่านปิ่นบนเครื่อง → ตัวกลาง → '
                  'โมเดล → เครื่องมือ แล้วแสดงการ์ด/ข้อมูลที่ได้กลับมา',
              run: _runDeviceBrain,
            )),
          ),
          _div(),
          _tile(
            PhosphorIconsRegular.newspaper,
            'รันงานข่าวเช้า (เดี๋ยวนี้)',
            'จำลองการปลุก รันงานตามเวลาทันที',
            nav: true,
            onTap: () => push(_DebugActionScreen(
              title: 'รันงานข่าวเช้า',
              desc: 'รันงาน "ค้นข่าว → สรุป" บนเครื่องทันที (จำลองการปลุกด้วย '
                  'การแจ้งเตือน) เพื่อเช็คว่างานตามเวลาทำงาน',
              run: _runNewsJob,
            )),
          ),
          _div(),
          _tile(
            PhosphorIconsRegular.bell,
            'ทดสอบแจ้งเตือน (10 วิ)',
            'ส่งแจ้งเตือน + ตรวจสิทธิ์และคิวที่ค้าง',
            nav: true,
            onTap: () => push(_DebugActionScreen(
              title: 'ทดสอบแจ้งเตือน',
              desc: 'ส่งแจ้งเตือนทดสอบใน 10 วินาที + แสดงสิทธิ์และคิวที่ค้าง '
                  'ออกจากแอปเพื่อดูว่าเด้งไหม',
              run: () async => (
                text: await NotificationService.instance.debugTest(secs: 10),
                flex: null,
              ),
            )),
          ),
          _div(),
          _tile(
            PhosphorIconsRegular.users,
            'ทดสอบ DM ปิ่น (2-account)',
            'ยก ปิ่น session + DM แล้วอ่าน timeline กลับมา — เช็ค provision + E2EE',
            nav: true,
            onTap: () => push(_DebugActionScreen(
              title: 'ทดสอบ DM ปิ่น',
              desc: 'register/login บัญชี ปิ่น, สร้าง/หา DM เข้ารหัส, แล้ว '
                  'paginate ข้อความกลับมา — ดูว่า provision สำเร็จ + ถอดรหัสได้',
              run: _runPinDmTest,
            )),
          ),
          _div(),
          _tile(
            PhosphorIconsRegular.chatCircle,
            'รัน persona setup ใหม่',
            'ปิดหน้านี้แล้วเริ่มถามตั้งชื่อ/เรียกขาน ในแชตอีกครั้ง',
            onTap: () {
              if (debugForcePersonaSetup == null) {
                PinToast.show(context, 'เปิดหน้าแชตก่อน');
                return;
              }
              Navigator.of(context).popUntil((r) => r.isFirst);
              debugForcePersonaSetup?.call();
            },
          ),
          ],
          _div(),
          _tile(
            PhosphorIconsRegular.coins,
            'การใช้งาน · ค่าใช้จ่าย',
            'โทเค็น + ค่าใช้จ่าย (บาท) · ล่าสุด/วันนี้/7วัน/30วัน',
            nav: true,
            onTap: () => push(const UsageScreen()),
          ),
          _div(),
          _tile(
            PhosphorIconsRegular.database,
            'ข้อมูลห้องแชต',
            'ดู/ล้าง ความจำ · ประวัติ · ความรู้ · การตั้งค่า',
            nav: true,
            onTap: () => push(const DeviceDataScreen()),
          ),
          _div(),
          _tile(
            PhosphorIconsRegular.devices,
            'ยืนยันอุปกรณ์',
            'เทียบ emoji กับอีกเครื่องที่ล็อกอินอยู่ → ปลดล็อกแชตเก่าโดยไม่ใช้กุญแจ',
            nav: true,
            onTap: () => push(const DeviceVerifyScreen()),
          ),
          _div(),
          _tile(
            PhosphorIconsRegular.shieldWarning,
            'ตั้งค่า E2EE ใหม่',
            'ตั้งการลงนามข้ามอุปกรณ์/กุญแจใหม่ (ต้องใช้รหัสผ่าน)',
            danger: true,
            nav: true,
            onTap: () => push(const E2eeResetScreen())
                .then((_) => setState(() => _future = _load())),
          ),
        ]);
      },
    );
  }

  // Bring up the ปิ่น 2-account DM and read its (decrypted) timeline back — a
  // standalone check of provisioning + E2EE before the chat renders from it.
  Future<_DebugOut> _runPinDmTest() async {
    final m = MatrixService.instance;
    await m.ensurePinSession();
    final rid = await m.getOrCreatePinDm();
    final members =
        await m.roomMembers(rid).catchError((_) => <String>[]);
    final page = await m.roomMessages(rid, limit: 20);
    final lines = page.messages.reversed.map((e) {
      final who = e.sender == m.pinUserId
          ? 'ปิ่น'
          : (e.sender == m.userId ? 'ฉัน' : e.sender);
      final b = e.body.length > 40 ? '${e.body.substring(0, 40)}…' : e.body;
      return '[$who/${e.kind}] $b';
    }).join('\n');
    final txt = 'pinUserId: ${m.pinUserId ?? "(ยังไม่ขึ้น)"}\n'
        'room: $rid\n'
        'members: ${members.join(", ")}\n'
        'msgs (${page.messages.length}):\n'
        '${lines.isEmpty ? "(ว่าง — ยังไม่มีข้อความ หรือถอดรหัสไม่ได้)" : lines}';
    return (text: txt, flex: null);
  }

  // Pure runners → text and/or a flex card the action screen renders.
  Future<_DebugOut> _runDeviceBrain() async {
    final session = AgentSession(room: 'device-test', proxy: devProxy());
    final r = await session.send('อากาศเชียงใหม่วันนี้เป็นไง สรุปสั้นๆ');
    return (text: r.text, flex: r.flex);
  }

  Future<_DebugOut> _runNewsJob() async {
    final session = AgentSession(room: 'job-news', proxy: devProxy());
    final r = await session.send(
        'ค้นข่าวเด่นของไทยล่าสุด แล้วสรุปเป็นข้อ ๆ สั้น ๆ 3-5 หัวข้อ');
    return (text: r.text, flex: r.flex);
  }

  Widget _div() =>
      const Divider(height: 1, indent: 56, color: PinPalette.line);

  /// Settings-style tile. Per the design language: a chevron means "navigates";
  /// an action that runs in place has NO trailing glyph (just tappable, like the
  /// attachment-menu rows). `trailing` overrides (e.g. a copy icon for info).
  Widget _tile(IconData icon, String title, String subtitle,
      {required VoidCallback onTap,
      Widget? trailing,
      bool nav = false,
      bool danger = false}) {
    final color = danger ? const Color(0xFFC0392B) : null;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title,
          style: TextStyle(
              fontWeight: FontWeight.w600, fontSize: 14, color: color)),
      subtitle: Text(subtitle,
          style: const TextStyle(color: PinPalette.ink2, fontSize: 12)),
      trailing: trailing ??
          (nav ? const Icon(PhosphorIconsRegular.caretRight, size: 18) : null),
      onTap: onTap,
    );
  }

}

/// A debug run's output: text and/or a flex card spec.
typedef _DebugOut = ({String? text, Map<String, dynamic>? flex});

/// Generic full-screen debug action: auto-runs on open, renders the result
/// inline (flex card + JSON when present), with a "รันอีกครั้ง" button.
class _DebugActionScreen extends StatefulWidget {
  final String title;
  final String desc;
  final Future<_DebugOut> Function() run;
  const _DebugActionScreen(
      {required this.title, required this.desc, required this.run});

  @override
  State<_DebugActionScreen> createState() => _DebugActionScreenState();
}

class _DebugActionScreenState extends State<_DebugActionScreen> {
  bool _running = true;
  _DebugOut? _out;
  String? _error;

  @override
  void initState() {
    super.initState();
    _go();
  }

  Future<void> _go() async {
    setState(() {
      _running = true;
      _out = null;
      _error = null;
    });
    try {
      final out = await widget.run();
      if (mounted) setState(() => _out = out);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Widget _card(Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [
            BoxShadow(
                color: Color(0x0F282822),
                blurRadius: 10,
                offset: Offset(0, 3)),
          ],
        ),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final flex = _out?.flex;
    final text = _out?.text;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Text(widget.desc,
              style: const TextStyle(
                  color: PinPalette.ink2, fontSize: 13, height: 1.45)),
          const SizedBox(height: 16),
          if (_running)
            _card(const Row(children: [
              SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Text('กำลังรัน…'),
            ]))
          else if (_error != null)
            _card(SelectableText('ผิดพลาด: $_error',
                style: const TextStyle(
                    color: Color(0xFFC0392B), fontSize: 14)))
          else ...[
            // Rendered card (what the user actually sees in chat).
            if (flex != null) FlexCardView(spec: flex),
            // Text reply, if any.
            if (text != null && text.isNotEmpty) ...[
              const SizedBox(height: 12),
              _card(SelectableText(text,
                  style: const TextStyle(fontSize: 14, height: 1.5))),
            ],
            // Raw JSON of the card spec — for inspecting the structure.
            if (flex != null) ...[
              const SizedBox(height: 12),
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('JSON',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  childrenPadding: EdgeInsets.zero,
                  children: [
                    _card(SelectableText(
                      const JsonEncoder.withIndent('  ').convert(flex),
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12, height: 1.4),
                    )),
                  ],
                ),
              ),
            ],
            if (flex == null && (text == null || text.isEmpty))
              _card(const Text('(ว่าง)')),
          ],
          const SizedBox(height: 16),
          PinButton('รันอีกครั้ง', onTap: _running ? null : _go, busy: _running),
        ],
      ),
    );
  }
}

/// Full-screen diagnostics — key/value status + copy-all.
class _DiagnosticsScreen extends StatelessWidget {
  final _DebugData d;
  const _DiagnosticsScreen(this.d);

  @override
  Widget build(BuildContext context) {
    final s = d.status;
    final recovery = switch (s.recovery) {
      'enabled' => 'เปิดใช้งาน',
      'disabled' => 'ปิด',
      'incomplete' => 'ไม่สมบูรณ์',
      _ => 'ไม่ทราบ',
    };
    final rows = <(String, String)>[
      ('รุ่นแอป', d.appVersion),
      ('บัญชี', s.userId),
      ('อุปกรณ์', s.deviceId),
      ('รหัสกู้คืน', recovery),
      ('การลงนามข้ามอุปกรณ์', s.crossSigningReady ? 'พร้อม' : 'ยังไม่พร้อม'),
      ('อุปกรณ์ยืนยันแล้ว', s.deviceVerified ? 'ใช่' : 'ยัง'),
      ('ห้อง', d.roomId ?? '—'),
      ('สมาชิก', '${d.members.length} · ${d.members.join(", ")}'),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('เวอร์ชัน · สถานะระบบ')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          for (final (k, v) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                      width: 120,
                      child: Text(k,
                          style: const TextStyle(
                              color: PinPalette.ink2, fontSize: 13))),
                  Expanded(
                    child: SelectableText(v,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 13)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          PinButton('คัดลอกทั้งหมด', onTap: () {
            Clipboard.setData(ClipboardData(
                text: rows.map((r) => '${r.$1}: ${r.$2}').join('\n')));
            PinToast.show(context, 'คัดลอกแล้ว');
            },
          ),
        ],
      ),
    );
  }
}

/// Full-screen E2EE reset — password field → recovery key shown inline.
/// E2EE recovery screen — full bootstrap/reset of the user key AND "เริ่ม ปิ่น
/// ใหม่" (recreate a locked companion), both showing the new recovery QR to save.
/// Public so the chat can route here when the companion can't come up
/// ([MatrixService.companionLocked]).
class E2eeResetScreen extends StatefulWidget {
  /// When true (opened from the chat "companion locked" banner) the screen
  /// auto-runs "เริ่ม ปิ่น ใหม่" on open — so the user doesn't have to find the
  /// right button (the user-key "ตั้งค่าใหม่" would NOT fix a locked companion).
  const E2eeResetScreen({super.key, this.lockedCompanion = false});

  final bool lockedCompanion;

  @override
  State<E2eeResetScreen> createState() => _E2eeResetScreenState();
}

class _E2eeResetScreenState extends State<E2eeResetScreen> {
  final _pw = TextEditingController();
  bool _running = false;
  String? _key;
  String? _qrData; // combined QR payload (email + user key + ปิ่น key)
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.lockedCompanion) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _recreatePin());
    }
  }

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  /// Start a brand-new ปิ่น when the old one can't be recovered: resets the
  /// recovery key, registers a fresh companion, shows the new key to save.
  Future<void> _recreatePin() async {
    setState(() {
      _running = true;
      _error = null;
      _key = null;
    });
    try {
      final key = await MatrixService.instance.resetAndRecreateCompanion();
      final payload = await MatrixService.instance.packRecoveryQr(key);
      final m = jsonDecode(payload) as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _key = m['p'] != null ? '${m['u']}\n${m['p']}' : '${m['u']}';
          _qrData = payload;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _reset() async {
    setState(() {
      _running = true;
      _error = null;
      _key = null;
    });
    try {
      // No account password (Google/SSO users have none) → reset just the
      // recovery key + key backup, with no cross-signing UIA. With a password →
      // full cross-signing bootstrap. Either way packRecoveryQr then derives the
      // ปิ่น companion password from the new key so the companion can come up.
      final pw = _pw.text;
      final key = pw.isEmpty
          ? await MatrixService.instance.resetRecoveryKey()
          : await MatrixService.instance.resetRecovery(pw);
      // Package into the combined QR (adds ปิ่น key + email) without rotating
      // the just-issued user key.
      final payload = await MatrixService.instance.packRecoveryQr(key);
      final m = jsonDecode(payload) as Map<String, dynamic>;
      if (mounted) setState(() {
        _key = m['p'] != null ? '${m['u']}\n${m['p']}' : '${m['u']}';
        _qrData = payload;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ตั้งค่ากุญแจความปลอดภัย')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            20, 16, 20, 24 + MediaQuery.of(context).viewPadding.bottom),
        children: [
          const Text(
              'สำรองกุญแจกู้คืน + ตั้งการลงนามข้ามอุปกรณ์. จะได้กุญแจกู้คืน — '
              'เก็บไว้ในที่ปลอดภัย ถ้าหายเรากู้ให้ไม่ได้.',
              style: TextStyle(fontSize: 13, height: 1.45)),
          const SizedBox(height: 16),
          if (MatrixService.instance.hasUserPassword) ...[
            PinField(
              controller: _pw,
              placeholder: 'รหัสผ่านบัญชี',
              icon: PhosphorIconsLight.lockSimple,
              obscure: true,
              enabled: !_running && _key == null,
            ),
            const SizedBox(height: 16),
          ],
          const SizedBox(height: 16),
          if (_key == null) ...[
            PinButton('ตั้งค่าใหม่',
                onTap: _running ? null : _reset, busy: _running),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _running ? null : _recreatePin,
              child: const Text('กู้ ปิ่น เดิมไม่ได้? เริ่ม ปิ่น ใหม่ (แชตเดิมจะหาย)',
                  style: TextStyle(fontSize: 13)),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text('ตั้งค่าไม่สำเร็จ: $_error',
                  style: const TextStyle(color: Color(0xFFC0392B))),
            ),
          if (_key != null) ...[
            const Text('กุญแจกู้คืนใหม่ — เก็บไว้ให้ดี',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFE9F1E6),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(_key!,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 14, height: 1.5)),
            ),
            const SizedBox(height: 12),
            // Key actions = a row of two equal outlined buttons (design .key-acts).
            Row(children: [
              Expanded(
                child: _keyActBtn(PhosphorIconsRegular.copy, 'คัดลอก', () {
                  Clipboard.setData(ClipboardData(text: _key!));
                  PinToast.show(context, 'คัดลอกแล้ว');
                }),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _keyActBtn(
                    PhosphorIconsRegular.qrCode,
                    'บันทึก QR',
                    () => shareRecoveryQr(context, _qrData ?? _key!,
                        caption: MatrixService.instance.userEmail)),
              ),
            ]),
          ],
        ],
      ),
    );
  }

  /// Design `.key-acts` button: equal-width, white, hairline border, green icon.
  Widget _keyActBtn(IconData icon, String label, VoidCallback onTap) => SizedBox(
        height: 40,
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 16, color: ThemeController.instance.value.accent),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            foregroundColor: PinPalette.ink,
            backgroundColor: Colors.white,
            side: const BorderSide(color: PinPalette.line),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
            textStyle:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      );
}
