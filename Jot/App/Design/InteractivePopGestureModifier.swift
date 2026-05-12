import SwiftUI
import UIKit

private struct InteractivePopGestureRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.updateNavigationController()
    }

    final class Controller: UIViewController {
        private weak var trackedNavigationController: UINavigationController?
        private var originalDelegate: (any UIGestureRecognizerDelegate)?
        private var didStoreOriginalDelegate = false
        private var isAppearing = false

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            isAppearing = true
            enableGestureIfPossible()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            isAppearing = false
            restoreGestureDelegate()
        }

        func updateNavigationController() {
            if isAppearing {
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
    func enableInteractivePopGesture() -> some View {
        background(
            InteractivePopGestureRepresentable()
                .frame(width: 0, height: 0)
                .hidden()
        )
    }
}
