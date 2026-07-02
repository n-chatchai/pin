import Flutter
import UIKit
import receive_sharing_intent

/// The app uses the UIScene lifecycle, so URL opens arrive here — not on the
/// AppDelegate. The Share Extension reopens ปิ่น via the `ShareMedia-<bundleId>`
/// scheme; forward those to receive_sharing_intent (it reads the shared items
/// from the app group). Everything else falls through to Flutter's default.
class SceneDelegate: FlutterSceneDelegate {

  /// App already running → a share arrives as an open-URL on the live scene.
  override func scene(
    _ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    if let url = URLContexts.first?.url, handleShare(url) { return }
    super.scene(scene, openURLContexts: URLContexts)
  }

  /// Cold start from a share → the URL rides in the connection options.
  override func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    if let url = connectionOptions.urlContexts.first?.url { _ = handleShare(url) }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  private func handleShare(_ url: URL) -> Bool {
    let sharing = SwiftReceiveSharingIntentPlugin.instance
    guard sharing.hasMatchingSchemePrefix(url: url) else { return false }
    return sharing.application(UIApplication.shared, open: url, options: [:])
  }
}
