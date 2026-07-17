import Foundation
import Sentry

/// Manages user authentication: Sign in with Apple → JWT access/refresh pair.
///
/// Tokens persist in Keychain (survives relaunches but stays on-device).
/// `currentAccessToken()` auto-refreshes if the stored access token is within
/// the 60s refresh window of its expiry.
public actor AuthService {

    // MARK: - Types

    public enum AuthError: Error, Sendable {
        case noToken
        case appleSignInFailed(String)
        /// The backend rejected the credentials themselves (401/403). This is
        /// the only error class that justifies clearing the Keychain.
        case backendRejected(String)
        /// The backend answered with a non-auth failure (5xx, 429, proxy
        /// pages during a redeploy). Transient — never clear credentials.
        case serverError(status: Int, message: String)
        case refreshFailed(String)
        case invalidResponse
    }

    public struct TokenBundle: Codable, Sendable, Equatable {
        public let accessToken: String
        public let refreshToken: String
        public let accessExpiresAt: Date
        public let userId: String
        public let email: String?
    }

    // MARK: - Private types

    private struct AppleLoginRequest: Codable {
        let identityToken: String
        let nonce: String?
    }

    private struct TokenResponse: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let userId: String?
        let email: String?
    }

    private struct RefreshRequest: Codable {
        let refreshToken: String
    }

    private struct VerifySubscriptionRequest: Codable {
        let jws: String
    }

    /// Result of `/v1/subscription/verify`. `expiresAt` is epoch milliseconds
    /// (or nil if never subscribed).
    public struct SubscriptionStatusResponse: Codable, Sendable {
        public let subscriptionStatus: String
        public let expiresAt: Double?
    }

    /// Result of `/v1/usage` — the user's current free-tier fal spend. `exempt`
    /// is true for test accounts + active subscribers (the meter is hidden).
    public struct UsageResponse: Codable, Sendable {
        public let spendUsd: Double
        public let capUsd: Double
        public let exempt: Bool
    }

    // MARK: - Constants

    /// Refresh proactively when the access token has less than this many seconds left.
    private static let refreshThresholdSeconds: TimeInterval = 60

    private static let keychainAccessToken = "accessToken"
    private static let keychainRefreshToken = "refreshToken"
    private static let keychainAccessExpiresAt = "accessExpiresAt"
    private static let keychainUserId = "userId"
    private static let keychainEmail = "email"

    // MARK: - State

    private let backendURL: URL
    private let keychain: KeychainStore
    private let urlSession: URLSession

    public init(
        backendURL: URL,
        keychain: KeychainStore = .default,
        urlSession: URLSession = .shared
    ) {
        self.backendURL = backendURL
        self.keychain = keychain
        self.urlSession = urlSession
    }

    // MARK: - Public

    /// True if there's a token bundle in Keychain (regardless of expiry).
    public var isSignedIn: Bool {
        return currentBundle() != nil
    }

    /// The signed-in userId, if any.
    public var userId: String? {
        return currentBundle()?.userId
    }

    /// The signed-in user's email, if the backend has one for this user.
    /// May be a real address or an Apple private-relay address. Only set for
    /// users who shared their email with us on first Apple sign-in (or whose
    /// record has one from a prior sign-in).
    public var email: String? {
        return currentBundle()?.email
    }

    /// Exchanges an Apple identity token for a backend-issued access+refresh pair.
    /// Call from the Sign in with Apple completion handler.
    public func signInWithApple(identityToken: String, nonce: String?) async throws {
        let body = AppleLoginRequest(identityToken: identityToken, nonce: nonce)
        do {
            let response: TokenResponse = try await post(path: "/v1/auth/apple", body: body)
            try save(from: response)
        } catch {
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "auth.signInWithApple", key: "op")
            }
            throw error
        }
    }

    /// Returns a valid access token, refreshing if close to expiry.
    /// Throws `AuthError.noToken` if the user isn't signed in.
    public func currentAccessToken() async throws -> String {
        guard let bundle = currentBundle() else {
            throw AuthError.noToken
        }
        let now = Date()
        let needsRefresh = bundle.accessExpiresAt.timeIntervalSince(now) < Self.refreshThresholdSeconds

        if !needsRefresh {
            return bundle.accessToken
        }
        try await ensureFreshToken()
        guard let refreshed = currentBundle() else {
            throw AuthError.refreshFailed("no token after refresh")
        }
        return refreshed.accessToken
    }

    /// Single-flight refresh. The backend rotates refresh tokens one-time-use,
    /// so two concurrent refreshes with the same stored token would race: the
    /// first wins, the second gets `invalid_refresh_token` and (pre-fix) wiped
    /// the winner's fresh Keychain bundle. Cold launch fires several
    /// near-simultaneous `currentAccessToken()` callers (entitlements, usage,
    /// stream, lambda pool), so this coalescing is load-bearing, not hygiene.
    private var inFlightRefresh: Task<Void, Error>?

    private func ensureFreshToken() async throws {
        if let existing = inFlightRefresh {
            try await existing.value
            return
        }
        let task = Task<Void, Error> {
            // Cleared by the task itself (not the awaiter) so an awaiting
            // caller's cancellation can't open the slot while the refresh is
            // still in flight.
            defer { self.inFlightRefresh = nil }
            // Re-read inside the task: the bundle may have been rotated by a
            // refresh that completed between the caller's check and now.
            guard let bundle = self.currentBundle() else { throw AuthError.noToken }
            if bundle.accessExpiresAt.timeIntervalSinceNow >= Self.refreshThresholdSeconds {
                return
            }
            try await self.refresh(using: bundle.refreshToken)
        }
        inFlightRefresh = task
        try await task.value
    }

    /// Submit a StoreKit 2 `Transaction.jwsRepresentation` to the backend for
    /// verification. The backend validates the Apple signature, records the
    /// subscription state, and returns the resulting status. Authenticated with
    /// the current access token (auto-refreshes). Call after a purchase, for
    /// Restore Purchases, and on launch for each current entitlement.
    public func verifySubscription(jws: String) async throws -> SubscriptionStatusResponse {
        let token = try await currentAccessToken()
        return try await authedPost(
            path: "/v1/subscription/verify",
            body: VerifySubscriptionRequest(jws: jws),
            token: token
        )
    }

    /// Response from the Lambda dev-pool endpoints (test accounts only).
    public struct LambdaPoolState: Codable, Sendable {
        public let status: String
        public let message: String
        public let ip: String?
    }

    private struct EmptyBody: Encodable {}

    /// Ask the backend to spin up (or keep alive) the Lambda H100 dev
    /// instance backing the `imageProvider=lambda` toggle. Test accounts
    /// only — the backend 403s for everyone else. Non-blocking server-side:
    /// returns the pool's current state immediately.
    public func ensureLambdaPool() async throws -> LambdaPoolState {
        let token = try await currentAccessToken()
        return try await authedPost(
            path: "/v1/dev/lambda/ensure",
            body: EmptyBody(),
            token: token
        )
    }

    /// Fetch the signed-in user's current free-tier usage (for the in-app
    /// meter). Authenticated; auto-refreshes the access token.
    public func fetchUsage() async throws -> UsageResponse {
        let token = try await currentAccessToken()
        let url = backendURL.appendingPathComponent("/v1/usage")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, rawResponse) = try await urlSession.data(for: request)
        guard let http = rawResponse as? HTTPURLResponse else { throw AuthError.invalidResponse }
        if !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AuthError.backendRejected("HTTP \(http.statusCode)")
            }
            throw AuthError.serverError(status: http.statusCode, message: "HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw AuthError.invalidResponse
        }
    }

    /// Clears all credentials from Keychain. Call on explicit sign-out.
    public func signOut() {
        keychain.remove(Self.keychainAccessToken)
        keychain.remove(Self.keychainRefreshToken)
        keychain.remove(Self.keychainAccessExpiresAt)
        keychain.remove(Self.keychainUserId)
        keychain.remove(Self.keychainEmail)
    }

    /// Best-effort: notify the backend that the user signed out. The endpoint
    /// is now just a sign-out marker (no pod or Redis session to clean up).
    /// Call BEFORE `signOut()` so the JWT is still available for the request.
    /// Failures are logged but never thrown — the local sign-out must always
    /// succeed regardless of backend reachability.
    public func requestServerSignOut() async {
        guard let token = currentBundle()?.accessToken else { return }
        let url = backendURL.appendingPathComponent("/v1/auth/signout")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                SentrySDK.capture(message: "auth.serverSignOut.nonOk") { scope in
                    scope.setLevel(.warning)
                    scope.setExtra(value: http.statusCode, key: "status")
                }
            }
        } catch {
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "auth.serverSignOut", key: "op")
                scope.setLevel(.warning)
            }
        }
    }

    // MARK: - Private

    private func currentBundle() -> TokenBundle? {
        guard
            let access = keychain.get(Self.keychainAccessToken),
            let refresh = keychain.get(Self.keychainRefreshToken),
            let expiresAtString = keychain.get(Self.keychainAccessExpiresAt),
            let expiresAtSec = TimeInterval(expiresAtString),
            let userId = keychain.get(Self.keychainUserId)
        else {
            return nil
        }
        return TokenBundle(
            accessToken: access,
            refreshToken: refresh,
            accessExpiresAt: Date(timeIntervalSince1970: expiresAtSec),
            userId: userId,
            email: keychain.get(Self.keychainEmail)
        )
    }

    private func save(from response: TokenResponse) throws {
        let expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        try keychain.set(response.accessToken, for: Self.keychainAccessToken)
        try keychain.set(response.refreshToken, for: Self.keychainRefreshToken)
        try keychain.set(String(expiresAt.timeIntervalSince1970), for: Self.keychainAccessExpiresAt)
        if let userId = response.userId {
            try keychain.set(userId, for: Self.keychainUserId)
        }
        // Only overwrite email when the backend sent one — /v1/auth/refresh
        // will omit it for users whose record never captured it (Apple only
        // returns email on the first sign-in).
        if let email = response.email {
            try keychain.set(email, for: Self.keychainEmail)
        }
    }

    private func refresh(using refreshToken: String) async throws {
        let body = RefreshRequest(refreshToken: refreshToken)
        do {
            let response: TokenResponse = try await post(path: "/v1/auth/refresh", body: body)
            try save(from: response)
        } catch AuthError.backendRejected(let message) {
            // Refresh tokens expire or get rotated; clear stale bundle so the caller re-signs in.
            SentrySDK.capture(message: "auth.refresh.rejected") { scope in
                scope.setLevel(.warning)
                scope.setExtra(value: message, key: "backendMessage")
            }
            signOut()
            throw AuthError.refreshFailed(message)
        } catch {
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "auth.refresh", key: "op")
            }
            throw error
        }
    }

    private func post<Req: Encodable, Resp: Decodable>(path: String, body: Req) async throws -> Resp {
        return try await send(path: path, body: body, token: nil)
    }

    /// Like `post`, but attaches a Bearer token for authenticated endpoints.
    private func authedPost<Req: Encodable, Resp: Decodable>(
        path: String, body: Req, token: String
    ) async throws -> Resp {
        return try await send(path: path, body: body, token: token)
    }

    private func send<Req: Encodable, Resp: Decodable>(
        path: String, body: Req, token: String?
    ) async throws -> Resp {
        let url = backendURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, rawResponse) = try await urlSession.data(for: request)
        guard let http = rawResponse as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        if !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(BackendError.self, from: data))
                .flatMap { $0.message ?? $0.error } ?? "HTTP \(http.statusCode)"
            // Only 401/403 mean "your credentials are bad." Everything else
            // (5xx during a Railway redeploy, 429, proxy error pages) is
            // transient and must NOT trigger the credential-wiping paths.
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AuthError.backendRejected(message)
            }
            throw AuthError.serverError(status: http.statusCode, message: message)
        }

        do {
            return try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            throw AuthError.invalidResponse
        }
    }
}

private struct BackendError: Decodable {
    let error: String?
    let message: String?
}
