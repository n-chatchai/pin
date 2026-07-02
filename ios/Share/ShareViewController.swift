import UIKit

/// The OS "Share to ปิ่น" extension. Subclasses the vendored controller, which
/// writes the shared items into the app group and reopens the host app via the
/// `ShareMedia-<bundleId>` URL scheme. Auto-redirect → no compose screen; the
/// share hands straight off to ปิ่น.
class ShareViewController: RSIShareViewController {
    override func shouldAutoRedirect() -> Bool { true }
}
