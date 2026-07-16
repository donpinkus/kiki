import SwiftUI
import AuthenticationServices
import NetworkModule

/// Sign in with Apple gate. Shown when the user isn't authenticated.
/// On success, AppCoordinator transitions to the gallery.
struct SignInView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme

    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            VStack(spacing: 16) {
                Text("Kiki")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                Text("Sketch with AI")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 12) {
                SignInWithAppleButton(.signIn) { request in
                    // Request email so we can attach an address to the account (receipts,
                    // support, recovery). Apple only returns it on the FIRST authorization
                    // for this Apple ID + app, and only embeds it in the identity token
                    // (which the backend verifies) when this scope is requested. May be a
                    // private relay (@privaterelay.appleid.com) if the user picks Hide My Email.
                    request.requestedScopes = [.email]
                } onCompletion: { result in
                    handleCompletion(result)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 54)
                .frame(maxWidth: 380)
                .disabled(isSigningIn)

                if isSigningIn {
                    ProgressView()
                        .controlSize(.small)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                Text("Sign in to start drawing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleCompletion(_ result: Result<ASAuthorization, Error>) {
        errorMessage = nil
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let identityTokenData = credential.identityToken,
                let identityToken = String(data: identityTokenData, encoding: .utf8)
            else {
                showError("Couldn't read Apple credential.")
                return
            }
            isSigningIn = true
            Task {
                do {
                    try await coordinator.signInWithApple(identityToken: identityToken)
                    await MainActor.run { isSigningIn = false }
                } catch {
                    await MainActor.run {
                        isSigningIn = false
                        showError("Sign in failed: \(error.localizedDescription)")
                    }
                }
            }
        case .failure(let error):
            if let asError = error as? ASAuthorizationError, asError.code == .canceled {
                return  // user cancelled, no error to show
            }
            showError("Sign in failed: \(error.localizedDescription)")
        }
    }

    /// Single chokepoint for surfacing a sign-in error — sets the visible
    /// message and reports it so error banners stand out in Insights timelines.
    private func showError(_ message: String) {
        errorMessage = message
        Analytics.track(.errorBannerShown, properties: [
            "message": message,
            "surface": "sign_in",
        ])
    }
}
