import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../config.dart';
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

  /// Companion login password for SSO (Google) users, who have NO account
  /// password to reuse. Derived from the user's recovery key (see
  /// [_deriveCompanionPw]); set in the recovery create/restore paths, both of
  /// which hold that key. [ensurePinSession] uses it when [_userPassword] is null.
  String? _companionPw;

  /// Companion localpart. Normally `{user}_pin`, but [recreateCompanion] picks a
  /// fresh suffixed name when the old account is locked (recovery key lost). The
  /// chosen name rides the secret-storage blob so every device agrees. Null =
  /// fall back to the default `{user}_pin`.
  String? _companionUser;

  /// True once the ปิ่น companion session is up — i.e. the real 2-account E2EE
  /// DM can exist. While false, any "chat" is a local-only fallback with NO ปิ่น
  /// account, which SSO users must never be silently left in.
  bool get companionReady => pinUserId != null;
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
    // SSO user (no account password): resolve the companion password from secret
    // storage (rotation-safe), seeding it from the legacy derivation the first
    // time, so ensurePinSession can bring up the ปิ่น account. No-op for password
    // users (_userPassword wins).
    await _resolveCompanionPw(userKey);
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
      await _resolveCompanionPw(lines[0]);
      await ensurePinSession();
      if (lines.length > 1 && pinUserId != null) {
        try {
          await rust.recoverWithKeyFor(role: 'pin', recoveryKey: lines[1]);
        } catch (_) {/* pin restore best-effort */}
      }
      return null;
    }
    await rust.recoverWithKeyFor(role: 'user', recoveryKey: '${j['u']}');
    await _resolveCompanionPw('${j['u']}');
    await ensurePinSession();
    if (j['p'] != null && pinUserId != null) {
      try {
        await rust.recoverWithKeyFor(role: 'pin', recoveryKey: '${j['p']}');
      } catch (_) {/* pin restore best-effort */}
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
    // Drop the cached ปิ่น room id — it's per-account; leaking it makes the next
    // account resolve a room its client doesn't have ("room not found").
    await const FlutterSecureStorage().delete(key: _pinRoomKey);
  }

  // -------------------------------------------------------------------------
  // ปิ่น companion account — second concurrent matrix session (2-account E2EE DM)
  // -------------------------------------------------------------------------

  static const _pinCredsPrefix = 'pin_companion_creds_'; // + user id

  /// Companion login password for an SSO user, derived from the USER's recovery
  /// key. Properties that make this the secure choice:
  ///  - never stored anywhere — recomputed on demand from the key;
  ///  - server-blind — the homeserver never sees the recovery key, only the
  ///    resulting matrix password *hash*, so an admin can't read or reuse it;
  ///  - cross-device — the recovery key rides along in the recovery QR, so every
  ///    device derives the SAME companion password.
  /// HMAC-SHA256 acts as the PRF; base64url makes it an ASCII-safe password.
  ///
  /// The companion password is the LEGACY derivation, kept only to bootstrap
  /// the stable secret on accounts created before [_resolveCompanionPw]. New
  /// accounts read/write the seed in secret storage instead (rotation-safe).
  String? _deriveCompanionPw(String userRecoveryKey) {
    final uid = userId;
    if (uid == null || userRecoveryKey.isEmpty) return null;
    final pinUser = '${uid.substring(1).split(':').first}_pin';
    final mac = Hmac(sha256, utf8.encode(userRecoveryKey))
        .convert(utf8.encode('pin-companion:$pinUser'));
    return base64Url.encode(mac.bytes);
  }

  /// Secret-storage name (E2EE account-data) the stable companion password lives
  /// under, so a recovery-key rotation re-encrypts it (not re-derives it).
  static const _companionSecret = 'io.tokens2.pin.companion';

  /// Resolve [_companionPw] from the user's E2EE secret storage — STABLE across
  /// recovery-key rotation (the value is re-encrypted under the new key, not
  /// recomputed). On an account that predates this, the secret isn't there yet,
  /// so derive the legacy HMAC password (which still matches the existing `_pin`
  /// account — provided this is the same recovery key it was made with) and
  /// store it as the seed, migrating the account to the rotation-safe scheme.
  /// [userRecoveryKey] is the 4S secret-storage key (must be unlocked/recovered).
  Future<void> _resolveCompanionPw(String userRecoveryKey) async {
    if (_userPassword != null || userRecoveryKey.isEmpty) return;
    try {
      final stored = await rust.secretGet(
          role: 'user', recoveryKey: userRecoveryKey, name: _companionSecret);
      if (stored != null && stored.isNotEmpty) {
        // New format is a {u,p} blob (username + password). Old format was a bare
        // password string — treat that as the password with the default name.
        try {
          final j = jsonDecode(stored) as Map<String, dynamic>;
          _companionUser = '${j['u']}';
          _companionPw = '${j['p']}';
        } catch (_) {
          _companionPw = stored;
        }
        return; // rotation-safe value wins
      }
    } catch (e) {
      debugPrint('[sso] 4S fetch failed: $e');
      /* secret storage not ready → fall through to legacy + migrate */
    }
    final derived = _deriveCompanionPw(userRecoveryKey);
    if (derived == null) return;
    _companionPw = derived; // _companionUser stays null → default {user}_pin
    // Persist so the NEXT recovery-key rotation keeps this same password.
    await _putCompanionSecret(userRecoveryKey);
  }

  /// Write the current companion identity ({username, password}) to the user's
  /// E2EE secret storage, so every device brings up the SAME ปิ่น account.
  Future<void> _putCompanionSecret(String userRecoveryKey) async {
    final uid = userId;
    final pw = _companionPw;
    if (uid == null || pw == null || userRecoveryKey.isEmpty) return;
    final u = _companionUser ?? '${uid.substring(1).split(':').first}_pin';
    try {
      await rust
          .secretPut(
              role: 'user',
              recoveryKey: userRecoveryKey,
              name: _companionSecret,
              value: jsonEncode({'u': u, 'p': pw}))
          .timeout(const Duration(seconds: 45));
    } catch (e) {
      // Best-effort: a slow/failed secret-storage open must not hang or abort
      // the recreate — the companion still comes up from the in-memory pw; the
      // secret just isn't rotation-persisted until the next successful write.
      debugPrint('[sso] _putCompanionSecret failed: $e');
    }
  }

  /// Start a FRESH ปิ่น companion. Used when the original `{user}_pin` is locked
  /// (the recovery key it was made with is lost) and the user chose to start
  /// over: register a brand-new companion under a unique localpart with a fresh
  /// random password, record it in secret storage, and drop the old DM cache so
  /// a new ปิ่น DM is created. The old ปิ่น chat is abandoned (its E2EE history
  /// stays unreadable). [userRecoveryKey] must be a usable (just reset/recovered)
  /// recovery key so the new identity can be saved to secret storage.
  Future<void> recreateCompanion(String userRecoveryKey) async {
    final uid = userId;
    if (uid == null) throw Exception('ยังไม่ได้เข้าสู่ระบบ');
    final userLocal = uid.substring(1).split(':').first;
    final suffix = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    _companionUser = '${userLocal}_pin_$suffix';
    final rnd = Random.secure();
    _companionPw =
        base64Url.encode(List<int>.generate(32, (_) => rnd.nextInt(256)));
    debugPrint('[recreate] new companion=$_companionUser');
    // Forget the half-up old companion + its DM so a fresh DM is created.
    pinUserId = null;
    const storage = FlutterSecureStorage();
    await storage.delete(key: _pinRoomKey);
    await storage.delete(key: '$_pinCredsPrefix$uid'); // stale token of old ปิ่น
    debugPrint('[recreate] storing companion secret …');
    await _putCompanionSecret(userRecoveryKey);
    debugPrint('[recreate] secret stored → ensurePinSession');
    await ensurePinSession();
    debugPrint('[recreate] ensurePinSession returned companionReady=$companionReady');
    if (!companionReady) {
      throw 'สร้างบัญชี ปิ่น ใหม่ไม่สำเร็จ — ลองอีกครั้ง';
    }
  }

  /// "เริ่ม ปิ่น ใหม่": reset the recovery key (fresh secret storage) and register
  /// a brand-new companion under it. Returns the new recovery key to save. Use
  /// when the old ปิ่น can't be recovered (lost its original key).
  ///
  /// Each network step is bounded so a stalled homeserver surfaces an error
  /// instead of an infinite spinner (the recovery enable + secret-storage open
  /// are the slow ones).
  Future<String> resetAndRecreateCompanion() async {
    debugPrint('[recreate] resetRecoveryKey …');
    final key = await rust.resetRecoveryKey().timeout(
        const Duration(seconds: 90),
        onTimeout: () =>
            throw 'รีเซ็ตกุญแจกู้คืนนานเกินไป — ตรวจสอบเน็ตแล้วลองใหม่');
    debugPrint('[recreate] resetRecoveryKey OK → recreateCompanion');
    await recreateCompanion(key);
    return key;
  }

  /// Whether the ปิ่น companion failed to come up this session (so the UI can
  /// offer "start a new ปิ่น"). True when we have a user but no companion.
  bool get companionLocked => userId != null && pinUserId == null;

  /// Bring up the companion ปิ่น session, starting its sync. Idempotent.
  ///
  /// The ปิ่น account is `<user-localpart>_pin` and reuses the USER's password,
  /// so any device the user logs into can bring it up. Paths:
  /// - fresh login ([_userPassword] in memory): register-if-needed + login pin
  ///   with that password, cache its token for fast relaunch.
  /// - relaunch (token-restore, no password): restore pin from the cached token.
  Future<void> ensurePinSession() async {
    final uid = userId;
    if (uid == null || pinUserId != null) {
      debugPrint('[sso] ensurePinSession skip (uid=$uid pinUp=${pinUserId != null})');
      return; // not ready / already up
    }
    final homeserver = (await _store.read())?.homeserver;
    if (homeserver == null) {
      debugPrint('[sso] ensurePinSession: no homeserver');
      return;
    }
    debugPrint('[sso] ensurePinSession start (pw=${_userPassword != null ? "user" : (_companionPw != null ? "companion" : "NONE")})');
    final storage = const FlutterSecureStorage();
    final pinPath = await _dbPathFor('pin_$uid');
    final userLocal = uid.substring(1).split(':').first; // @local:server → local
    final pinUser = _companionUser ?? '${userLocal}_pin';
    // Password users reuse their own password; SSO users have none, so fall back
    // to the password derived from their recovery key.
    final pw = _userPassword ?? _companionPw;
    if (pw != null) {
      try {
        // Same password as the user → no separate secret to recover cross-device.
        debugPrint('[sso] pin.register …');
        await timed(
            'pin.register',
            () => AuthService().registerCompanion(
                homeserver: homeserver, username: pinUser, password: pw));
        debugPrint('[sso] pin.register done → pin.login …');
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
        debugPrint('[sso] pin.login OK → pin=${session.userId}');
        await storage.write(
          key: '$_pinCredsPrefix$uid',
          value: jsonEncode({
            'homeserver': session.homeserver,
            'userId': session.userId,
            'deviceId': session.deviceId,
            'accessToken': session.accessToken,
          }),
        );
      } catch (e) {
        // Password login failed (e.g. the user changed their password since the
        // ปิ่น account was made → they diverged). Fall back to the cached token
        // so the pin chat keeps working instead of bricking.
        debugPrint('[sso] pin register/login FAILED: $e → try cache');
        if (!await _restorePinFromCache(uid, pinPath, storage)) {
          debugPrint('[sso] no pin cache → companion NOT up');
          return;
        }
      }
    } else {
      // Relaunch with no password in memory → restore pin from its cached token.
      debugPrint('[sso] no pw → restore pin from cache');
      if (!await _restorePinFromCache(uid, pinPath, storage)) {
        debugPrint('[sso] no pin cache → companion NOT up');
        return;
      }
    }
    debugPrint('[sso] pin.startSync …');
    await timed('pin.startSync', () => rust.startSyncRole(role: 'pin'));
    debugPrint('[sso] ensurePinSession DONE → companion up');
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
    // (+ pin join sync) on every launch — that was the main chat-open lag. But
    // VALIDATE it belongs to this account's client first: the cache is global,
    // so a stale id from a previous account makes every room read fail "room
    // not found" (→ persona defaults, empty history). Valid → keep the fast
    // path; stale → drop it and re-resolve below.
    final cached = await storage.read(key: _pinRoomKey);
    if (cached != null && cached.isNotEmpty) {
      if (await rust.roomInStore(roomId: cached)) return cached;
      await storage.delete(key: _pinRoomKey);
    }
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
