import Foundation
import CanvasModule
import NetworkModule

/// Simulator-only dev automation, so Claude/CI can drive the app without a
/// human: skip Sign in with Apple (which can't complete in the simulator) and
/// replay recorded stroke fixtures onto the live canvas. Everything compiles to
/// a no-op outside DEBUG simulator builds.
///
/// Auth bypass — launch the app with pre-minted backend JWTs
/// (`backend/scripts/mint-dev-token.ts`):
///
///   xcrun simctl launch <sim> com.don.Kiki \
///     -KikiDevAccessToken <jwt> -KikiDevRefreshToken <jwt>
///
/// The tokens persist in Keychain, so later launches need no arguments.
///
/// Stroke replay — write a BrushFixture JSON to /tmp/kiki-replay.json (the
/// simulator reads host paths) and post the Darwin notification:
///
///   xcrun simctl spawn <sim> notifyutil -p com.don.kiki.dev.replay
///
/// Driven end-to-end by ios/scripts/sim.sh.
enum DevAutomation {

    #if DEBUG && targetEnvironment(simulator)

    static let replayNotificationName = "com.don.kiki.dev.replay"
    static let defaultReplayPath = "/tmp/kiki-replay.json"
    /// UI-action bridge: write the action name to /tmp/kiki-ui-action.txt and
    /// post this notification. Drives taps the harness can't perform
    /// (popovers, modals) deterministically:
    ///   xcrun simctl spawn <sim> notifyutil -p com.don.kiki.dev.ui
    /// Actions: openDrawing | statusDetails | animateModal | lasso | dismiss
    static let uiNotificationName = "com.don.kiki.dev.ui"
    static let uiActionPath = "/tmp/kiki-ui-action.txt"

    /// Set by AppCoordinator. Called on the main actor with the decoded fixture.
    @MainActor static var onReplayRequested: ((BrushFixture) -> Void)?

    /// Set by AppCoordinator. Called on the main actor with the action name.
    @MainActor static var onUIActionRequested: ((String) -> Void)?

    /// Seed Keychain from launch arguments (UserDefaults argument domain) if
    /// dev tokens were passed. Must run before AppCoordinator's auth gate reads
    /// the Keychain. Safe to call every launch: no-ops without the arguments.
    static func injectAuthIfRequested() {
        let defaults = UserDefaults.standard
        guard
            let access = defaults.string(forKey: "KikiDevAccessToken"),
            let refresh = defaults.string(forKey: "KikiDevRefreshToken"),
            let claims = decodeJWTClaims(access),
            let userId = claims["sub"] as? String,
            let exp = claims["exp"] as? Double
        else { return }
        do {
            try AuthService.devInjectTokens(
                access: access,
                refresh: refresh,
                expiresAt: Date(timeIntervalSince1970: exp),
                userId: userId
            )
            print("DevAutomation: injected dev tokens for user \(userId)")
        } catch {
            print("DevAutomation: token injection failed: \(error)")
        }
    }

    /// Start listening for the stroke-replay Darwin notification.
    static func startReplayListener() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in DevAutomation.handleReplayNotification() },
            replayNotificationName as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in DevAutomation.handleUINotification() },
            uiNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    private static func handleUINotification() {
        let action = (try? String(contentsOfFile: uiActionPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !action.isEmpty else { return }
        Task { @MainActor in
            onUIActionRequested?(action)
        }
    }

    private static func handleReplayNotification() {
        let path = UserDefaults.standard.string(forKey: "KikiDevReplayPath") ?? defaultReplayPath
        guard let data = FileManager.default.contents(atPath: path) else {
            print("DevAutomation: no fixture at \(path)")
            return
        }
        do {
            let fixture = try JSONDecoder().decode(BrushFixture.self, from: data)
            Task { @MainActor in
                onReplayRequested?(fixture)
            }
        } catch {
            print("DevAutomation: fixture decode failed: \(error)")
        }
    }

    /// Base64url-decode a JWT's payload without verification (the backend is
    /// the verifier; this is only to read `sub`/`exp` for local bookkeeping).
    private static func decodeJWTClaims(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count == 3 else { return nil }
        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    #else

    @MainActor static var onReplayRequested: ((BrushFixture) -> Void)?
    @MainActor static var onUIActionRequested: ((String) -> Void)?
    static func injectAuthIfRequested() {}
    static func startReplayListener() {}

    #endif
}
