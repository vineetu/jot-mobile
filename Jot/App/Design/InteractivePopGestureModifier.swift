import SwiftUI
import UIKit

private struct InteractivePopGestureRepresentable: UIViewControllerRepresentable {
    let isEnabled: Bool

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        controller.isEnabled = isEnabled
        return controller
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.isEnabled = isEnabled
        uiViewController.updateNavigationController()
    }

    final class Controller: UIViewController {
        private weak var trackedNavigationController: UINavigationController?
        private var originalDelegate: (any UIGestureRecognizerDelegate)?
        private var didStoreOriginalDelegate = false
        private var isAppearing = false
        /// When `false`, the controller restores the original gesture
        /// delegate (so the system's normal "no back button → no swipe"
        /// guard applies) and skips re-overriding on update. Caller flips
        /// this to false e.g. during a TextEditor edit session so a
        /// left-edge swipe can't bypass the SwiftUI-layer lockout and
        /// silently discard unsaved edits.
        var isEnabled: Bool = true {
            didSet {
                guard oldValue != isEnabled else { return }
                if isEnabled, isAppearing {
                    enableGestureIfPossible()
                } else if !isEnabled {
                    restoreGestureDelegate()
                }
            }
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            isAppearing = true
            if isEnabled {
                enableGestureIfPossible()
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            isAppearing = false
            restoreGestureDelegate()
        }

        func updateNavigationController() {
            if isAppearing && isEnabled {
                enableGestureIfPossible()
            } else {
                trackNavigationController(findParentNavigationController())
            }
        }

        private func enableGestureIfPossible() {
            let navigationController = findParentNavigationController()
            trackNavigationController(navigationController)

            guard let gesture = navigationController?.interactivePopGestureRecognizer else {
                return
            }

            if !didStoreOriginalDelegate {
                originalDelegate = gesture.delegate
                didStoreOriginalDelegate = true
            }

            gesture.delegate = nil
        }

        private func trackNavigationController(_ navigationController: UINavigationController?) {
            guard navigationController !== trackedNavigationController else {
                return
            }

            restoreGestureDelegate()
            trackedNavigationController = navigationController
        }

        private func restoreGestureDelegate() {
            if didStoreOriginalDelegate {
                trackedNavigationController?.interactivePopGestureRecognizer?.delegate = originalDelegate
            }

            originalDelegate = nil
            didStoreOriginalDelegate = false
            trackedNavigationController = nil
        }

        private func findParentNavigationController() -> UINavigationController? {
            var controller: UIViewController? = self

            while let current = controller {
                if let navigationController = current as? UINavigationController {
                    return navigationController
                }

                controller = current.parent
            }

            return navigationController
        }
    }
}

extension View {
    /// Re-enable iOS's interactive pop gesture even when the system back
    /// button is hidden. Pass `isEnabled: false` (driven off a SwiftUI
    /// state like `isEditing`) to temporarily restore the system's
    /// default "no back button → no swipe" behavior — useful when an
    /// edge-swipe pop would silently discard in-flight user input.
    func enableInteractivePopGesture(isEnabled: Bool = true) -> some View {
        background(
            InteractivePopGestureRepresentable(isEnabled: isEnabled)
                .frame(width: 0, height: 0)
                .hidden()
        )
    }

    /// Standard chrome for a pushed page that uses a custom top toolbar
    /// (e.g. `DonationsView`'s glass back button) instead of the system
    /// nav bar UI. Apply at the end of the view's modifier chain.
    ///
    /// Produces:
    /// - system back button hidden (the custom toolbar takes over the
    ///   leading affordance);
    /// - nav bar background transparent (the page's own wallpaper /
    ///   gradient shows through);
    /// - edge-swipe-to-back gesture enabled even with the back button
    ///   hidden (see `enableInteractivePopGesture()` for the mechanism).
    ///
    /// **Why this exists**: `.toolbar(.hidden, for: .navigationBar)`
    /// fully removes the nav bar from the layout, and when iOS sees no
    /// nav bar it disables the interactive pop gesture at a level the
    /// delegate-override hack can't reach. Keeping the bar present (but
    /// invisible via transparent background) preserves the gesture
    /// while letting the page render its own header. Any new pushed
    /// page that hides standard nav chrome should use this modifier
    /// instead of `.toolbar(.hidden, for: .navigationBar)`.
    func jotPushedPage() -> some View {
        self
            .navigationBarBackButtonHidden(true)
            .toolbarBackground(.hidden, for: .navigationBar)
            .enableInteractivePopGesture()
    }
}
