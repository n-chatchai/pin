import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../main.dart';
import '../services/matrix_service.dart';
import '../theme/pin_theme.dart';
import 'pin_route.dart';
import 'pin_toast.dart';

/// "เข้าสู่ระบบด้วย Google" — runs the Matrix SSO flow (loginWithGoogle) then
/// goes to AfterAuth. Used on both the login and register screens. Shows the
/// official 4-color Google "G".
class GoogleSignInButton extends StatefulWidget {
  const GoogleSignInButton({super.key});

  @override
  State<GoogleSignInButton> createState() => _GoogleSignInButtonState();
}

class _GoogleSignInButtonState extends State<GoogleSignInButton> {
  bool _busy = false;

  Future<void> _go() async {
    setState(() => _busy = true);
    debugPrint('[sso] button tapped → loginWithGoogle');
    try {
      await MatrixService.instance.loginWithGoogle();
      debugPrint('[sso] loginWithGoogle returned → navigate AfterAuth');
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
          pinRoute(const AfterAuth()), (_) => false);
    } catch (e) {
      debugPrint('[sso] loginWithGoogle threw: $e');
      if (e.toString().contains('CANCELED')) return;
      if (mounted) {
        PinToast.show(context, e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: _busy ? null : _go,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        side: const BorderSide(color: PinPalette.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        foregroundColor: PinPalette.ink,
      ),
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
          : SvgPicture.asset('assets/google-g.svg', width: 20, height: 20),
      label: const Text('เข้าสู่ระบบด้วย Google',
          style: TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}
