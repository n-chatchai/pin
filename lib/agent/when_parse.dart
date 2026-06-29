/// Pure time-parsing for ปิ่น's reminder/job capabilities — no Flutter/rust deps,
/// so it unit-tests fast and deterministically (pass `now`).

/// Parse the model-supplied `time` into a fire [DateTime], or null if unreadable.
/// Accepts:
/// - relative: `+30m` / `+2h` / `+1d` / bare `90` (minutes)
/// - `HH:MM`  → today, rolled to tomorrow if already past
/// - full ISO-8601 timestamp
DateTime? parseWhen(String raw, {DateTime? now}) {
  final t = raw.trim();
  final n = now ?? DateTime.now();
  // Relative: +30m / +2h / +1d / 90 (minutes default).
  final rel =
      RegExp(r'^\+?\s*(\d+)\s*([mhd]?)$', caseSensitive: false).firstMatch(t);
  if (rel != null) {
    final v = int.parse(rel.group(1)!);
    final unit = (rel.group(2) ?? 'm').toLowerCase();
    return n.add(switch (unit) {
      'h' => Duration(hours: v),
      'd' => Duration(days: v),
      _ => Duration(minutes: v),
    });
  }
  // HH:MM today (roll to tomorrow if already past).
  final hm = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(t);
  if (hm != null) {
    final h = int.parse(hm.group(1)!);
    final m = int.parse(hm.group(2)!);
    if (h < 24 && m < 60) {
      var when = DateTime(n.year, n.month, n.day, h, m);
      if (!when.isAfter(n)) when = when.add(const Duration(days: 1));
      return when;
    }
    // invalid clock time → fall through (unreadable)
  }
  // Full ISO timestamp.
  return DateTime.tryParse(t);
}

/// HH:MM (24h, zero-padded).
String hhmm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
