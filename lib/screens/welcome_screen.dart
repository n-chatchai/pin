import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../main.dart';
import '../services/prefs.dart';
import '../theme/pin_theme.dart';
import '../widgets/pin_button.dart';
import '../widgets/pin_route.dart';
import '../widgets/pin_scaffold.dart';
import 'auth_screen.dart';
import 'onboarding_screen.dart';

/// Landing before auth. New users go straight into a personalize-first
/// onboarding (account is created near the end, lowering the signup wall);
/// returning users tap "เข้าสู่ระบบ" for the login form. Material-free.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PinScaffold(
      child: ValueListenableBuilder<PinPrefs>(
          valueListenable: PrefsController.instance,
          builder: (context, prefs, _) {
            final en = prefs.lang == 'en';
            return Stack(
              children: [
                // English isn't ready yet — static badge, no toggle.
                Positioned(
                  top: 14,
                  right: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFFFFF),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: PinPalette.line),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.globe, size: 14, color: PinPalette.ink2),
                        SizedBox(width: 6),
                        Text('English coming soon',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: PinPalette.ink2)),
                      ],
                    ),
                  ),
                ),
                Padding(
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
                          style: PinPalette.brand(
                                  size: 38, color: PinPalette.ink)
                              .copyWith(
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1)),
                      const SizedBox(height: 10),
                      Text(
                          en
                              ? 'Your companion to remember,\nremind, and reflect'
                              : 'คู่หูที่คอยจำ เตือน\nและให้มุมมอง',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 16,
                              height: 1.5,
                              color: PinPalette.ink2)),
                      const Spacer(flex: 5),
                  PinButton(
                    en ? 'Get started' : 'เริ่มใช้งาน',
                    onTap: () => Navigator.of(context).push(
                      pinRoute(
                        OnboardingScreen(
                          signup: true,
                          onDone: () =>
                              Navigator.of(context).pushAndRemoveUntil(
                            pinRoute(const AfterAuth()),
                            (_) => false,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  PinButton.text(
                    en
                        ? 'I already have an account · Sign in'
                        : 'มีบัญชีอยู่แล้ว · เข้าสู่ระบบ',
                    onTap: () => Navigator.of(context)
                        .push(pinRoute(const AuthScreen())),
                  ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
    );
  }
}
