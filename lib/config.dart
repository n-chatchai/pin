/// App-wide identity/config constants kept in one place so the homeserver
/// doesn't drift across screens and services.
///
/// The registration token lives in [AuthService] (auth_service.dart) since it
/// is only meaningful there and is supplied at build time.
library;

/// Matrix homeserver this app talks to — a server *name*, not a URL.
/// `AuthService` resolves the actual base URL via `.well-known/matrix/client`.
const kHomeserver = 'pin-chat.tokens2.io';
