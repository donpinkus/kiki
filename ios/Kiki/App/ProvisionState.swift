import Foundation

/// Server-side stream state codes. Mirrors the state strings emitted by
/// `backend/src/routes/stream.ts` `sendState`. Backend sends these as
/// raw strings over the WebSocket; iOS maps them to display text locally —
/// backend never emits display strings anymore.
public enum ProvisionState: String, Decodable, Sendable {
    case connecting
    case ready
}

/// Returns the user-facing string for a given stream state. Backend
/// owns state; iOS owns presentation.
public func displayText(for state: ProvisionState) -> String {
    switch state {
    case .connecting: return "Connecting..."
    case .ready:      return "Ready"
    }
}
