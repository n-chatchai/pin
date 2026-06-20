/// App-wide identity/config constants kept in one place so the homeserver
/// doesn't drift across screens and services.
///
/// The registration token lives in [AuthService] (auth_service.dart) since it
/// is only meaningful there and is supplied at build time.
library;

/// Matrix homeserver this app talks to — a server *name*, not a URL.
/// `AuthService` resolves the actual base URL via `.well-known/matrix/client`.
const kHomeserver = 'pin-chat.tokens2.io';

/// Internal/debug build flag — gates dev-only affordances (e.g. the API-log
/// shortcut in the chat). Pass `--dart-define=PIN_DEBUG=true` for internal
/// builds; the store build omits it.
const kDebugBuild = bool.fromEnvironment('PIN_DEBUG');

/// Matrix HTTP inspector flag — when set, matrix-sdk is routed through the
/// in-process loopback proxy so every Matrix request/response can be logged.
/// SEPARATE from [kDebugBuild] and OFF by default: the proxy MITMs all Matrix
/// traffic, so a forwarding bug breaks login/recovery. Only opt in deliberately
/// to capture traffic: `--dart-define=PIN_INSPECTOR=true`.
const kInspectorBuild = bool.fromEnvironment('PIN_INSPECTOR');
