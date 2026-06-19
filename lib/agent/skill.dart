/// A skill = a prompt/knowledge pack (Claude `SKILL.md` shape). The body
/// (`instructions`) is injected into the system prompt when the skill is ON —
/// it runs on-device and never leaves the phone. `toolNames` are the tools the
/// skill leans on (they must exist in the registry / be installed).
class Skill {
  final String name;
  final String description;
  final String instructions;
  final List<String> toolNames;
  const Skill({
    required this.name,
    required this.description,
    required this.instructions,
    this.toolNames = const [],
  });
}

/// Built-in skills shipped with the app. More arrive later via `/catalog`.
const kBuiltinSkills = <Skill>[
  Skill(
    name: 'morning_news',
    description: 'สรุปข่าวเช้า',
    instructions:
        'เมื่อผู้ใช้ขอข่าว/สรุปข่าว ให้ค้นข่าวล่าสุดด้วย web_search แล้วสรุปเป็นหัวข้อ '
        'สั้น กระชับ พร้อมระบุที่มา. เลือกเฉพาะเรื่องที่ผู้ใช้น่าจะสนใจ.',
    toolNames: ['web_search'],
  ),
  Skill(
    name: 'researcher',
    description: 'ค้นคว้าเชิงลึก',
    instructions:
        'ถ้าคำถามต้องค้น/ประมวลหลายรอบกว่าจะตอบได้ครบ ให้ใช้ delegate ส่งงานไปยัง '
        'ผู้ช่วย researcher แทนการตอบเองทันที.',
    toolNames: ['delegate'],
  ),
];
