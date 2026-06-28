import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../config.dart';
import '../main.dart';
import '../services/auth_service.dart';
import '../theme/pin_theme.dart';
import '../widgets/google_sign_in_button.dart';
import '../widgets/pin_button.dart';
import '../widgets/pin_field.dart';
import '../widgets/pin_route.dart';
import 'onboarding_screen.dart';

const _homeserver = kHomeserver;

/// Brand green (matches the app icon + theme). Accent for the sign-in action.
const kPinGreen = Color(0xFF34B06A);

/// Single auth page: login and register share one screen, toggled in place (the
/// two read identically, so a mode switch beats a second route). Register success
/// continues into the recovery onboarding; login goes straight to the app.
class AuthScreen extends StatefulWidget {
  /// Start in register mode (e.g. from the welcome "เริ่มใช้งาน" button).
  final bool initialRegister;
  const AuthScreen({super.key, this.initialRegister = false});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  late bool _register = widget.initialRegister;

  void _toggle() => setState(() => _register = !_register);

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
                              style: PinPalette.brand(
                                      size: 34, color: PinPalette.ink)
                                  .copyWith(
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 1)),
                          const SizedBox(height: 8),
                          const Text('คู่หูที่คอยจำ เตือน และให้มุมมอง',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 15, color: PinPalette.ink2)),
                          const Spacer(flex: 2),
                          // Username / password form (login or register).
                          _AuthForm(register: _register),
                          const SizedBox(height: 16),
                          // Toggle the mode in place.
                          GestureDetector(
                            onTap: _toggle,
                            child: Text.rich(
                              TextSpan(
                                style: const TextStyle(
                                    fontSize: 14, color: PinPalette.ink2),
                                children: [
                                  TextSpan(
                                      text: _register
                                          ? 'มีบัญชีอยู่แล้ว? '
                                          : 'ยังไม่มีบัญชี? '),
                                  TextSpan(
                                      text:
                                          _register ? 'เข้าสู่ระบบ' : 'สมัครเลย',
                                      style: const TextStyle(
                                          color: kPinGreen,
                                          fontWeight: FontWeight.w700)),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 36),
                          Row(children: [
                            const Expanded(
                                child: Divider(color: PinPalette.line)),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              child: Text('หรือ',
                                  style: TextStyle(
                                      fontSize: 13.5, color: PinPalette.ink2)),
                            ),
                            const Expanded(
                                child: Divider(color: PinPalette.line)),
                          ]),
                          const SizedBox(height: 16),
                          const GoogleSignInButton(),
                          const Spacer(flex: 3),
                          const Text(
                              'ดำเนินการต่อ = ยอมรับข้อตกลงการใช้งาน และนโยบายความเป็นส่วนตัว',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 11, color: PinPalette.ink2)),
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

/// Username + password form. [register] flips the action: register-with-username
/// (+ realtime availability check) → recovery onboarding, vs sign-in → the app.
/// Kept mounted across a mode toggle so a typed username survives the switch.
class _AuthForm extends StatefulWidget {
  final bool register;
  const _AuthForm({required this.register});

  @override
  State<_AuthForm> createState() => _AuthFormState();
}

class _AuthFormState extends State<_AuthForm> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _auth = AuthService();
  bool _busy = false;
  String? _error;
  Timer? _debounce; // realtime username-availability check (register only)
  bool? _taken; // true = username already registered, null = unknown/typing

  @override
  void didUpdateWidget(_AuthForm old) {
    super.didUpdateWidget(old);
    // Mode toggled → clear the other mode's error/availability state so nothing
    // stale carries over (height is already constant, so no shift either way).
    if (old.register != widget.register) {
      _debounce?.cancel();
      setState(() {
        _error = null;
        _taken = null;
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _onNameChanged(String v) {
    if (!widget.register) return;
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
      if (widget.register) {
        await _auth.registerWithUsername(
          homeserver: _homeserver,
          username: _username.text.trim(),
          password: _password.text,
        );
        if (!mounted) return;
        // New account → continue into the recovery onboarding, then the app.
        Navigator.of(context).push(pinRoute(OnboardingScreen(
          onDone: () => Navigator.of(context).pushAndRemoveUntil(
            pinRoute(const AfterAuth()),
            (_) => false,
          ),
        )));
      } else {
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
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reg = widget.register;
    final blocked = _busy || (reg && _taken == true);
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
          onChanged: _onNameChanged,
        ),
        // Constant-height slot in BOTH modes so toggling login⇄register doesn't
        // shift the layout. Holds the register-only availability hint.
        SizedBox(
          height: 26,
          child: Padding(
            padding: const EdgeInsets.only(top: 8, left: 4),
            child: (reg && _taken == true)
                ? const Text('ชื่อนี้มีคนใช้แล้ว — เข้าสู่ระบบด้านล่าง',
                    style: TextStyle(fontSize: 12, color: Color(0xFFC0392B)))
                : const SizedBox.shrink(),
          ),
        ),
        PinField(
          controller: _password,
          enabled: !_busy,
          placeholder: 'รหัสผ่าน',
          icon: PhosphorIconsLight.lockSimple,
          obscure: true,
          onSubmitted: () => blocked ? null : _go(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: PinPalette.neg)),
        ],
        const SizedBox(height: 16),
        PinButton(reg ? 'สมัครและไปต่อ' : 'เข้าสู่ระบบ',
            busy: _busy, onTap: blocked ? null : _go),
      ],
    );
  }
}
