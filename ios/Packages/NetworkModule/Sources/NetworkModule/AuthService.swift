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
        case backendRejected(String)
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
        try await refresh(using: bundle.refreshToken)
        guard let refreshed = currentBundle() else {
            throw AuthError.refreshFailed("no token after refresh")
        }
        return refreshed.accessToken
    }

    /// Clears all credentials from Keychain. Call on explicit sign-out.
    public func signOut() {
        keychain.remove(Self.keychainAccessToken)
        keychain.remove(Self.keychainRefreshToken)
        keychain.remove(Self.keychainAccessExpiresAt)
        keychain.remove(Self.keychainUserId)
        keychain.remove(Self.keychainEmail)
    }

    /// Best-effort: ask the backend to terminate the user's pod and delete
    /// their Redis session. Call BEFORE `signOut()` so the JWT is still
    /// available for the request. Failures are logged but never thrown — the
    /// local sign-out must always succeed regardless of backend reachability.
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
        let url = backendURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, rawResponse) = try await urlSession.data(for: request)
        guard let http = rawResponse as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        if !(200..<300).contains(http.statusCode) {
            if let parsed = try? JSONDecoder().decode(BackendError.self, from: data) {
                throw AuthError.backendRejected(parsed.message ?? parsed.error ?? "HTTP \(http.statusCode)")
            }
            throw AuthError.backendRejected("HTTP \(http.statusCode)")
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
