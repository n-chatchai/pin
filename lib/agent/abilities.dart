import 'package:flutter/widgets.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

/// How a capability is priced. `free` = add yourself; `onetime` = buy once;
/// `subscription` = recurring. Drives the action button in the abilities UI.
class Pricing {
  final String tier; // free | onetime | subscription
  final int amount;
  final String currency;
  final String period; // month | year | ''
  const Pricing({
    this.tier = 'free',
    this.amount = 0,
    this.currency = 'THB',
    this.period = '',
  });

  bool get isFree => tier == 'free';

  static Pricing fromJson(Map? j) => j == null
      ? const Pricing()
      : Pricing(
          tier: '${j['tier'] ?? 'free'}',
          amount: (j['amount'] is num) ? (j['amount'] as num).toInt() : 0,
          currency: '${j['currency'] ?? 'THB'}',
          period: '${j['period'] ?? ''}',
        );

  /// Short price label, e.g. "ฟรี" · "฿49" · "฿59/เดือน".
  String get label => switch (tier) {
        'onetime' => '฿$amount',
        'subscription' => '฿$amount/${period == 'year' ? 'ปี' : 'เดือน'}',
        _ => 'ฟรี',
      };
}

/// A consumer-facing capability ("ความสามารถ") — the plain-language wrapper the
/// app shows instead of tool/skill/mcp/subagent. Built-ins are on-device; the
/// rest come from the proxy catalog's display metadata.
class Ability {
  final String name;
  final String label;
  final String blurb;
  final IconData icon;
  final String group; // 'ready' (toggle) | 'connect' (needs an account)
  final String category;
  final String instructions; // injected into the persona when this is enabled
  final String provider; // who supplies it (Google / Notion / ปิ่น)
  final String source; // 'builtin' (in-app) | 'hosted' (ปิ่น server) | 'mcp'
  final Pricing pricing;
  const Ability({
    required this.name,
    required this.label,
    required this.blurb,
    required this.icon,
    this.group = 'ready',
    this.category = 'อื่น ๆ',
    this.instructions = '',
    this.provider = '',
    this.source = 'builtin',
    this.pricing = const Pricing(),
  });

  bool get needsConnect => group == 'connect';

  /// Short Thai label for where the capability runs/comes from.
  String get sourceLabel => switch (source) {
        'mcp' => provider.isEmpty ? 'เชื่อมต่อ' : provider,
        'hosted' => 'เซิร์ฟเวอร์ปิ่น',
        _ => 'ในแอป',
      };

  static IconData iconFor(String? key) => switch (key) {
        'cloud' => PhosphorIconsRegular.cloud,
        'coins' => PhosphorIconsRegular.coins,
        'search' => PhosphorIconsRegular.magnifyingGlass,
        'newspaper' => PhosphorIconsRegular.newspaper,
        'brain' => PhosphorIconsRegular.brain,
        'mail' => PhosphorIconsRegular.envelope,
        'calendar' => PhosphorIconsRegular.calendar,
        'book' => PhosphorIconsRegular.bookOpen,
        'bell' => PhosphorIconsRegular.bell,
        'pin' => PhosphorIconsRegular.pushPin,
        _ => PhosphorIconsRegular.sparkle,
      };

  static Ability fromManifest(Map<String, dynamic> m) => Ability(
        name: '${m['name']}',
        label: '${m['label'] ?? m['name']}',
        blurb: '${m['blurb'] ?? m['description'] ?? ''}',
        icon: iconFor(m['icon'] as String?),
        // MCP tools usually need an account → default them to "connect".
        group: '${m['group'] ?? (m['kind'] == 'mcp' ? 'connect' : 'ready')}',
        category: '${m['category'] ?? (m['kind'] == 'mcp' ? 'เชื่อมบัญชี' : 'อื่น ๆ')}',
        provider: '${m['provider'] ?? ''}',
        source: m['kind'] == 'mcp' ? 'mcp' : 'hosted',
        pricing: Pricing.fromJson(m['pricing'] as Map?),
      );
}

/// Catalog tool/skill/subagent name → Thai label, populated at runtime from the
/// proxy catalog so dynamic capabilities (news_reporter, thai_astrology, …) show
/// a Thai name in the hint instead of their raw English id.
final Map<String, String> _runtimeLabels = {};
void registerAbilityLabels(Map<String, String> labels) {
  labels.forEach((k, v) {
    if (v.trim().isNotEmpty) _runtimeLabels[k] = v;
  });
}

/// Friendly Thai label for a tool name — used for the "ใช้ความสามารถ" hint
/// under a reply. Built-ins first, then the catalog, then the raw name.
String abilityLabel(String tool) =>
    const {
      'get_weather': 'พยากรณ์อากาศ',
      'get_currency': 'อัตราแลกเปลี่ยน',
      'web_search': 'ค้นข้อมูลในเว็บ',
      'schedule_reminder': 'ตั้งเตือน',
      'schedule_job': 'ตั้งงานอัตโนมัติ',
      'remember_fact': 'จำเรื่องให้',
      'recall_knowledge': 'ค้นความรู้',
      'save_knowledge': 'บันทึกความรู้',
      'generate_image': 'วาดรูป',
      'render_html': 'ทำการ์ด',
      'delegate': 'ค้นเชิงลึก',
      'get_time': 'ดูเวลา',
    }[tool] ??
    _runtimeLabels[tool] ??
    tool;

/// On-device abilities the app always knows about (not in the catalog).
const kBuiltinAbilities = <Ability>[
  Ability(
      name: 'schedule_reminder',
      label: 'เตือนความจำ',
      blurb: 'ตั้งเตือน เด้งแจ้งเตือนแม้ปิดจอ',
      icon: PhosphorIconsRegular.bell,
      category: 'ผู้ช่วยส่วนตัว'),
  Ability(
      name: 'remember_fact',
      label: 'จำเรื่องของคุณ',
      blurb: 'จดจำสิ่งสำคัญเกี่ยวกับคุณ',
      icon: PhosphorIconsRegular.pushPin,
      category: 'ผู้ช่วยส่วนตัว'),
  Ability(
      name: 'recall_knowledge',
      label: 'ค้นความรู้ที่เก็บไว้',
      blurb: 'หยิบสิ่งที่เคยบันทึกมาใช้',
      icon: PhosphorIconsRegular.bookOpen,
      category: 'ผู้ช่วยส่วนตัว'),
];

/// Free add-ons the user can switch on themselves. Default OFF; enabling one
/// injects its `instructions` into the persona (on-device, free).
const kFreeAbilities = <Ability>[
  Ability(
      name: 'morning_news',
      label: 'สรุปข่าวเช้า',
      blurb: 'ค้นข่าวล่าสุดแล้วสรุปให้',
      icon: PhosphorIconsRegular.newspaper,
      category: 'ฟรี',
      instructions:
          'เมื่อผู้ใช้ขอข่าว/สรุปข่าว ให้ค้นข่าวล่าสุดด้วย web_search แล้วสรุปเป็นหัวข้อสั้น พร้อมที่มา.'),
  Ability(
      name: 'deep_research',
      label: 'ค้นข้อมูลเชิงลึก',
      blurb: 'หาหลายแหล่งแล้วสรุปให้',
      icon: PhosphorIconsRegular.brain,
      category: 'ฟรี',
      instructions:
          'ถ้าคำถามต้องค้น/ประมวลหลายรอบ ให้ใช้ delegate ส่งงานไปยังผู้ช่วย researcher.'),
  Ability(
      name: 'encourage',
      label: 'ให้กำลังใจ',
      blurb: 'พูดให้กำลังใจเวลาเหนื่อย',
      icon: PhosphorIconsRegular.heart,
      category: 'ฟรี',
      instructions:
          'เมื่อผู้ใช้ดูเครียดหรือเหนื่อย ให้พูดให้กำลังใจสั้น ๆ อย่างจริงใจก่อนช่วยงาน.'),
  Ability(
      name: 'tldr_link',
      label: 'ย่อลิงก์',
      blurb: 'สรุปบทความจากลิงก์',
      icon: PhosphorIconsRegular.link,
      category: 'ฟรี',
      instructions:
          'เมื่อผู้ใช้ส่งลิงก์มา ให้ค้นเนื้อหาด้วย web_search แล้วสรุปประเด็นหลักสั้น ๆ.'),
];

/// Teaser capabilities not yet available — shown locked with a "ซื้อ · เร็ว ๆ นี้"
/// button. Filtered out automatically once the same name appears in the catalog.
///
/// Only list what a bare LLM CAN'T do on its own — account integrations, live
/// data, real automation. Generic text tasks (translate / summarize / rewrite)
/// are NOT products here; ปิ่น does those as base behavior, so they don't earn a
/// store row. (Dropped: translate, สรุปเอกสาร — LLM-native; Notion — low TH use.)
const kComingSoonAbilities = <Ability>[
  Ability(
      name: 'email',
      label: 'อีเมล',
      blurb: 'อ่าน คัดกรอง และร่างตอบอีเมลให้',
      icon: PhosphorIconsRegular.envelope,
      group: 'connect',
      category: 'เชื่อมบัญชี',
      provider: 'Google',
      pricing: Pricing(tier: 'subscription', amount: 59, period: 'month')),
  Ability(
      name: 'calendar',
      label: 'ปฏิทิน',
      blurb: 'หาเวลาว่าง สร้างนัด เตือนล่วงหน้า',
      icon: PhosphorIconsRegular.calendar,
      group: 'connect',
      category: 'เชื่อมบัญชี',
      provider: 'Google',
      pricing: Pricing(tier: 'subscription', amount: 59, period: 'month')),
  Ability(
      name: 'trip',
      label: 'วางแผนทริป',
      blurb: 'หาเที่ยวบิน อากาศ แล้วร่างแผน',
      icon: PhosphorIconsRegular.mapTrifold,
      category: 'ชีวิตประจำวัน',
      provider: 'ปิ่น',
      pricing: Pricing(tier: 'subscription', amount: 39, period: 'month')),
];
