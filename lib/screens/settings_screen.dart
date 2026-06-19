import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/matrix_service.dart';
import 'api_log_screen.dart';
import '../services/notification_service.dart';
import '../src/rust/api/matrix.dart' as rust;
import '../services/prefs.dart';
import '../theme/pin_theme.dart';
import '../theme/theme_controller.dart';
import '../widgets/theme_picker.dart';
import '../widgets/pin_toast.dart';
import '../widgets/recovery_qr.dart';
import '../agent/agent_config.dart';
import '../agent/agent_session.dart';
import '../widgets/flex_card_view.dart';
import 'abilities_screen.dart';
import 'device_data_screen.dart';
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
      'user_call': np.userCall,
      'pin_self': np.pinSelf,
      'pin_ending': np.pinEnding,
      'theme': ThemeController.instance.value.key,
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
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            _section(p.pinName),
            _card([
              _navRow(
                context,
                LucideIcons.messageCircle,
                'ชื่อผู้ช่วย',
                p.pinName,
                () => _editText(context, 'ตั้งชื่อผู้ช่วย', p.pinName,
                    ['ปิ่น', 'น้อง', 'แก'],
                    (v) => _updatePersona(
                        p.copyWith(pinName: v.trim().isEmpty ? 'ปิ่น' : v.trim()))),
              ),
              _navRow(
                context,
                LucideIcons.user,
                'ให้${p.pinName}เรียกเราว่า',
                p.userCall,
                () => _pick(context, 'ให้${p.pinName}เรียกเราว่า',
                    ['พี่', 'คุณ', 'ท่าน'],
                    p.userCall,
                    (v) => _updatePersona(p.copyWith(userCall: v))),
              ),
              _navRow(
                context,
                LucideIcons.smile,
                '${p.pinName}แทนตัวเองว่า',
                p.pinSelf,
                () => _editText(context, '${p.pinName}แทนตัวเองว่า', p.pinSelf,
                    ['ปิ่น', 'หนู', 'ผม', 'เรา'],
                    (v) => _updatePersona(
                        p.copyWith(pinSelf: v.isEmpty ? 'ปิ่น' : v))),
              ),
              _navRow(
                context,
                LucideIcons.messageSquare,
                '${p.pinName}ลงท้ายว่า',
                p.pinEnding.isEmpty ? '(ไม่ลงท้าย)' : p.pinEnding,
                () => _editText(context, '${p.pinName}ลงท้ายประโยคว่า', p.pinEnding,
                    ['ครับ', 'คะ', 'จ้ะ', ''],
                    (v) => _updatePersona(p.copyWith(pinEnding: v))),
              ),
              ListTile(
                leading: const Icon(LucideIcons.sparkles),
                title: Text('ความสามารถของ${p.pinName}'),
                trailing: const Icon(LucideIcons.chevronRight, size: 18),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const AbilitiesScreen())),
              ),
            ]),
            _section('ทั่วไป'),
            _card([
              ListTile(
                leading: const Icon(LucideIcons.globe),
                title: const Text('ภาษา · Language'),
                trailing: _LangToggle(
                  lang: p.lang,
                  onChanged: (v) =>
                      PrefsController.instance.update(p.copyWith(lang: v)),
                ),
              ),
              ValueListenableBuilder<PinPalette>(
                valueListenable: ThemeController.instance,
                builder: (context, palette, _) => ListTile(
                  leading: const Icon(LucideIcons.palette),
                  title: const Text('ธีมสี'),
                  trailing: Text(palette.name,
                      style: const TextStyle(color: PinPalette.ink2)),
                  onTap: () => showThemePicker(context),
                ),
              ),
            ]),
            _section('สถานะความปลอดภัย'),
            _card([_SecurityStatus()]),
            _section('เครื่องมือนักพัฒนา'),
            _card([
              SwitchListTile(
                secondary: const Icon(LucideIcons.bug),
                title: const Text('ดีบักบอท'),
                subtitle: const Text(
                    'โชว์ขั้นตอนใต้คำตอบ + ส่งบทสนทนาให้ทีมพัฒนาดูเพื่อปรับปรุง '
                    '(ปิดการตาบอดชั่วคราว)'),
                value: p.debugBot,
                onChanged: (v) =>
                    PrefsController.instance.update(p.copyWith(debugBot: v)),
              ),
              ListTile(
                leading: const Icon(LucideIcons.activity),
                title: const Text('API call log'),
                subtitle: const Text('เวลาที่ใช้ของแต่ละ API (หา call ที่ช้า)'),
                trailing: const Icon(LucideIcons.chevronRight, size: 18),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const ApiLogScreen())),
              ),
            ]),
            _card([_E2eeDebug()]),
            _section('บัญชี'),
            _card([
              if (userId != null)
                ListTile(
                  leading: const Icon(LucideIcons.userCircle),
                  title: const Text('บัญชี'),
                  subtitle: Text(userId!,
                      style: const TextStyle(
                          color: PinPalette.ink2, fontSize: 12)),
                ),
              ListTile(
                leading: Icon(LucideIcons.logOut, color: scheme.error),
                title: Text('ออกจากระบบ',
                    style: TextStyle(
                        color: scheme.error, fontWeight: FontWeight.w600)),
                onTap: () => _logout(context),
              ),
            ]),
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
        rows.add(const Divider(height: 1, indent: 56, color: PinPalette.line));
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
            Text(value, style: const TextStyle(color: PinPalette.ink2)),
            const SizedBox(width: 4),
            const Icon(LucideIcons.chevronRight, size: 18),
          ],
        ),
        onTap: onTap,
      );

  void _pick(BuildContext context, String title, List<String> options,
      String current, ValueChanged<String> onPick) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(title, style: PinPalette.brand(size: 16)),
            ),
            for (final o in options)
              ListTile(
                title: Text(o),
                trailing: o == current
                    ? Icon(LucideIcons.check,
                        color: Theme.of(context).colorScheme.primary)
                    : null,
                onTap: () {
                  onPick(o);
                  Navigator.pop(context);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Free-text edit with quick preset chips (for pronoun / ending particle).
  void _editText(BuildContext context, String title, String current,
      List<String> presets, ValueChanged<String> onSave) {
    final ctl = TextEditingController(text: current);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(sheet).viewInsets.bottom + 16,
          top: 8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: PinPalette.brand(size: 16)),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              autofocus: true,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                for (final v in presets)
                  ActionChip(
                    label: Text(v.isEmpty ? 'ไม่ลงท้าย' : v),
                    onPressed: () => ctl.text = v,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  onSave(ctl.text.trim());
                  Navigator.pop(sheet);
                },
                child: const Text('บันทึก'),
              ),
            ),
          ],
        ),
      ),
    );
  }

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

class _LangToggle extends StatelessWidget {
  final String lang;
  final ValueChanged<String> onChanged;
  const _LangToggle({required this.lang, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget seg(String code, String label) {
      final on = lang == code;
      return GestureDetector(
        onTap: () => onChanged(code),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: on ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label,
              style: TextStyle(
                  color: on ? Colors.white : PinPalette.ink2,
                  fontWeight: FontWeight.w600,
                  fontSize: 12)),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [seg('th', 'TH'), seg('en', 'EN')],
      ),
    );
  }
}

/// Clean, user-facing E2EE status (not the debug dump): one row per protection
/// with a green check when active — recovery, server key backup, cross-signing,
/// device verification.
class _SecurityStatus extends StatefulWidget {
  @override
  State<_SecurityStatus> createState() => _SecurityStatusState();
}

class _SecurityStatusState extends State<_SecurityStatus> {
  Future<rust.E2eeStatus>? _future;

  @override
  void initState() {
    super.initState();
    _future = MatrixService.instance.e2eeStatus();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<rust.E2eeStatus>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const ListTile(
              dense: true, title: Text('กำลังอ่านสถานะ…'));
        }
        if (!snap.hasData) {
          return ListTile(
            dense: true,
            title: const Text('อ่านสถานะไม่ได้'),
            trailing: IconButton(
              icon: const Icon(LucideIcons.refreshCw, size: 18),
              onPressed: () => setState(
                  () => _future = MatrixService.instance.e2eeStatus()),
            ),
          );
        }
        final s = snap.data!;
        final hasRecovery = s.recovery == 'enabled';
        return Column(children: [
          _statusRow('รหัสกู้คืน', hasRecovery),
          _statusRow('สำรองคีย์บนเซิร์ฟเวอร์', hasRecovery),
          _statusRow('การลงนามข้ามอุปกรณ์', s.crossSigningReady),
          _statusRow('อุปกรณ์นี้ยืนยันแล้ว', s.deviceVerified),
          // Privacy is one more "protection" in the list — tap to slide up the
          // explanation (blind proxy / PII-aware tools / on-device memory).
          ListTile(
            leading: const Icon(LucideIcons.eyeOff,
                color: Color(0xFF2E9E63), size: 26),
            title: const Text('ความเป็นส่วนตัวของ AI',
                style:
                    TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            subtitle: const Text('AI ตาบอด · เครื่องมือเห็นแค่คำค้น',
                style: TextStyle(color: PinPalette.ink2, fontSize: 12)),
            trailing: const Icon(LucideIcons.chevronRight, size: 18),
            onTap: () => _showPrivacy(context),
          ),
        ]);
      },
    );
  }

  Widget _statusRow(String title, bool ok) => ListTile(
        leading: Icon(
          ok ? LucideIcons.checkCircle2 : LucideIcons.alertCircle,
          color: ok ? const Color(0xFF2E9E63) : const Color(0xFFE0A100),
          size: 26,
        ),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        subtitle: Text(ok ? 'เปิดใช้งาน' : 'ยังไม่เปิด',
            style: const TextStyle(color: PinPalette.ink2, fontSize: 12)),
      );

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
      appBar: AppBar(title: const Text('ความเป็นส่วนตัวของ AI')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: const [
          _PrivacyItem(LucideIcons.eyeOff, 'AI ไม่เห็นตัวตนคุณ',
              'ข้อความวิ่งผ่านพร็อกซีแบบ "ตาบอด" — ส่งต่อไปยังโมเดลเท่านั้น '
                  'ไม่เก็บ ไม่บันทึก log เนื้อหาบทสนทนา'),
          _PrivacyItem(LucideIcons.scissors, 'เครื่องมือเห็นแค่คำค้น',
              'tools / MCP / ผู้พัฒนาภายนอก ได้รับเฉพาะค่าที่จำเป็น '
                  '(เช่น ชื่อเมือง) ระบบตัดชื่อ บทสนทนา และการตั้งค่าส่วนตัว '
                  'ออกก่อนเสมอ'),
          _PrivacyItem(LucideIcons.smartphone, 'ความจำอยู่บนเครื่อง',
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
});

class _E2eeDebugState extends State<_E2eeDebug> {
  Future<_DebugData>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_DebugData> _load() async {
    final info = await PackageInfo.fromPlatform();
    final status = await MatrixService.instance.e2eeStatus();
    final roomId = await MatrixService.instance.pinRoomId();
    final members = roomId == null
        ? <String>[]
        : await MatrixService.instance.roomMembers(roomId).catchError((_) => <String>[]);
    return (
      appVersion: '${info.version} (${info.buildNumber})',
      status: status,
      roomId: roomId,
      members: members,
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
              icon: const Icon(LucideIcons.refreshCw, size: 18),
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
            LucideIcons.info,
            'เวอร์ชัน · สถานะระบบ',
            'รุ่น ${d.appVersion} · E2EE '
                '${d.status.crossSigningReady ? "พร้อม" : "ยังไม่พร้อม"}',
            nav: true,
            onTap: () => push(_DiagnosticsScreen(d)),
          ),
          if (_kDebugTools) ...[
          _div(),
          _tile(
            LucideIcons.cpu,
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
            LucideIcons.newspaper,
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
            LucideIcons.bell,
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
            LucideIcons.users,
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
          ],
          _div(),
          _tile(
            LucideIcons.database,
            'ข้อมูลในเครื่อง',
            'ดู/ล้าง ความจำ · ประวัติ · ความรู้ · การตั้งค่า',
            nav: true,
            onTap: () => push(const DeviceDataScreen()),
          ),
          _div(),
          _tile(
            LucideIcons.shieldAlert,
            'ตั้งค่า E2EE ใหม่',
            'ตั้งการลงนามข้ามอุปกรณ์/กุญแจใหม่ (ต้องใช้รหัสผ่าน)',
            danger: true,
            nav: true,
            onTap: () => push(const _E2eeResetScreen())
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
          (nav ? const Icon(LucideIcons.chevronRight, size: 18) : null),
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
          FilledButton.icon(
            icon: const Icon(LucideIcons.refreshCw, size: 16),
            label: const Text('รันอีกครั้ง'),
            onPressed: _running ? null : _go,
          ),
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
          FilledButton.icon(
            icon: const Icon(LucideIcons.copy, size: 16),
            label: const Text('คัดลอกทั้งหมด'),
            onPressed: () {
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
class _E2eeResetScreen extends StatefulWidget {
  const _E2eeResetScreen();

  @override
  State<_E2eeResetScreen> createState() => _E2eeResetScreenState();
}

class _E2eeResetScreenState extends State<_E2eeResetScreen> {
  final _pw = TextEditingController();
  bool _running = false;
  String? _key;
  String? _qrData; // combined QR payload (email + user key + ปิ่น key)
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  Future<void> _reset() async {
    if (_pw.text.isEmpty) return;
    setState(() {
      _running = true;
      _error = null;
      _key = null;
    });
    try {
      final key = await MatrixService.instance.resetRecovery(_pw.text);
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
      appBar: AppBar(title: const Text('ตั้งค่า E2EE ใหม่')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          const Text(
              'ตั้ง cross-signing + key backup ใหม่ (ต้องใช้รหัสผ่านบัญชี). '
              'จะได้กุญแจกู้คืนใหม่ — เก็บไว้ให้ดี',
              style: TextStyle(fontSize: 13, height: 1.45)),
          const SizedBox(height: 16),
          TextField(
            controller: _pw,
            obscureText: true,
            enabled: !_running && _key == null,
            decoration: const InputDecoration(
                labelText: 'รหัสผ่านบัญชี', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          if (_key == null)
            FilledButton(
              onPressed: _running ? null : _reset,
              child: Text(_running ? 'กำลังตั้งค่า…' : 'ตั้งค่าใหม่'),
            ),
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
            FilledButton.icon(
              icon: const Icon(LucideIcons.qrCode, size: 16),
              label: const Text('บันทึกเป็น QR'),
              onPressed: () => shareRecoveryQr(context, _qrData ?? _key!,
                  caption: MatrixService.instance.userEmail),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(LucideIcons.copy, size: 16),
              label: const Text('คัดลอกกุญแจ'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _key!));
                PinToast.show(context, 'คัดลอกแล้ว');
              },
            ),
          ],
        ],
      ),
    );
  }
}
