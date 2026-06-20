import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../config.dart';
import '../main.dart';
import '../services/auth_service.dart';
import '../theme/pin_theme.dart';
import '../widgets/pin_button.dart';
import '../widgets/pin_field.dart';
import '../widgets/pin_route.dart';
import 'onboarding_screen.dart';

const _homeserver = kHomeserver;

/// Brand green (matches the app icon + theme). Accent for the sign-in action.
const kPinGreen = Color(0xFF34B06A);

/// Auth entry. Only username/password (email) works for now; Apple / Google /
/// LINE / Facebook are shown as "เร็ว ๆ นี้" (need OAuth bridges, not yet wired).
class AuthScreen extends StatelessWidget {
  const AuthScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Warm cream — tonal, not the muddy green-grey surface.
      backgroundColor: const Color(0xFFFBF8F1),
      body: SafeArea(
        child: Stack(
          children: [
            // Back affordance only when there's somewhere to go back to (this
            // screen can be the root, e.g. after logout) — no dead button.
            if (Navigator.of(context).canPop())
              Positioned(
                top: 0,
                left: 4,
                child: IconButton(
                  icon: const Icon(Icons.chevron_left, color: PinPalette.ink2),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            LayoutBuilder(
          builder: (context, c) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: c.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                  child: Column(
                    children: [
                      const Spacer(flex: 3),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(22),
                        child: Image.asset('assets/pin-logo.png',
                            width: 88, height: 88, fit: BoxFit.cover),
                      ),
                      const SizedBox(height: 20),
                      Text('ปิ่น',
                          style: PinPalette.brand(size: 34, color: PinPalette.ink)
                              .copyWith(
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1)),
                      const SizedBox(height: 8),
                      const Text('คู่หูที่คอยจำ เตือน และให้มุมมอง',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 15, color: PinPalette.ink2)),
                      const Spacer(flex: 2),
                      // Username / password form, shown directly.
                      const _EmailForm(),
                      const SizedBox(height: 16),
                      // No account yet → jump to the signup flow.
                      GestureDetector(
                        onTap: () => Navigator.of(context).push(pinRoute(
                          OnboardingScreen(
                            signup: true,
                            onDone: () =>
                                Navigator.of(context).pushAndRemoveUntil(
                              pinRoute(const AfterAuth()),
                              (_) => false,
                            ),
                          ),
                        )),
                        child: Text.rich(
                          TextSpan(
                            style: const TextStyle(
                                fontSize: 14, color: PinPalette.ink2),
                            children: const [
                              TextSpan(text: 'ยังไม่มีบัญชี? '),
                              TextSpan(
                                  text: 'สมัครเลย',
                                  style: TextStyle(
                                      color: kPinGreen,
                                      fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 36),
                      Row(children: [
                        const Expanded(child: Divider(color: PinPalette.line)),
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          child: Text('ช่องทางอื่น · เร็ว ๆ นี้',
                              style: TextStyle(
                                  fontSize: 13.5, color: PinPalette.ink2)),
                        ),
                        const Expanded(child: Divider(color: PinPalette.line)),
                      ]),
                      const Spacer(flex: 3),
                      const Text(
                          'ดำเนินการต่อ = ยอมรับข้อตกลงการใช้งาน และนโยบายความเป็นส่วนตัว',
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(fontSize: 11, color: PinPalette.ink2)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          ),
          ],
        ),
      ),
    );
  }
}

class _EmailForm extends StatefulWidget {
  const _EmailForm();

  @override
  State<_EmailForm> createState() => _EmailFormState();
}

class _EmailFormState extends State<_EmailForm> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _auth = AuthService();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _auth.signInWithUsername(
        homeserver: _homeserver,
        username: _username.text.trim(),
        password: _password.text,
      );
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        pinRoute(const AfterAuth()),
        (_) => false,
      );
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PinField(
          controller: _username,
          enabled: !_busy,
          placeholder: 'ชื่อผู้ใช้',
          icon: PhosphorIconsLight.user,
          keyboardType: TextInputType.text,
        ),
        const SizedBox(height: 14),
        PinField(
          controller: _password,
          enabled: !_busy,
          placeholder: 'รหัสผ่าน',
          icon: PhosphorIconsLight.lockSimple,
          obscure: true,
          onSubmitted: () => _busy ? null : _go(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: PinPalette.neg)),
        ],
        const SizedBox(height: 16),
        PinButton('เข้าสู่ระบบ', busy: _busy, onTap: _go),
      ],
    );
  }
}
