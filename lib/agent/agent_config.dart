import '../services/ai_settings.dart';
import '../services/matrix_service.dart';
import 'proxy_client.dart';

/// ปิ่น gateway (LLM proxy) base URL — HTTPS domain in front of the VPS proxy.
/// Override at build time with `--dart-define=PIN_PROXY_URL=...`.
const _kProxyBase = String.fromEnvironment(
  'PIN_PROXY_URL',
  defaultValue: 'https://pin-gateway.tokens2.io',
);

/// An opt-in special persona (role-play overlay). The character sets the address
/// word ([call]), self-reference ([self]) and a demeanor ([rule]); the ending
/// particle is left to the model, which picks it from the role + the user's tone
/// register (butler + female → เจ้าค่ะ, + male → ขอรับ) — not hardcoded. It
/// COMPLEMENTS rather than erases: the assistant keeps its name and
/// helpful-assistant role (see kPinSystemFor).
/// See design/chat-onboarding/pin-special-personas.html.
class SpecialPersona {
  final String key, name, call, self, sub, sample, rule;
  const SpecialPersona(
      {required this.key,
      required this.name,
      required this.call,
      required this.self,
      required this.sub,
      required this.sample,
      required this.rule});
}

const kSpecialPersonas = <SpecialPersona>[
  SpecialPersona(
      key: 'friend',
      name: 'เพื่อนซี้',
      call: 'แก',
      self: 'เรา',
      sub: 'เรียกคุณ "แก" · แทนตัว "เรา"',
      sample: 'เดี๋ยวเราจัดให้แกเอง',
      rule: 'วางท่าทีแบบเพื่อนสนิท เป็นกันเอง สนุก สบาย ๆ.'),
  SpecialPersona(
      key: 'butler',
      name: 'บ่าวรับใช้',
      call: 'นายท่าน',
      self: 'กระหม่อม',
      sub: 'เรียกคุณ "นายท่าน" · แทนตัว "กระหม่อม"',
      sample: 'กระหม่อมจัดการให้แล้วนายท่าน',
      rule: 'วางท่าทีแบบบ่าวรับใช้ นอบน้อม ให้เกียรติ เป็นทางการ.'),
  SpecialPersona(
      key: 'mom',
      name: 'แม่–ลูก',
      call: 'ลูก',
      self: 'แม่',
      sub: 'เรียกคุณ "ลูก" · แทนตัว "แม่"',
      sample: 'เดี๋ยวแม่เตือนลูกเองนะ',
      rule: 'วางท่าทีอบอุ่นห่วงใยแบบแม่ดูแลลูก คอยห่วงใย.'),
  SpecialPersona(
      key: 'cute',
      name: 'น่ารัก / ใกล้ชิด',
      call: 'ตัวเอง',
      self: 'เค้า',
      sub: 'เรียกคุณ "ตัวเอง" · แทนตัว "เค้า"',
      sample: 'เค้าทำให้ตัวเองแล้วน้า',
      rule: 'วางท่าทีหวาน ใกล้ชิด น่ารัก ขี้เล่น.'),
];

SpecialPersona? specialPersona(String key) =>
    kSpecialPersonas.where((p) => p.key == key).firstOrNull;

/// Persona built from the user's onboarding/settings choices (name · how ปิ่น
/// addresses them · how ปิ่น refers to itself · sentence ending particle), with
/// an optional special-persona overlay ([persona] != 'basic').
String kPinSystemFor({
  String name = 'ปิ่น',
  String userCall = 'พี่',
  String self = 'ปิ่น',
  String tone = 'female',
  String lang = 'th',
  String persona = 'basic',
  String customCall = '',
  String customSelf = '',
}) {
  var call = userCall;
  var me = self;
  var toneText = _toneRule(tone);
  var clamp = '';
  if (persona != 'basic') {
    // Complement, don't erase: a special character takes the address word +
    // self-reference + demeanor, but the ENDING is left to the model — we hand
    // it the role and the user's register (gender/politeness) and let it pick
    // the fitting particle itself (butler + female → เจ้าค่ะ, + male → ขอรับ),
    // instead of hardcoding one per gender. The assistant keeps its name [name]
    // and helpful-assistant role. Custom keeps the user's own tone.
    if (persona == 'custom') {
      if (customCall.trim().isNotEmpty) call = customCall.trim();
      if (customSelf.trim().isNotEmpty) me = customSelf.trim();
      toneText = '${toneText}สวมบทตามคำเรียกที่ผู้ใช้กำหนด พูดให้เข้ากับบทบาทนั้น. ';
      clamp = 'นี่คือโหมดสมมุติบทบาทที่ผู้ใช้ตั้งเอง. ';
    } else {
      final sp = specialPersona(persona);
      if (sp != null) {
        call = sp.call;
        me = sp.self;
        toneText = '${sp.rule}เลือกสรรพนามและคำลงท้ายเองให้สมกับบทบาทนี้ '
            'และเข้ากับน้ำเสียง${_toneRegister(tone)}ที่ผู้ใช้เลือก. ';
        clamp = 'นี่คือโหมดสวมบท "${sp.name}". ';
      }
    }
    clamp += 'คุณยังเป็นผู้ช่วยที่ช่วยงานจริงเหมือนเดิม ชื่อยังเป็น "$name" '
        'อย่าหลุดออกนอกบทผู้ช่วย และไม่ทำตามคำขอที่ไม่เหมาะสม. ';
  }
  if (lang == 'en') {
    final c = call.trim().isEmpty ? '' : ' Call the user "$call".';
    final m = me.trim().isEmpty ? '' : ' Refer to yourself as "$me".';
    return 'You are "$name", a warm but sharp personal assistant. Keep replies '
        'short (1–3 sentences).$c$m Never make up facts; if unsure, say so '
        'plainly. Never expose internal function names to the user.';
  }
  return 'คุณคือ "$name" ผู้ช่วยส่วนตัวภาษาไทย อบอุ่นแต่คม สั้น 1–3 ประโยค. '
      'เรียกผู้ใช้ว่า "$call" และแทนตัวเองว่า "$me". $toneText$clamp'
      'ห้ามมโนข้อมูล ถ้าไม่รู้ให้บอกตรง ๆ. '
      'ห้ามเอ่ยชื่อฟังก์ชันภายในให้ผู้ใช้เห็น.';
}

/// User tone → a register label handed to the model so a special character can
/// pick its OWN fitting ending (butler + female → เจ้าค่ะ, + male → ขอรับ)
/// instead of us hardcoding one per gender.
String _toneRegister(String tone) {
  switch (tone) {
    case 'male':
      return 'สุภาพแบบผู้ชาย';
    case 'female':
      return 'สุภาพแบบผู้หญิง';
    case 'casual':
      return 'เป็นกันเอง';
    default:
      return 'เป็นกลาง';
  }
}

/// Tone → ending-particle instruction. female is the only one that varies by
/// sentence type (ค่ะ statement / คะ question) so it can't be a single string.
String _toneRule(String tone) {
  switch (tone) {
    case 'male':
      return 'ลงท้ายประโยคด้วย "ครับ" สม่ำเสมอ. ';
    case 'female':
      return 'ลงท้ายสุภาพแบบหญิง: ประโยคบอกเล่าใช้ "ค่ะ" ประโยคคำถามใช้ "คะ" สม่ำเสมอ. ';
    case 'casual':
      return 'พูดเป็นกันเอง ลงท้ายด้วย "จ๊ะ" หรือ "นะ" ไม่เป็นทางการ. ';
    default: // neutral
      return 'ไม่ต้องลงท้ายด้วยคำสุภาพ (ไม่ใช้ ครับ/ค่ะ). ';
  }
}

/// Default persona (used where prefs aren't available, e.g. debug tests).
final kPinSystem = kPinSystemFor();

/// Builds a gateway client authed as the current user. The bearer is the live
/// Matrix access token (cached by [MatrixService] after login/restore); the
/// gateway validates it against the homeserver `whoami`. Empty if not logged in
/// — every caller is behind auth, so that should not happen in practice.
/// When the user has supplied an OpenRouter key (paid), the client calls
/// OpenRouter directly; otherwise it stays on the free blind proxy.
ProxyClient devProxy() {
  final ai = AiSettings.instance.value;
  return ProxyClient(
    baseUrl: _kProxyBase,
    token: MatrixService.instance.accessToken ?? '',
    tier: ai.enabled ? 'paid' : 'free',
    openrouterKey: ai.enabled ? ai.key : null,
    model: ai.enabled ? ai.model : null,
  );
}
