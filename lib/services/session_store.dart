import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the Matrix session in platform secure storage (Keychain/Keystore).
/// The matrix-sdk crypto store lives separately on disk; this only holds the
/// credentials needed to restore that store.
class SessionStore {
  static const _storage = FlutterSecureStorage();
  static const _kHomeserver = 'homeserver';
  static const _kToken = 'access_token';
  static const _kUserId = 'user_id';
  static const _kDeviceId = 'device_id';
  static const _kDbPath = 'db_path';
  static const _kEmail = 'user_email';

  Future<void> save(StoredSession s) async {
    await _storage.write(key: _kHomeserver, value: s.homeserver);
    await _storage.write(key: _kToken, value: s.accessToken);
    await _storage.write(key: _kUserId, value: s.userId);
    await _storage.write(key: _kDeviceId, value: s.deviceId);
    await _storage.write(key: _kDbPath, value: s.dbPath);
    if (s.email != null) await _storage.write(key: _kEmail, value: s.email);
  }

  Future<StoredSession?> read() async {
    final homeserver = await _storage.read(key: _kHomeserver);
    final token = await _storage.read(key: _kToken);
    final userId = await _storage.read(key: _kUserId);
    final deviceId = await _storage.read(key: _kDeviceId);
    if (homeserver == null ||
        token == null ||
        userId == null ||
        deviceId == null) {
      return null;
    }
    return StoredSession(
      homeserver: homeserver,
      accessToken: token,
      userId: userId,
      deviceId: deviceId,
      // Null for sessions saved before per-user store paths; the caller falls
      // back to the legacy shared path so existing installs still restore.
      dbPath: await _storage.read(key: _kDbPath),
      email: await _storage.read(key: _kEmail),
    );
  }

  Future<void> clear() => _storage.deleteAll();
}

class StoredSession {
  final String homeserver;
  final String accessToken;
  final String userId;
  final String deviceId;

  /// Absolute path to this account's matrix-sdk store. Null for pre-upgrade
  /// sessions (legacy single shared store).
  final String? dbPath;

  /// The login email — persisted so a token-restore can still set the account's
  /// displayname (the localpart is a one-way hash). Null for old sessions.
  final String? email;

  const StoredSession({
    required this.homeserver,
    required this.accessToken,
    required this.userId,
    required this.deviceId,
    this.dbPath,
    this.email,
  });
}
