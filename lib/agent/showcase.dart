/// First-run in-chat showcase tour. A scripted, guided conversation where ปิ่น
/// walks the user through what it can do — each step ends with quick-reply chips
/// that either run a real demo live, advance the tour, or open another screen.
///
/// Text uses {pinName} / {userCall} / {ending} placeholders, filled from the
/// user's persona by the chat screen (same as the server welcome).
library;

/// One quick-reply chip in the tour.
class TourChip {
  final String label;

  /// next  = post tour step [next]
  /// live  = send [payload] as a real message, then offer step [next]
  /// action= trigger a media action ('scan' | 'file'), then offer step [next]
  /// route = open another screen ('abilities'), then end the tour
  /// end   = finish the tour
  final String kind;
  final String payload;
  final int next; // step to continue to (live/action/next); -1 = none

  const TourChip(this.label,
      {this.kind = 'next', this.payload = '', this.next = -1});
}

/// One step in the tour: ปิ่น's line + the chips shown under it.
class TourStep {
  final String text;
  final List<TourChip> chips;
  const TourStep(this.text, this.chips);
}

/// The scripted conversation. Index 0 is the opener.
const List<TourStep> kTour = [
  // 0 — greeting + ask to start the tour
  TourStep(
    'สวัสดี! {pinName}พร้อมเป็นคู่หูช่วย{userCall}แล้ว — '
        'ขอเวลาสั้น ๆ พาดูว่าเราทำอะไรด้วยกันได้บ้าง เอาไหม{ending}',
    [
      TourChip('ดูเลย', kind: 'next', next: 1),
      TourChip('เริ่มคุยก่อน', kind: 'end'),
    ],
  ),
  // 1 — ask anything live (weather)
  TourStep(
    'อย่างแรก — ถามอะไรสด ๆ ได้เลย เช่น อากาศ 🌤️',
    [
      TourChip('อากาศวันนี้',
          kind: 'live', payload: 'อากาศกรุงเทพวันนี้เป็นยังไง', next: 2),
      TourChip('ถัดไป', kind: 'next', next: 2),
    ],
  ),
  // 2 — reminders & scheduled jobs
  TourStep(
    'ตั้งเตือนได้ เด้งแจ้งแม้ปิดจอ — หรือสั่งงานให้{pinName}ทำเองตามเวลา '
        'เช่น สรุปข่าวทุกเช้า ⏰',
    [
      TourChip('เตือนกินยา 20:00 ทุกวัน',
          kind: 'live', payload: 'เตือนกินยาทุกวัน 20:00', next: 3),
      TourChip('ถัดไป', kind: 'next', next: 3),
    ],
  ),
  // 3 — image generation
  TourStep(
    'วาดรูปจากคำพูดก็ได้ พิมพ์สั้น ๆ พอ 🎨',
    [
      TourChip('วาดรูปแมวนักบินอวกาศ',
          kind: 'live', payload: 'วาดรูปแมวนักบินอวกาศ', next: 4),
      TourChip('ถัดไป', kind: 'next', next: 4),
    ],
  ),
  // 4 — remember facts / knowledge
  TourStep(
    'บอกให้จำเรื่องสำคัญ แล้วดึงมาใช้ทีหลังได้ 📌',
    [
      TourChip('จำไว้ว่าฉันแพ้กุ้ง',
          kind: 'live', payload: 'จำไว้นะว่าฉันแพ้กุ้ง', next: 5),
      TourChip('ถัดไป', kind: 'next', next: 5),
    ],
  ),
  // 5 — summarise a file/document
  TourStep(
    'ส่งเอกสาร/รูปที่มีตัวหนังสือมา {pinName} อ่าน สรุปสั้น ๆ แล้วจำไว้ให้ '
        'ดึงมาใช้ทีหลังได้ 📄',
    [
      TourChip('ส่งเอกสาร/รูป', kind: 'action', payload: 'scan', next: 6),
      TourChip('ถัดไป', kind: 'next', next: 6),
    ],
  ),
  // 6 — voice note → transcript + summary (hold-to-record, can't auto-trigger)
  TourStep(
    'พูดมาได้เลย — กดค้างที่ปุ่มไมค์ 🎙️ แล้วพูด {pinName} ถอดความ + '
        'สรุปประเด็นให้ เก็บไว้ในแท็บ "ไฟล์"',
    [
      TourChip('ถัดไป', kind: 'next', next: 7),
    ],
  ),
  // 7 — live info / news
  TourStep(
    'หาข้อมูลสด สรุปข่าว ย่อบทความให้ 📰',
    [
      TourChip('สรุปข่าวเด่นวันนี้',
          kind: 'live', payload: 'สรุปข่าวเด่นวันนี้ให้หน่อย', next: 8),
      TourChip('ถัดไป', kind: 'next', next: 8),
    ],
  ),
  // 8 — wrap up
  TourStep(
    'ยังมีอีก เช่น อัตราแลกเปลี่ยน · ค้นเชิงลึก · ทำการ์ดสรุป — เปิดเพิ่มได้ที่ '
        'หน้า "ความสามารถ". ตอนนี้พิมพ์อะไรก็ได้เลย{ending}',
    [
      TourChip('เปิดหน้าความสามารถ', kind: 'route', payload: 'abilities'),
      TourChip('เริ่มใช้เลย', kind: 'end'),
    ],
  ),
];
