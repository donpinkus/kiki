import Photos
import UIKit

/// Deep-links a video into Instagram Stories via the documented pasteboard
/// hand-off. No SDK required.
enum InstagramStories {
    /// Meta requires a `source_application` on the share URL. The bundle id works
    /// on current Instagram builds; if Instagram rejects the share, register a
    /// Meta (Facebook) App ID at developers.facebook.com and put it here.
    static let sourceApplication = Bundle.main.bundleIdentifier ?? "com.don.Kiki"

    /// Put the video on the pasteboard and open Instagram's story composer.
    /// `completion(false)` means Instagram couldn't be opened (not installed).
    static func share(videoURL: URL, completion: @escaping (Bool) -> Void) {
        guard let data = try? Data(contentsOf: videoURL),
              let url = URL(string: "instagram-stories://share?source_application=\(sourceApplication)") else {
            completion(false)
            return
        }
        let items: [[String: Any]] = [["com.instagram.sharedSticker.backgroundVideo": data]]
        UIPasteboard.general.setItems(items, options: [.expirationDate: Date().addingTimeInterval(60 * 5)])
        UIApplication.shared.open(url, options: [:], completionHandler: completion)
    }
}

/// Saves a video file to the user's photo library (add-only authorization).
enum PhotoLibrarySaver {
    static func saveVideo(_ url: URL) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            return true
        } catch {
            return false
        }
    }
}
