import '../services/matrix_service.dart';
import 'proxy_client.dart';

/// ปิ่น gateway (LLM proxy) base URL — HTTPS domain in front of the VPS proxy.
/// Override at build time with `--dart-define=PIN_PROXY_URL=...`.
const _kProxyBase = String.fromEnvironment(
  'PIN_PROXY_URL',
  defaultValue: 'https://pin-gateway.tokens2.io',
);

/// Persona built from the user's onboarding/settings choices (name · how ปิ่น
/// addresses them · how ปิ่น refers to itself · sentence ending particle).
String kPinSystemFor({
  String name = 'ปิ่น',
  String userCall = 'พี่',
  String self = 'ปิ่น',
  String ending = 'ค่ะ',
  String lang = 'th',
}) {
  if (lang == 'en') {
    final call = userCall.trim().isEmpty ? '' : ' Call the user "$userCall".';
    final me = self.trim().isEmpty ? '' : ' Refer to yourself as "$self".';
    return 'You are "$name", a warm but sharp personal assistant. Keep replies '
        'short (1–3 sentences).$call$me Never make up facts; if unsure, say so '
        'plainly. Never expose internal function names to the user.';
  }
  final end = ending.trim().isEmpty
      ? ''
      : 'ลงท้ายประโยคด้วย "${ending.trim()}" สม่ำเสมอ. ';
  return 'คุณคือ "$name" ผู้ช่วยส่วนตัวภาษาไทย อบอุ่นแต่คม สั้น 1–3 ประโยค. '
      'เรียกผู้ใช้ว่า "$userCall" และแทนตัวเองว่า "$self". $end'
      'ห้ามมโนข้อมูล ถ้าไม่รู้ให้บอกตรง ๆ. '
      'ห้ามเอ่ยชื่อฟังก์ชันภายในให้ผู้ใช้เห็น.';
}

/// Default persona (used where prefs aren't available, e.g. debug tests).
final kPinSystem = kPinSystemFor();

/// Builds a gateway client authed as the current user. The bearer is the live
/// Matrix access token (cached by [MatrixService] after login/restore); the
/// gateway validates it against the homeserver `whoami`. Empty if not logged in
/// — every caller is behind auth, so that should not happen in practice.
ProxyClient devProxy() => ProxyClient(
      baseUrl: _kProxyBase,
      token: MatrixService.instance.accessToken ?? '',
      tier: 'free',
    );
