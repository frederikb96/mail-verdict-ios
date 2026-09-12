import SwiftUI
import UIKit

/// Reports a swipe-down on a sheet that refuses to close (`interactiveDismissDisabled`) — the
/// moment Mail asks whether to save the draft. SwiftUI has no callback for it; UIKit reports it to
/// the presentation controller's delegate, so this installs itself there and hands every other
/// delegate call to the delegate that was already in place.
struct DismissAttemptObserver: UIViewControllerRepresentable {
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> ObserverController {
        ObserverController(onAttempt: onAttempt)
    }

    func updateUIViewController(_ controller: ObserverController, context: Context) {
        controller.onAttempt = onAttempt
    }

    final class ObserverController: UIViewController, UIAdaptivePresentationControllerDelegate {
        var onAttempt: () -> Void
        private weak var original: (any UIAdaptivePresentationControllerDelegate)?

        init(onAttempt: @escaping () -> Void) {
            self.onAttempt = onAttempt
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let presentation = presentationController, presentation.delegate !== self else { return }
            original = presentation.delegate
            presentation.delegate = self
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            original?.presentationControllerDidAttemptToDismiss?(presentationController)
            onAttempt()
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            original?.presentationControllerShouldDismiss?(presentationController) ?? true
        }

        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            original?.presentationControllerWillDismiss?(presentationController)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            original?.presentationControllerDidDismiss?(presentationController)
        }

        func adaptivePresentationStyle(
            for controller: UIPresentationController, traitCollection: UITraitCollection
        ) -> UIModalPresentationStyle {
            original?.adaptivePresentationStyle?(for: controller, traitCollection: traitCollection)
                ?? controller.presentationStyle
        }
    }
}
