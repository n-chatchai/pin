import 'dart:convert';

/// Pure helpers for the self-DM model — no Flutter/rust deps, so they unit-test
/// fast. The human and the on-device ปิ่น both post from the user's own account;
/// a `meta.pin` flag (not the sender) tells them apart, and the canonical
/// self-room id lives in an account-data pointer.

/// Whether a DM event's `io.tokens2.meta` JSON marks it a ปิ่น (assistant) turn.
bool isPinMeta(String? metaJson) {
  if (metaJson == null || metaJson.isEmpty) return false;
  try {
    final m = jsonDecode(metaJson);
    return m is Map && m['pin'] == true;
  } catch (_) {
    return false;
  }
}

/// Meta map for a ปิ่น turn: the pin flag + optional used-tools (omitted if none).
Map<String, dynamic> pinMeta(List<String> usedTools) =>
    {'pin': true, if (usedTools.isNotEmpty) 'used': usedTools};

/// Room id from the self-room account-data pointer JSON (null if absent/malformed).
String? selfRoomId(String? accountDataJson) {
  if (accountDataJson == null || accountDataJson.isEmpty) return null;
  try {
    final id = (jsonDecode(accountDataJson) as Map<String, dynamic>)['room'];
    return (id is String && id.isNotEmpty) ? id : null;
  } catch (_) {
    return null;
  }
}

/// Encode the self-room pointer for account data.
String selfRoomPointer(String roomId) => jsonEncode({'room': roomId});

/// Display name of the self-room (used to match legacy rooms predating the
/// account-data pointer).
const selfRoomName = 'ปิ่น';

/// Pick the canonical self-room id: the account-data pointer wins; otherwise the
/// first joined room named [selfRoomName] (legacy fallback). Null = none yet →
/// onboarding. Pure decision logic; the I/O (read pointer, sync, create) lives in
/// MatrixService.findPinRoomId/getOrCreatePinDm.
String? resolveSelfRoom(
    String? adPointerJson, Iterable<({String id, String name})> rooms) {
  final ad = selfRoomId(adPointerJson);
  if (ad != null) return ad;
  for (final r in rooms) {
    if (r.name == selfRoomName) return r.id;
  }
  return null;
}
