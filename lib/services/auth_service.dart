import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'matrix_service.dart';

/// Shared invite token for token-gated registration on the homeserver. Override
/// per-build with `--dart-define=PIN_REG_TOKEN=<token>`; the default matches the
/// current dev homeserver so test builds can register out of the box. Rotate the
/// server token + drop this default before any public release.
const kRegistrationToken = String.fromEnvironment('PIN_REG_TOKEN',
    defaultValue: 'daf372281ba708ede1ed7b4ab5951618');

/// Consumer-friendly auth: email+password maps deterministically to a Matrix
/// account (register if new, else log in), then hands the session to the Rust
/// E2EE client. No Matrix jargon shown to the user.
///
/// Apple/Google SSO needs an auth-bridge backend + OAuth client IDs; those
/// paths are stubbed until that infra exists.
class AuthService {
  /// Resolves the homeserver base URL from a server name.
  Future<String> _discover(String serverName) async {
    var name = serverName.trim();
    if (!name.startsWith('http')) name = 'https://$name';
    try {
      final res =
          await http.get(Uri.parse('$name/.well-known/matrix/client'));
      if (res.statusCode == 200) {
        final url = (jsonDecode(res.body)['m.homeserver']?['base_url']) as String?;
        if (url != null && url.isNotEmpty) {
          return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
        }
      }
    } catch (_) {}
    return name.endsWith('/') ? name.substring(0, name.length - 1) : name;
  }

  /// Deterministic Matrix localpart from an email (stable across devices,
  /// doesn't leak the address). Bare 16-hex-char hash, no `pin_` prefix.
  String _localpart(String email) {
    final h = sha256.convert(utf8.encode(email.trim().toLowerCase()));
    return h.toString().substring(0, 16);
  }

  /// Matrix localpart from a chosen username — used directly (human-readable
  /// @username:server) and sanitised to the allowed localpart grammar.
  String _localpartFromUsername(String username) =>
      username.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9._=\-/]'), '');

  /// Whether a username is still free to register.
  Future<bool> usernameAvailable({
    required String homeserver,
    required String username,
  }) async {
    final base = await _discover(homeserver);
    final lp = _localpartFromUsername(username);
    if (lp.isEmpty) return false;
    try {
      final res = await http.get(Uri.parse(
          '$base/_matrix/client/v3/register/available?username=$lp'));
      if (res.statusCode == 200) return true; // available
      return (jsonDecode(res.body)['errcode']) != 'M_USER_IN_USE';
    } catch (_) {
      return true; // network issue → let the actual call decide
    }
  }

  /// LOGIN only — existing account, by username.
  Future<void> signInWithUsername({
    required String homeserver,
    required String username,
    required String password,
  }) async {
    final base = await _discover(homeserver);
    final lp = _localpartFromUsername(username);
    try {
      await MatrixService.instance
          .login(homeserver: base, username: lp, password: password);
    } on Object {
      throw Exception('เข้าสู่ระบบไม่สำเร็จ — ชื่อผู้ใช้หรือรหัสผ่านไม่ถูกต้อง');
    }
  }

  /// REGISTER only — new account by username. Stops if the name is taken.
  Future<void> registerWithUsername({
    required String homeserver,
    required String username,
    required String password,
  }) async {
    final base = await _discover(homeserver);
    final lp = _localpartFromUsername(username);
    final creds = await _register(base, lp, password);
    if (creds == null) {
      throw Exception('ชื่อผู้ใช้นี้มีคนใช้แล้ว — ไปที่ "เข้าสู่ระบบ"');
    }
    await MatrixService.instance
        .login(homeserver: base, username: lp, password: password);
  }

  /// Whether an account already exists for this email (used to keep register
  /// and login as distinct, explicit actions).
  Future<bool> accountExists({
    required String homeserver,
    required String email,
  }) async {
    final base = await _discover(homeserver);
    final username = _localpart(email);
    try {
      final res = await http.get(Uri.parse(
          '$base/_matrix/client/v3/register/available?username=$username'));
      if (res.statusCode == 200) return false; // available → no account yet
      return (jsonDecode(res.body)['errcode']) == 'M_USER_IN_USE';
    } catch (_) {
      return false; // network issue → let the actual call decide
    }
  }

  /// LOGIN only — for an account that already exists. Fails if it doesn't, or
  /// the password is wrong (so it stays distinct from registration).
  Future<void> signInWithEmail({
    required String homeserver,
    required String email,
    required String password,
  }) async {
    final base = await _discover(homeserver);
    final username = _localpart(email);
    try {
      await MatrixService.instance.login(
          homeserver: base, username: username, password: password, email: email);
    } on Object {
      throw Exception('เข้าสู่ระบบไม่สำเร็จ — อีเมลหรือรหัสผ่านไม่ถูกต้อง');
    }
  }

  /// REGISTER only — creates a new account. If the email already has one,
  /// stops with a clear message pointing the user to login (no silent login).
  Future<void> registerWithEmail({
    required String homeserver,
    required String email,
    required String password,
  }) async {
    final base = await _discover(homeserver);
    final username = _localpart(email);
    final creds = await _register(base, username, password);
    if (creds == null) {
      throw Exception('อีเมลนี้มีบัญชีอยู่แล้ว — ไปที่ "เข้าสู่ระบบ"');
    }
    await MatrixService.instance
        .login(homeserver: base, username: username, password: password);
  }

  /// Register the companion ปิ่น account (the assistant identity in the 2-account
  /// E2EE DM). Walks the same UIAA flow as a user registration. Swallows
  /// "already in use" (a prior install registered it) so the caller can log in
  /// with the stored password. Throws on a real failure.
  Future<void> registerCompanion({
    required String homeserver,
    required String username,
    required String password,
  }) async {
    final base = await _discover(homeserver);
    await _register(base, username, password); // null = M_USER_IN_USE → ok
  }

  /// Returns creds on success, null if the username is already taken.
  ///
  /// Walks the UIAA flow generically so it works whether the homeserver gates
  /// registration behind `m.login.dummy` (open) or `m.login.registration_token`
  /// (token-gated). One stage is submitted per request until the flow
  /// completes (200) or the server rejects it.
  Future<_Creds?> _register(String base, String username, String password,
      {String token = kRegistrationToken}) async {
    final url = Uri.parse('$base/_matrix/client/v3/register');
    final payload = <String, dynamic>{
      'username': username,
      'password': password,
      'initial_device_display_name': 'pin',
    };

    // Step 1: empty POST to obtain a UIAA session + the offered flows.
    var res = await http.post(url, headers: _json, body: jsonEncode(payload));
    var body = jsonDecode(res.body) as Map<String, dynamic>;

    // UIAA loop: keep satisfying the next uncompleted stage.
    var guard = 0;
    while (res.statusCode == 401 && guard++ < 5) {
      // A 401 carrying an errcode is a stage rejection (e.g. bad token), not a
      // fresh challenge — stop instead of resubmitting the same bad input.
      if (body['errcode'] != null) break;
      final session = body['session'] as String?;
      final completed =
          (body['completed'] as List?)?.cast<String>() ?? const <String>[];
      final flows = (body['flows'] as List?)
              ?.map((f) => (f['stages'] as List).cast<String>())
              .toList() ??
          const <List<String>>[];

      // Prefer a flow whose every stage we know how to satisfy.
      const known = {'m.login.dummy', 'm.login.registration_token'};
      final stages = flows.firstWhere(
        (st) => st.every(known.contains),
        orElse: () => flows.isNotEmpty ? flows.first : const <String>[],
      );
      final next = stages.firstWhere(
        (s) => !completed.contains(s),
        orElse: () => '',
      );

      final Map<String, dynamic> auth;
      switch (next) {
        case 'm.login.registration_token':
          if (token.isEmpty) {
            throw Exception('สมัครไม่ได้ — ต้องใช้รหัสเชิญ (registration token)');
          }
          auth = {
            'type': 'm.login.registration_token',
            'token': token,
            'session': session,
          };
        case 'm.login.dummy':
          auth = {'type': 'm.login.dummy', 'session': session};
        default:
          throw Exception('สมัครไม่ได้ — ระบบต้องการขั้นตอนที่ไม่รองรับ: $next');
      }

      res = await http.post(url,
          headers: _json, body: jsonEncode({...payload, 'auth': auth}));
      body = jsonDecode(res.body) as Map<String, dynamic>;
    }

    if (res.statusCode == 200) {
      return _Creds(body['user_id'], body['device_id'], body['access_token']);
    }
    if (body['errcode'] == 'M_USER_IN_USE') return null;
    throw Exception(body['error'] ?? 'สมัครไม่สำเร็จ');
  }

  static const _json = {'Content-Type': 'application/json'};
}

class _Creds {
  final String userId;
  final String deviceId;
  final String accessToken;
  _Creds(this.userId, this.deviceId, this.accessToken);
}
