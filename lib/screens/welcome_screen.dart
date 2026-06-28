import 'package:flutter/widgets.dart';

import '../theme/pin_theme.dart';
import '../widgets/pin_button.dart';
import '../widgets/pin_route.dart';
import '../widgets/pin_scaffold.dart';
import 'auth_screen.dart';

/// Landing before auth. New users go straight into a personalize-first
/// onboarding (account is created near the end, lowering the signup wall);
/// returning users tap "เข้าสู่ระบบ" for the login form. Thai-only for now.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PinScaffold(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        child: Column(
          children: [
            const Spacer(flex: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Image.asset('assets/pin-logo.png',
                  width: 96, height: 96, fit: BoxFit.cover),
            ),
            const SizedBox(height: 22),
            Text('ปิ่น',
                style: PinPalette.brand(size: 38, color: PinPalette.ink)
                    .copyWith(fontWeight: FontWeight.w600, letterSpacing: 1)),
            const SizedBox(height: 10),
            const Text('คู่หูที่คอยจำ เตือน\nและให้มุมมอง',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 16, height: 1.5, color: PinPalette.ink2)),
            const Spacer(flex: 5),
            PinButton(
              'เริ่มใช้งาน',
              onTap: () => Navigator.of(context)
                  .push(pinRoute(const AuthScreen(initialRegister: true))),
            ),
            const SizedBox(height: 12),
            PinButton.text(
              'มีบัญชีอยู่แล้ว · เข้าสู่ระบบ',
              onTap: () =>
                  Navigator.of(context).push(pinRoute(const AuthScreen())),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
