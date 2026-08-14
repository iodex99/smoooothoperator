import AuthenticationServices
import CryptoKit
import SwiftUI

/// Sign in (spec §§29, 95). Apple and Google, and never a password of our
/// own — we hold no credentials at all. Apple is listed first because the
/// App Store requires it wherever a third-party login is offered, and
/// because it is the least data we can ask for.
///
/// Signing in is OPTIONAL. Driving, scoring and the local run queue all work
/// signed out — an account is what makes a run *count*: uploaded, verified,
/// ranked. The copy says exactly that instead of blocking the door.
struct SignInView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    /// Shown as a first-run step (with a skip) vs. opened deliberately later.
    var isOnboardingStep = false

    @State private var nonce = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        ZStack {
            SOTheme.ground.ignoresSafeArea()
            RadialGradient(
                colors: [SOTheme.heatStart.opacity(0.10), .clear],
                center: .top, startRadius: 0, endRadius: 420
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()
                ZStack {
                    GlowRing(progress: 1, lineWidth: 5)
                        .frame(width: 84, height: 84)
                    Image(systemName: "person.badge.shield.checkmark")
                        .font(.system(.title))
                        .foregroundStyle(SOTheme.heat)
                }
                .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("Make it count")
                        .font(.system(.title, design: .rounded).weight(.black))
                        .foregroundStyle(.white)
                    Text("An account is what turns a drive into a ranked, verified run.")
                        .font(.subheadline)
                        .foregroundStyle(SOTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 30)

                VStack(alignment: .leading, spacing: 13) {
                    Reason(icon: "trophy", text: "Your runs upload and rank on the leaderboards")
                    Reason(icon: "person.2", text: "Add friends and race their ghosts")
                    Reason(icon: "icloud", text: "Your runs follow you to a new phone")
                }
                .soCard(padding: 18)
                .padding(.horizontal, 24)

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(SOTheme.caution)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 28)
                }

                Spacer()

                VStack(spacing: 12) {
                    SignInWithAppleButton(.signIn) { request in
                        // Apple signs a hash of the nonce; Supabase verifies
                        // the raw one against it. Replay protection.
                        nonce = Self.randomNonce()
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = Self.sha256(nonce)
                    } onCompletion: { result in
                        handle(result)
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 52)
                    .clipShape(Capsule())
                    .disabled(working)

                    Button {
                        Task { await signInWithGoogle() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "globe")
                                .font(.headline)
                            Text("Continue with Google")
                                .font(.system(.headline, design: .rounded).weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(SOTheme.elevated, in: Capsule())
                        .overlay(Capsule().strokeBorder(SOTheme.hairline, lineWidth: 1))
                    }
                    .disabled(working)

                    Button(isOnboardingStep ? "Not now — just let me drive" : "Cancel") {
                        dismiss()
                    }
                    .font(.footnote.weight(.semibold))
                    .tint(SOTheme.textSecondary)
                    .frame(minHeight: 44)   // tap target, not decoration

                    Text("We store the id your provider gives us and the runs you record. Nothing else — no password, no contacts.")
                        .font(.caption2)
                        .foregroundStyle(SOTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let failure):
            // Cancelling is not an error worth shouting about.
            if (failure as NSError).code == ASAuthorizationError.canceled.rawValue { return }
            error = "Apple sign-in didn't complete. Please try again."
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                error = "Apple didn't return a usable credential. Please try again."
                return
            }
            working = true
            Task {
                defer { working = false }
                do {
                    try await environment.signIn(identityToken: identityToken, nonce: nonce)
                    dismiss()
                } catch {
                    self.error = "Couldn't reach Smooooth Operator. Check your connection and try again."
                }
            }
        }
    }

    /// Google (and any other provider enabled later) goes through
    /// ASWebAuthenticationSession — no provider SDK in the binary. The
    /// system browser owns the credentials; we only ever see the callback.
    @MainActor
    private func signInWithGoogle() async {
        guard let api = environment.api,
              let url = api.authorizeURL(provider: "google", redirectScheme: Self.callbackScheme)
        else {
            error = "Sign-in isn't configured in this build."
            return
        }
        working = true
        defer { working = false }
        do {
            let callback = try await WebAuthenticator.authenticate(
                url: url,
                callbackScheme: Self.callbackScheme
            )
            try await environment.completeOAuth(callbackURL: callback)
            dismiss()
        } catch WebAuthenticator.Failure.cancelled {
            // The user backed out; not an error.
        } catch {
            self.error = "Google sign-in didn't complete. Please try again."
        }
    }

    /// Must match CFBundleURLSchemes in project.yml and the redirect URL
    /// allow-list in the Supabase dashboard.
    static let callbackScheme = "smooothoperator"

    // MARK: - Nonce

    private static func randomNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct Reason: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SOTheme.heatStart)
                .frame(width: 30, height: 30)
                .background(SOTheme.heatStart.opacity(0.12), in: Circle())
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
