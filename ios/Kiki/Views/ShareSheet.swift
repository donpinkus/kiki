import SwiftUI
import UIKit

/// SwiftUI wrapper around `UIActivityViewController` — the native iOS share
/// sheet that provides both "Save to Files" and the app-share carousel
/// (AirDrop, Messages, Mail, Gmail-if-installed, …) with no per-app work.
///
/// Presented via `.sheet(item:)`; SwiftUI supplies the iPad presentation
/// context so the activity controller's popover anchoring is handled for us.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var onComplete: ((Bool) -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onComplete?(completed)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
