import UIKit
import Social

/// Scaffold only — share extension UI and node creation implemented in Session 2+.
final class ShareViewController: SLComposeServiceViewController {

    override func isContentValid() -> Bool {
        true
    }

    override func didSelectPost() {
        // TODO: Session 2+ — parse incoming share items and create an AirPad node
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    override func configurationItems() -> [Any]! {
        []
    }
}
