import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../config.dart';
import '../src/rust/api/matrix.dart' as rust;
import 'api_log.dart';
import 'files_store.dart';
import 'pin_meta.dart';
import 'now_controllers.dart';
import 'prefs.dart';
import 'session_store.dart';
import 'tasks_controller.dart';

/// App-facing wrapper around the Rust matrix-sdk bindings. Owns the on-disk
/// store path, credential persistence, and the live message stream.
class MatrixService {
  MatrixService._();
  static final MatrixService instance = MatrixService._();

  final _store = SessionStore();
  Stream<rust.ChatMessage>? _messages;
  final _subs = <StreamSubscription<rust.ChatMessage>>[];

  /// Current Matrix access token, cached in memory after login/restore. Used as
  /// the per-user bearer for the ปิ่น gateway (proxy validates it via whoami).
  String? accessToken;

  /// Currently logged-in user id (set on login/restore, cleared on logout).
  /// Used to scope on-device stores (see [AgentStore]) per account.
  String? userId;

  /// Broadcast stream of live decrypted messages (started after login/restore).
  /// On first use it also routes task payloads into [TasksController] so the
  /// งานค้าง screen stays live app-wide, regardless of which screen is open.
  /// ปิ่น is the user themselves (self-DM model). Kept as an alias of [userId] so
  /// debug/admin screens that show "the ปิ่น identity" still resolve. Assistant
  /// turns are told apart from the human's by an event `meta.pin` flag, NOT by a
  /// distinct sender.
  String? get pinUserId => userId;

  /// The user's plaintext password, held in memory between a fresh login and the
  /// E2EE bootstrap (used to reset cross-signing). Null after a token-restore.
  String? _userPassword;

  /// True once the user is logged in. There is no separate companion to bring up.
  bool get companionReady => userId != null;
  bool get hasUserPassword => _userPassword != null && _userPassword!.isNotEmpty;

  /// The user's email, held in memory between a fresh login and pin setup. Used
  /// to set the Matrix profile displayname (the localpart stays hashed) so
  /// accounts are identifiable in the admin UI.
  String? _userEmail;

  Stream<rust.ChatMessage> get messages {
    // The tasks/events/jobs controllers used to be fed here by the SERVER BOT's
    // io.tokens2.* message payloads. That bot is gone (on-device agent now), so
    // those listeners fed nothing — removed. The controllers are seeded from the
    // ปิ่น ROOM STATE instead (loadListFromRoom), the single source of truth.
    _messages ??= rust.startSync().asBroadcastStream();
    return _messages!;
  }

  /// Legacy single shared store path (pre per-user paths). Used as the fallback
  /// for sessions saved before the upgrade, which have no stored [dbPath].
  Future<String> _legacyDbPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/matrix_store';
  }

  /// Per-account store path: `…/matrix_store/<sanitized account key>`. Each
  /// account gets its own directory so one account can never read another's
  /// cached rooms/keys even if logout fails to wipe (e.g. crash mid-logout).
  Future<String> _dbPathFor(String accountKey) async {
    final dir = await getApplicationSupportDirectory();
    final safe = accountKey.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '${dir.path}/matrix_store/$safe';
  }

  /// True if a session could be restored from secure storage.
  Future<bool> tryRestore() async {
    final s = await _store.read();
    if (s == null) return false;
    await rust.restore(
      role: 'user',
      homeserver: s.homeserver,
      dbPath: s.dbPath ?? await _legacyDbPath(),
      userId: s.userId,
      deviceId: s.deviceId,
      accessToken: s.accessToken,
    );
    accessToken = s.accessToken;
    userId = s.userId;
    _userEmail = s.email;
    // Re-assert the account displayname from the persisted email (the localpart
    // is a one-way hash, so this is the only way a restored session can label
    // itself in the admin UI). Best-effort, fire-and-forget.
    if (s.email != null && s.email!.isNotEmpty) {
      rust.setDisplayName(role: 'user', name: s.email!).catchError((_) {});
    }
    return true;
  }

  Future<rust.Session> login({
    required String homeserver,
    required String username,
    required String password,
    String? email,
  }) async {
    final path = await _dbPathFor('$username@$homeserver');
    final session = await rust.login(
      role: 'user',
      homeserver: homeserver,
      dbPath: path,
      username: username,
      password: password,
    );
    // Label the account with the email (localpart stays hashed) so it's
    // identifiable in the admin UI. Best-effort.
    if (email != null && email.isNotEmpty) {
      try {
        await rust.setDisplayName(role: 'user', name: email);
      } catch (_) {/* non-fatal */}
    }
    await _store.save(StoredSession(
      homeserver: session.homeserver,
      accessToken: session.accessToken,
      userId: session.userId,
      deviceId: session.deviceId,
      dbPath: path,
      email: email,
    ));
    accessToken = session.accessToken;
    userId = session.userId;
    _userPassword = password; // reused for the ปิ่น companion (see ensurePinSession)
    _userEmail = email;
    return session;
  }

  /// Custom-scheme deep link the tuwunel SSO flow returns the `loginToken` to.
  static const _ssoScheme = 'pinapp';

  /// "Sign in with Google" — Matrix legacy SSO (m.login.sso) via tuwunel's Google
  /// identity_provider. Opens the homeserver SSO URL in a browser tab, captures
  /// the `loginToken` redirect, and exchanges it for a session. No password →
  /// the ปิ่น companion comes up via the room-stored E2EE pw path (separate).
  Future<rust.Session> loginWithGoogle() async {
    const homeserver = kHomeserver;
    final path = await _dbPathFor('sso@$homeserver');
    final url = await rust.ssoLoginUrl(
      homeserver: homeserver,
      dbPath: path,
      redirectUrl: '$_ssoScheme://sso',
      idpId: null, // single provider (Google) → implicit default
    );
    debugPrint('[sso] authenticate() → opening browser');
    final result = await FlutterWebAuth2.authenticate(
        url: url, callbackUrlScheme: _ssoScheme);
    debugPrint('[sso] authenticate() RETURNED (callback received)');
    final token = Uri.parse(result).queryParameters['loginToken'];
    if (token == null || token.isEmpty) {
      throw 'การเข้าสู่ระบบ Google ไม่สำเร็จ (ไม่มี loginToken)';
    }
    debugPrint('[sso] got loginToken → rust.loginToken exchange');
    final session = await rust.loginToken(
        role: 'user', homeserver: homeserver, dbPath: path, token: token);
    debugPrint('[sso] loginToken exchange OK → user=${session.userId}');
    await _store.save(StoredSession(
      homeserver: session.homeserver,
      accessToken: session.accessToken,
      userId: session.userId,
      deviceId: session.deviceId,
      dbPath: path,
      email: null,
    ));
    accessToken = session.accessToken;
    userId = session.userId;
    return session;
  }

  Future<List<rust.RoomSummary>> listRooms() => rust.listRooms();

  static const _pinRoomKey = 'pin_room_id'; // legacy device cache (being retired)

  /// Account-data pointer to the canonical self-room id. Server-side + per-user +
  /// key-independent → every device/relogin resolves the SAME room deterministically
  /// (no device cache to clear, no name-match guessing, no duplicate rooms).
  static const _selfRoomAd = 'io.tokens2.selfroom';

  Future<String?> _selfRoomFromAd() async {
    try {
      return selfRoomId(
          await rust.accountDataGet(role: 'user', name: _selfRoomAd));
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveSelfRoomToAd(String id) async {
    try {
      await rust.accountDataPut(
          role: 'user', name: _selfRoomAd, value: selfRoomPointer(id));
    } catch (_) {/* best-effort */}
  }

  /// Find the existing ปิ่น room id WITHOUT creating one. Returns null on a
  /// brand-new account (→ onboarding runs). Account data is the source of truth;
  /// a legacy room (named 'ปิ่น', pre-account-data) is the only fallback.
  Future<String?> findPinRoomId() async {
    final adId = await _selfRoomFromAd();
    if (adId != null) {
      // The pointer alone doesn't load the room into the local store. On a cold
      // relogin the room isn't synced yet, so a later getPrefsState/roomMessages
      // read would miss (→ spurious in-chat onboarding + empty history). Sync it
      // in first when absent.
      if (!await rust.roomInStore(roomId: adId)) {
        await listRooms(); // sync_once → loads joined rooms + state
      }
      return adId;
    }
    final rooms = await listRooms();
    return resolveSelfRoom(null, rooms.map((r) => (id: r.id, name: r.name)));
  }

  final _mediaCache = <String, Future<String>>{};

  /// Download (and decrypt) a message's media to a temp file, memoized by event.
  Future<String> downloadMedia(String roomId, String eventId) =>
      _mediaCache.putIfAbsent(
          eventId, () => rust.downloadMedia(roomId: roomId, eventId: eventId));

  /// Push the current persona to the ปิ่น room's state so every device reads the
  /// same persona (the room is the source of truth — mirrors the transcript).
  /// State events are NOT E2EE, so they sync without key recovery. Best-effort.
  Future<void> savePersonaToRoom(String roomId, Map<String, String> persona) =>
      setStateEvent(roomId, 'io.tokens2.prefs', persona);

  /// Read persona prefs back from the ปิ่น room's state (None if never set).
  /// Used on startup to rehydrate [PrefsController] after a fresh install.
  Future<Map<String, String>?> loadPrefsFromRoom(String roomId) async {
    final raw =
        await timed('getPrefsState', () => rust.getPrefsState(roomId: roomId));
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in m.entries) e.key: '${e.value}',
      };
    } catch (_) {
      return null;
    }
  }

  /// Enable E2EE key backup/recovery; returns the recovery key to save.
  /// "enabled" | "disabled" | "incomplete" | "unknown" — is key backup already
  /// set up for this account (returning user should restore, not re-create).
  Future<String> recoveryState() => rust.recoveryState();

  /// E2EE diagnostics for the Settings debug section.
  Future<rust.E2eeStatus> e2eeStatus() => rust.e2EeStatus();

  /// (Re)bootstrap cross-signing + key backup using the account password;
  /// returns the new recovery key. Fixes "cross-signing not ready".
  Future<String> resetRecovery(String password) =>
      rust.resetRecovery(password: password);

  /// The canonical self-room id from account data (if any). Used by cold-wake
  /// jobs to post without creating a room.
  Future<String?> pinRoomId() => _selfRoomFromAd();

  /// Joined member user-ids of a room.
  Future<List<String>> roomMembers(String roomId) =>
      rust.roomMembers(roomId: roomId);

  Future<String> enableRecovery() => rust.enableRecovery();

  /// Authoritative server check: does a key backup already exist? A fresh device
  /// must RESTORE (not create) when true — creating deletes the backup and locks
  /// the user's other devices out.
  Future<bool> backupExists() => rust.backupExistsOnServer();

  /// The login email (if known this session), for embedding in the recovery QR.
  String? get userEmail => _userEmail;

  /// Build the combined recovery QR payload: email + the user account's recovery
  /// key + the ปิ่น account's recovery key, as JSON. Both accounts have separate
  /// E2EE keys, so one QR must carry both to restore the full DM on a new device.
  Future<String> buildRecoveryQr() async {
    debugPrint('[qr] buildRecoveryQr → ensureRecoveryFor(user) …');
    final userKey = await rust.ensureRecoveryFor(role: 'user');
    debugPrint('[qr] ensureRecoveryFor(user) OK');
    return packRecoveryQr(userKey);
  }

  /// FULL E2EE bootstrap (cross-signing + key backup + recovery) using the
  /// account password cached right after signup/login — so a new account is
  /// fully set up (not the "incomplete" state that plain `enableRecovery` leaves,
  /// where cross-signing never gets bootstrapped). Falls back to backup-only when
  /// there's no cached password (e.g. a token-restored session). Returns the
  /// combined recovery QR payload.
  Future<String> bootstrapE2eeQr() async {
    final pw = _userPassword;
    debugPrint('[qr] bootstrapE2eeQr (pw=${pw != null && pw.isNotEmpty})');
    if (pw != null && pw.isNotEmpty) {
      final userKey = await rust.resetRecovery(password: pw);
      return packRecoveryQr(userKey);
    }
    return buildRecoveryQr(); // no password → backup only (cross-signing unset)
  }

  /// Package an already-obtained user recovery key + the ปิ่น key + email into
  /// the combined QR JSON. Used by Settings (which gets the user key from a full
  /// cross-signing reset) so the user key isn't rotated twice.
  Future<String> packRecoveryQr(String userKey) async {
    // Self-DM: one account, one recovery key. Resolve the email even on a
    // token-restored session (no _userEmail) by reading back the displayname.
    var email = _userEmail;
    if (email == null || email.isEmpty) {
      try {
        email = await rust.getDisplayName(role: 'user');
      } catch (_) {/* leave null */}
    }
    return jsonEncode({
      'v': 1,
      if (email != null && email.isNotEmpty) 'e': email,
      'u': userKey,
    });
  }

  /// Restore E2EE keys from a scanned recovery QR (or a raw pasted key). Accepts
  /// the combined `{v,e,u,p}` JSON or a bare key string (old QRs). Recovers the
  /// user account and, if present, the ปิ่น account. Returns the embedded email.
  Future<String?> restoreFromRecoveryQr(String scanned) async {
    Map<String, dynamic>? j;
    try {
      final d = jsonDecode(scanned);
      if (d is Map<String, dynamic>) j = d;
    } catch (_) {/* not JSON → raw key */}
    if (j == null || j['u'] == null) {
      final lines = scanned.trim().split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      if (lines.isEmpty) return null;
      await rust.recoverWithKeyFor(role: 'user', recoveryKey: lines[0]);
      return null;
    }
    await rust.recoverWithKeyFor(role: 'user', recoveryKey: '${j['u']}');
    return j['e'] as String?;
  }

  /// Lost recovery key → wipe the stale server backup and create a new one.
  /// Returns the new recovery key.
  Future<String> resetRecoveryKey() => rust.resetRecoveryKey();

  /// Restore keys on this device from a saved recovery key.
  Future<void> recoverWithKey(String key) =>
      rust.recoverWithKey(recoveryKey: key);

  Future<void> logout() async {
    final s = await _store.read();
    await rust.logout(role: 'user', dbPath: s?.dbPath ?? await _legacyDbPath());
    await _store.clear();
    accessToken = null;
    userId = null;
    _userPassword = null;
    _userEmail = null;
    // Cancel the live-message listeners and drop the stream so the next
    // account's sync starts clean (a broadcast stream's listeners keep firing
    // into the singleton controllers otherwise).
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    _messages = null;
    // Clear the in-memory singleton controllers — they hold the previous
    // account's tasks/events/jobs/memory and survive logout (same isolate),
    // leaking that data into the next account's UI.
    TasksController.instance.value = const [];
    EventsController.instance.value = const [];
    JobsController.instance.value = const [];
    MemoryController.instance.value = const [];
    // Close the per-account files DB so the next account opens its own.
    await FilesStore.instance.reset();
    // Wipe ALL local prefs (persona, onboarded, personaSetup, settings) so the
    // next account starts clean — keeping only onboarded=false left the previous
    // account's name/personaSetup behind, so a new account showed the old name
    // and skipped the in-chat setup. For the SAME account, AfterAuth's rehydrate
    // re-pulls persona from the ปิ่น room and flips onboarded back to true (keys
    // are kept, so no recovery prompt); a different account has no room here and
    // falls through to the recovery step to pull ITS keys.
    await PrefsController.instance.reset();
    // Drop the cached ปิ่น room id — it's per-account; leaking it makes the next
    // account resolve a room its client doesn't have ("room not found").
    await const FlutterSecureStorage().delete(key: _pinRoomKey);
  }

  // -------------------------------------------------------------------------
  // ปิ่น self-DM — ONE account. The human and the on-device agent both post into a
  // single-member encrypted room (the user's own), told apart by an event meta
  // flag (`meta.pin == true`). No second account, no companion password, no
  // cross-account verification. E2EE is to the user's own cross-signed devices.
  // -------------------------------------------------------------------------

  /// No-op shim: there is no separate companion session to bring up. Kept so the
  /// "ensure ปิ่น is ready" callers still compile. The user session (the only
  /// session) is brought up by [tryRestore]/[login]/[loginWithGoogle].
  Future<void> ensurePinSession() async {}

  /// "เริ่ม ปิ่น ใหม่": abandon the current self-room and start a fresh one (drops
  /// the cached id so [getOrCreatePinDm] creates a new room). The old chat is left
  /// behind.
  Future<void> recreateCompanion() async {
    if (userId == null) throw Exception('ยังไม่ได้เข้าสู่ระบบ');
    await const FlutterSecureStorage().delete(key: _pinRoomKey);
    await getOrCreatePinDm(); // creates + caches a fresh self-room
  }

  /// "เริ่ม ปิ่น ใหม่" from settings: rotate the recovery key (caller shows the new
  /// QR) AND start a fresh self-room. Bounded so a stall surfaces an error.
  Future<String> resetAndRecreateCompanion() async {
    final key = await rust.resetRecoveryKey().timeout(
        const Duration(seconds: 90),
        onTimeout: () =>
            throw 'รีเซ็ตกุญแจกู้คืนนานเกินไป — ตรวจสอบเน็ตแล้วลองใหม่');
    await recreateCompanion();
    return key;
  }

  /// No second account → never locked. Kept so the UI's "ปิ่น locked" branches
  /// compile (they're now dead).
  bool get companionLocked => false;

  /// Get-or-create the ปิ่น self-room (single-member encrypted). The id lives in
  /// account data (server-side, cross-device) — NOT a device cache — so every
  /// device/relogin resolves the SAME room deterministically. No id yet → migrate
  /// a legacy 'ปิ่น' room if one exists, else create; then persist to account data.
  Future<String> getOrCreatePinDm() async {
    if (userId == null) throw Exception('not logged in');
    // Read the pointer DIRECTLY (not via _selfRoomFromAd, which swallows errors):
    // a thrown read error must propagate, NOT fall through to create — creating
    // would overwrite the pointer and spawn a duplicate room. Only a definitively
    // -absent pointer (null) proceeds.
    final adId = selfRoomId(
        await rust.accountDataGet(role: 'user', name: _selfRoomAd));
    if (adId != null) {
      unawaited(_leaveDuplicatePinRooms(adId));
      return adId;
    }
    // No pointer yet → SYNC rooms first so a real existing room isn't missed on a
    // cold store (which would create a duplicate). Migrate a legacy 'ปิ่น' room if
    // present, else create; then persist the pointer.
    final rooms = await listRooms();
    final legacy =
        resolveSelfRoom(null, rooms.map((r) => (id: r.id, name: r.name)));
    final String roomId =
        legacy ?? await timed('createSelfRoom', () => rust.createSelfRoom());
    await _saveSelfRoomToAd(roomId);
    unawaited(_leaveDuplicatePinRooms(roomId)); // GC old dup self-rooms
    return roomId;
  }

  /// GC duplicate self-rooms left by the old create-on-cache-miss bug: leave every
  /// OTHER room named 'ปิ่น' so it loses its last member and the server prunes it.
  /// Never touches the admin room (different name). Best-effort, fire-and-forget.
  Future<void> _leaveDuplicatePinRooms(String keep) async {
    try {
      for (final r in await listRooms()) {
        if (r.id != keep && r.name == 'ปิ่น') {
          try {
            await rust.leaveRoom(role: 'user', roomId: r.id);
          } catch (_) {/* best-effort */}
        }
      }
    } catch (_) {/* best-effort */}
  }

  /// Post a turn into the DM. `role` = 'user' (human) or 'pin' (assistant).
  Future<String> sendText(String roomId, String body,
          {required String role, Map<String, dynamic>? flex, Map<String, dynamic>? meta}) =>
      timed(
          'sendText[$role]',
          () => rust.sendText(
                role: role,
                roomId: roomId,
                body: body,
                flexJson: flex == null ? null : jsonEncode(flex),
                metaJson: meta == null ? null : jsonEncode(meta),
              ));

  /// Upload an encrypted attachment into the DM as the human account.
  Future<String> sendUserAttachment(
      String roomId, String path, String mime,
      {String? caption}) async {
    final bytes = await File(path).readAsBytes();
    return rust.sendAttachment(
      role: 'user',
      roomId: roomId,
      filename: p.basename(path),
      mime: mime,
      bytes: bytes,
      caption: caption,
    );
  }

  /// Paginate the DM backward (newest→oldest) from the user session.
  Future<rust.TimelinePage> roomMessages(String roomId,
          {String? from, int limit = 60}) =>
      timed('roomMessages${from == null ? '[first]' : ''}',
          () => rust.roomMessages(role: 'user', roomId: roomId, from: from, limit: limit));

  /// Write a room state event (persona/facts/knowledge cross-device sync).
  Future<void> setStateEvent(String roomId, String type, Map<String, dynamic> content,
          {String role = 'user'}) =>
      timed(
          'setState:$type',
          () => rust.setState(
              role: role, roomId: roomId, eventType: type, contentJson: jsonEncode(content)));

  /// Read a room state event's content (None if never set).
  Future<Map<String, dynamic>?> getStateEvent(String roomId, String type,
      {String role = 'user'}) async {
    final raw = await rust.getState(role: role, roomId: roomId, eventType: type);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ---- Room-backed stores (single source of truth for the agent's
  // reminders/tasks/events/files; mirrors how persona uses io.tokens2.prefs) ----

  static const _stateCapBytes = 60000; // headroom under Matrix's ~64KB state cap

  /// Save a list to a room STATE event as `{items:[...]}` (state content must be
  /// a JSON object). Prunes oldest entries until it fits the cap. Best-effort.
  /// Returns true if the state write succeeded. Callers that don't care can
  /// ignore it (best-effort); the scheduler checks it so ปิ่น never acks a
  /// reminder it failed to record.
  Future<bool> saveListToRoom(
      String roomId, String type, List<Map<String, dynamic>> items) async {
    var list = items;
    while (list.length > 1 &&
        jsonEncode({'items': list}).length > _stateCapBytes) {
      list = list.sublist(1); // drop oldest
    }
    try {
      await setStateEvent(roomId, type, {'items': list});
      return true;
    } catch (_) {
      return false; // best-effort for most callers; the scheduler reacts
    }
  }

  /// Read a list back from a room state event's `items`.
  Future<List<Map<String, dynamic>>> loadListFromRoom(
      String roomId, String type) async {
    final content = await getStateEvent(roomId, type);
    final items = content?['items'];
    if (items is! List) return [];
    return [for (final e in items) Map<String, dynamic>.from(e as Map)];
  }

  /// Save a PRIVATE blob (the agent's memory) as an E2EE timeline event, and
  /// store its event id in a plaintext state-event POINTER so it can be fetched
  /// back reliably (scanning the timeline for it would be unreliable once it's
  /// buried under chat). The homeserver can't read the content (unlike a state
  /// event, which is plaintext).
  /// Returns true if the blob + its pointer were written. The agent checks this
  /// so ปิ่น never confirms a memory/fact it failed to record.
  Future<bool> saveEncryptedBlob(
      String roomId, String type, Map<String, dynamic> content) async {
    try {
      final eventId = await rust.sendCustomEvent(
          role: 'user',
          roomId: roomId,
          eventType: type,
          contentJson: jsonEncode(content));
      await setStateEvent(roomId, '$type.ptr', {'event_id': eventId});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Read a PRIVATE blob back: pointer state → fetch + decrypt that event.
  Future<Map<String, dynamic>?> loadEncryptedBlob(
      String roomId, String type) async {
    final ptr = await getStateEvent(roomId, '$type.ptr');
    final eid = ptr?['event_id'] as String?;
    if (eid == null || eid.isEmpty) return null;
    try {
      final raw = await rust.fetchEventContent(
          role: 'user', roomId: roomId, eventId: eid);
      if (raw == null) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}
