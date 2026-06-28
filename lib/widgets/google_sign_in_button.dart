import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../main.dart';
import '../services/matrix_service.dart';
import 'pin_button.dart';
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
    return PinButton.outlined(
      'เข้าสู่ระบบด้วย Google',
      busy: _busy,
      onTap: _go,
      icon: SvgPicture.asset('assets/google-g.svg', width: 20, height: 20),
    );
  }
}
