import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../src/rust/api/matrix.dart' as rust;
import 'api_log.dart';
import 'auth_service.dart';
import 'files_store.dart';
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
  /// The companion ปิ่น account's user id (the assistant identity in the DM),
  /// set once the pin session is up. Dart compares message senders against this
  /// vs [userId] to decide the bubble side.
  String? pinUserId;

  /// The user's plaintext password, held in memory only between a fresh login
  /// and pin provisioning. The ปิ่น companion account reuses the SAME password
  /// so any device the user signs into can bring up the pin session without
  /// recovering a separate secret. Null after a token-restore (relaunch).
  String? _userPassword;

  /// The user's email, held in memory between a fresh login and pin setup. Used
  /// to set the Matrix profile displayname (the localpart stays hashed) so
  /// accounts are identifiable in the admin UI.
  String? _userEmail;

  Stream<rust.ChatMessage> get messages {
    if (_messages == null) {
      _messages = rust.startSync().asBroadcastStream();
      _subs.add(_messages!
          .where((m) => m.kind == 'tasks')
          .listen((m) => TasksController.instance.updateFromJson(m.flexJson)));
      _subs.add(_messages!
          .where((m) => m.kind == 'events')
          .listen((m) => EventsController.instance.updateFromJson(m.flexJson)));
      _subs.add(_messages!
          .where((m) => m.kind == 'jobs')
          .listen((m) => JobsController.instance.updateFromJson(m.flexJson)));
    }
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

  Future<List<rust.RoomSummary>> listRooms() => rust.listRooms();

  static const _pinRoomKey = 'pin_room_id';

  /// Find the existing ปิ่น DM room id WITHOUT creating one. Returns null on a
  /// brand-new account (→ onboarding should run). Used to rehydrate persona
  /// prefs from room state after a reinstall, before deciding onboarding.
  Future<String?> findPinRoomId() async {
    const storage = FlutterSecureStorage();
    final rooms = await listRooms();
    final savedId = await storage.read(key: _pinRoomKey);
    if (savedId != null && rooms.any((r) => r.id == savedId)) return savedId;
    final existing = rooms.where((r) => r.name == 'ปิ่น AI');
    return existing.isEmpty ? null : existing.first.id;
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

  /// The stored ปิ่น DM room id (if any).
  Future<String?> pinRoomId() =>
      const FlutterSecureStorage().read(key: _pinRoomKey);

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
    final userKey = await rust.ensureRecoveryFor(role: 'user');
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
    await ensurePinSession();
    String? pinKey;
    if (pinUserId != null) {
      try {
        pinKey = await rust.ensureRecoveryFor(role: 'pin');
      } catch (_) {/* pin recovery best-effort */}
    }
    // Resolve the email even on a token-restored session (no _userEmail): we set
    // the account displayname = email, so read it back as a fallback.
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
      if (pinKey != null) 'p': pinKey,
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
      if (lines.length > 1) {
        await ensurePinSession();
        if (pinUserId != null) {
          try {
            await rust.recoverWithKeyFor(role: 'pin', recoveryKey: lines[1]);
          } catch (_) {/* pin restore best-effort */}
        }
      }
      return null;
    }
    await rust.recoverWithKeyFor(role: 'user', recoveryKey: '${j['u']}');
    if (j['p'] != null) {
      await ensurePinSession();
      if (pinUserId != null) {
        try {
          await rust.recoverWithKeyFor(role: 'pin', recoveryKey: '${j['p']}');
        } catch (_) {/* pin restore best-effort */}
      }
    }
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
    // Tear down the pin companion session first (if up), then the user session.
    if (userId != null) {
      try {
        await rust.logout(role: 'pin', dbPath: await _dbPathFor('pin_$userId'));
      } catch (_) {/* pin may not be running */}
    }
    await rust.logout(role: 'user', dbPath: s?.dbPath ?? await _legacyDbPath());
    await _store.clear();
    accessToken = null;
    userId = null;
    pinUserId = null;
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
  }

  // -------------------------------------------------------------------------
  // ปิ่น companion account — second concurrent matrix session (2-account E2EE DM)
  // -------------------------------------------------------------------------

  static const _pinCredsPrefix = 'pin_companion_creds_'; // + user id

  /// Bring up the companion ปิ่น session, starting its sync. Idempotent.
  ///
  /// The ปิ่น account is `<user-localpart>_pin` and reuses the USER's password,
  /// so any device the user logs into can bring it up. Paths:
  /// - fresh login ([_userPassword] in memory): register-if-needed + login pin
  ///   with that password, cache its token for fast relaunch.
  /// - relaunch (token-restore, no password): restore pin from the cached token.
  Future<void> ensurePinSession() async {
    final uid = userId;
    if (uid == null || pinUserId != null) return; // not ready / already up
    final homeserver = (await _store.read())?.homeserver;
    if (homeserver == null) return;
    final storage = const FlutterSecureStorage();
    final pinPath = await _dbPathFor('pin_$uid');
    final userLocal = uid.substring(1).split(':').first; // @local:server → local
    final pinUser = '${userLocal}_pin';
    final pw = _userPassword;
    if (pw != null) {
      try {
        // Same password as the user → no separate secret to recover cross-device.
        await timed(
            'pin.register',
            () => AuthService().registerCompanion(
                homeserver: homeserver, username: pinUser, password: pw));
        final session = await timed(
            'pin.login',
            () => rust.login(
                  role: 'pin',
                  homeserver: homeserver,
                  dbPath: pinPath,
                  username: pinUser,
                  password: pw,
                ));
        pinUserId = session.userId;
        await storage.write(
          key: '$_pinCredsPrefix$uid',
          value: jsonEncode({
            'homeserver': session.homeserver,
            'userId': session.userId,
            'deviceId': session.deviceId,
            'accessToken': session.accessToken,
          }),
        );
      } catch (_) {
        // Password login failed (e.g. the user changed their password since the
        // ปิ่น account was made → they diverged). Fall back to the cached token
        // so the pin chat keeps working instead of bricking.
        if (!await _restorePinFromCache(uid, pinPath, storage)) return;
      }
    } else {
      // Relaunch with no password in memory → restore pin from its cached token.
      if (!await _restorePinFromCache(uid, pinPath, storage)) return;
    }
    await timed('pin.startSync', () => rust.startSyncRole(role: 'pin'));
    // Label the companion so the admin UI can pair it with its owner.
    final em = _userEmail;
    if (em != null && em.isNotEmpty) {
      try {
        await timed('pin.setName',
            () => rust.setDisplayName(role: 'pin', name: 'ปิ่น · $em'));
      } catch (_) {/* non-fatal */}
    }
  }

  /// Restore the pin session from its cached token. Returns false if no cache.
  Future<bool> _restorePinFromCache(
      String uid, String pinPath, FlutterSecureStorage storage) async {
    final raw = await storage.read(key: '$_pinCredsPrefix$uid');
    if (raw == null) return false;
    final c = jsonDecode(raw) as Map<String, dynamic>;
    pinUserId = '${c['userId']}';
    await rust.restore(
      role: 'pin',
      homeserver: '${c['homeserver']}',
      dbPath: pinPath,
      userId: '${c['userId']}',
      deviceId: '${c['deviceId']}',
      accessToken: '${c['accessToken']}',
    );
    return true;
  }

  /// Get-or-create the encrypted DM with the ปิ่น account, cache its id, and make
  /// the pin session join it. Requires [ensurePinSession] first.
  Future<String> getOrCreatePinDm() async {
    final pin = pinUserId;
    if (pin == null) throw Exception('pin session not ready');
    const storage = FlutterSecureStorage();
    // Fast path: reuse the cached room id so boot doesn't pay a full sync_once
    // (+ pin join sync) on every launch — that was the main chat-open lag.
    final cached = await storage.read(key: _pinRoomKey);
    if (cached != null && cached.isNotEmpty) return cached;
    final roomId = await timed(
        'getOrCreatePinDm.syncOnce', () => rust.getOrCreatePinDm(pinUid: pin));
    await storage.write(key: _pinRoomKey, value: roomId);
    try {
      await timed('joinRoom[pin]', () => rust.joinRoom(role: 'pin', roomId: roomId));
    } catch (_) {/* already joined */}
    return roomId;
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
      String roomId, String path, String mime) async {
    final bytes = await File(path).readAsBytes();
    return rust.sendAttachment(
      role: 'user',
      roomId: roomId,
      filename: p.basename(path),
      mime: mime,
      bytes: bytes,
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
}
