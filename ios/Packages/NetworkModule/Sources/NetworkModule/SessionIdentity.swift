import Foundation

/// Stable per-install identifier used to route WebSocket connections to
/// a dedicated GPU pod on the backend.
///
/// Generated on first launch, persisted in UserDefaults. The backend uses it
/// to reuse the same pod across app relaunches (within the 10-min idle window)
/// and to keep concurrent users isolated on separate GPUs.
public enum SessionIdentity {
    private static let key = "kiki.sessionId"

    public static func load() -> String {
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }
}
