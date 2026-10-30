import MailVerdictKit
import SwiftUI
import UIKit

/// What the system opens when MailVerdict is picked in the share sheet.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        let inputItems = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = inputItems.flatMap { $0.attachments ?? [] }

        let screen = ShareScreen(providers: providers, close: { [weak self] in self?.close() })
        let host = UIHostingController(rootView: screen)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private func close() {
        SharedItemLoader.removeTemporaryFiles()
        extensionContext?.completeRequest(returningItems: nil)
    }
}
