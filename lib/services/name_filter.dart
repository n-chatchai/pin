/// Name guard for the onboarding persona inputs (assistant name, the user's
/// name, the address word). Because ปิ่น *speaks these out loud in every reply*,
/// junk / abusive / prompt-injection names must be caught.
///
/// Two layers: cheap LOCAL checks (empty / symbols-only / too long) run instantly
/// with no network; the semantic call (profanity / injection) is judged by the
/// LLM via the proxy (ProxyClient.moderateName) — no blocklist to maintain, and
/// it handles Thai slang / context / leetspeak better than a static list.
library;

const int kNameMaxLen = 14;

/// Instant, offline pre-check. Returns a reject reason ('symbol' | 'long') or
/// null when the name passes — then the LLM moderates profanity / injection.
String? localNameReason(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return 'symbol';
  // No Thai/Latin letter at all → symbols / emoji only.
  if (!RegExp(r'[฀-๾a-zA-Z]').hasMatch(t)) return 'symbol';
  if (t.length > kNameMaxLen) return 'long';
  return null;
}

/// Soft, in-character rejection lines (neutral tone — these fire during the
/// pre-tone name steps). Keyed by reason: symbol | long | profane | inject.
const nameRejectMsg = {
  'profane': 'อันนี้ปิ่นเรียกแล้วไม่ค่อยน่ารักเลย ขอเปลี่ยนเป็นคำอื่นได้ไหม',
  'long': 'ขอสั้น ๆ สัก 1–2 คำได้ไหม ปิ่นจะได้เรียกง่าย ๆ',
  'symbol': 'พิมพ์เป็นตัวอักษรให้ปิ่นหน่อยนะ จะได้เรียกได้ถูก',
  'inject': 'คำนี้ตั้งเป็นชื่อไม่ได้นะ ลองคำอื่นดูไหม',
};

/// Don't echo the offensive word back — mask profane/inject; keep the rest
/// (long/symbol aren't offensive, so the user still sees what they typed).
String maskRejected(String raw, String reason) {
  if (reason == 'profane') return '(คำไม่เหมาะสม)';
  if (reason == 'inject') return '(คำต้องห้าม)';
  return raw.trim().isEmpty ? '(ว่าง)' : raw.trim();
}
