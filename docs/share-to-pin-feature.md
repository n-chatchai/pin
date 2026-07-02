# Share to ปิ่น

OS share sheet → chat. Share URL/text/image/doc from any app into ปิ่น; a YouTube link gets the native-Gemini video summary (see `pin-tier-native-gemini`). Built 2026-07-02, commits b28bc4c (Dart+Android) + 830d07b (iOS).

## Architecture

`receive_sharing_intent` **pinned 1.8.1** (1.9+ is SPM-only; project uses CocoaPods). `main.dart` bridges getInitialMedia+getMediaStream → `SharedInbox` (`lib/services/shared_inbox.dart`, a buffer since a cold-start share lands before chat mounts). `LocalChatScreen._maybeDrainShared` drains on boot/resume/onboarding-finish/new-item, gated on room-up + not-onboarding. Pure `classifyShared` routes url/text→`_onSend`, image→`_sendImage`, file→`_convertAndSummarize`.

## Android

ACTION_SEND (text/image/application) + SEND_MULTIPLE filters on singleTop MainActivity. Gradle: root `build.gradle.kts` forces Java 17 on plugin subprojects (1.8.x declares Java 8 vs Kotlin 17 → inconsistent JVM target). **Verified**: APK builds, 6/6 `shared_inbox_test`.

## iOS

`ios/Share/` target `io.tokens2.pin.Share`: **vendored** RSIShareViewController + model into the extension instead of linking the pod — the pod compiles a host-side registrant (`addApplicationDelegate`) illegal under an extension's `APPLICATION_EXTENSION_API_ONLY=YES`. Host (Runner) still links the pod, reads app-group JSON. App group `group.io.tokens2.pin` on both entitlements. `ShareMedia-$(bundleid)` URL scheme; SceneDelegate forwards it (UIScene lifecycle). Embed phase ordered BEFORE Thin Binary (else build cycle). Bumped iOS min 13→15.1 (Podfile floor). Target added via the `xcodeproj` ruby gem. **Verified**: `flutter build ios --no-codesign` embeds `Share.appex`.

### iOS not yet runnable on device — manual steps remain

1. Register App Group `group.io.tokens2.pin` in the Apple Developer portal; enable on both `io.tokens2.pin` + `io.tokens2.pin.Share` App IDs.
2. Provisioning — Xcode automatic signing OR update fastlane match/sigh for the new extension bundle id + app-group entitlement.
3. Device build to verify runtime (share sheet → app reopens → getInitialMedia picks up).

## Known gap

BYO OpenAI/Groq/Claude providers still can't summarize YouTube (only ปิ่น native-Gemini can); a `fetch_url`+caption tool would cover them.
