import UIKit

/// Installs a window-level gesture recognizer that dismisses the keyboard
/// on any touch that doesn't originate inside a `UITextField`/`UITextView`.
/// `cancelsTouchesInView = false` means touches still reach their normal
/// targets — buttons fire, canvas strokes draw — while the keyboard also
/// dismisses.
enum KeyboardDismissal {
    static func installIfNeeded() {
        Installer.shared.install()
    }
}

private final class AnyTouchGestureRecognizer: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if state == .possible { state = .recognized }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }
}

private final class Installer: NSObject, UIGestureRecognizerDelegate {
    static let shared = Installer()
    private weak var installedOn: UIWindow?

    func install() {
        guard installedOn == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else {
            return
        }
        let gr = AnyTouchGestureRecognizer(target: self, action: #selector(handleTouch))
        gr.cancelsTouchesInView = false
        gr.delegate = self
        window.addGestureRecognizer(gr)
        installedOn = window
    }

    @objc private func handleTouch() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    func gestureRecognizer(_ gr: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var current: UIView? = touch.view
        while let v = current {
            if v is UITextField || v is UITextView { return false }
            current = v.superview
        }
        return true
    }

    func gestureRecognizer(
        _ gr: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
