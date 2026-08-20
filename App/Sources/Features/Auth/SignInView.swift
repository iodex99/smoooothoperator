import AuthenticationServices
import CryptoKit
import SOSync
import SwiftUI

/// Sign in (spec §§29, 95). Apple, Google, and an emailed six-digit code —
/// and never a password of our own. Apple is listed first because the App
/// Store requires it wherever a third-party login is offered, and because it
/// is the least data we can ask for.
///
/// The email door was added 2026-08-20. Apple and Google between them cover
/// most people and exclude a real slice: anyone holding neither account, and
/// anyone who will not hand a social login to a driving app. It is a CODE,
/// not a password, so we still store no credential, there is no reset flow
/// to get wrong, and a breach of this database exposes no reusable secret.
///
/// One field serves both sign-up and sign-in. Asking people which they are
/// is a question they get wrong, and getting it wrong is a dead end rather
/// than a retry.
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

    // Email code flow. `sentTo` holds the NORMALISED address the code was
    // issued to — never what was typed — because GoTrue matches the code
    // against that exact string.
    @State private var email = ""
    @State private var code = ""
    @State private var sentTo: String?
    @State private var secondsSinceSend = 0
    @State private var notice: String?
    @FocusState private var codeFocused: Bool

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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

                    // ── the third door ────────────────────────────────
                    HStack(spacing: 10) {
                        Rectangle().fill(SOTheme.hairline).frame(height: 1)
                        Text("or")
                            .font(.caption)
                            .foregroundStyle(SOTheme.textSecondary)
                        Rectangle().fill(SOTheme.hairline).frame(height: 1)
                    }
                    .padding(.vertical, 2)
                    .accessibilityHidden(true)

                    if sentTo == nil {
                        emailEntry
                    } else {
                        codeEntry
                    }

                    Button(isOnboardingStep ? "Not now — just let me drive" : "Cancel") {
                        dismiss()
                    }
                    .font(.footnote.weight(.semibold))
                    .tint(SOTheme.textSecondary)
                    .frame(minHeight: 44)   // tap target, not decoration

                    if let notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(SOTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    Text("We store your email or the id your provider gives us, and the runs you record. Nothing else — no password, no contacts.")
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

    // MARK: - Email code

    @ViewBuilder
    private var emailEntry: some View {
        VStack(spacing: 10) {
            TextField("you@example.com", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .onSubmit { Task { await sendCode() } }
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(SOTheme.elevated, in: Capsule())
                .overlay(Capsule().strokeBorder(SOTheme.hairline, lineWidth: 1))
                .accessibilityLabel("Email address")

            Button {
                Task { await sendCode() }
            } label: {
                Text("Email me a code")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(GhostButtonStyle())
            // Validated locally so an obvious typo costs nothing. The
            // authoritative test is whether the code arrives.
            .disabled(working || EmailSignIn.normalize(email) == nil)
        }
    }

    @ViewBuilder
    private var codeEntry: some View {
        VStack(spacing: 10) {
            if let sentTo {
                Text("Code sent to \(sentTo)")
                    .font(.footnote)
                    .foregroundStyle(SOTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("6-digit code", text: $code)
                .textContentType(.oneTimeCode)   // lets iOS autofill it
                .keyboardType(.numberPad)
                .focused($codeFocused)
                .font(.system(.title3, design: .monospaced).weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(height: 52)
                .background(SOTheme.elevated, in: Capsule())
                .overlay(Capsule().strokeBorder(SOTheme.hairline, lineWidth: 1))
                .accessibilityLabel("Six digit code")
                .onChange(of: code) { _, latest in
                    // Submitting the moment it is complete saves a tap, and
                    // autofill delivers all six digits at once anyway.
                    if EmailSignIn.isCompleteCode(latest) {
                        Task { await verifyCode() }
                    }
                }

            HStack(spacing: 14) {
                Button("Use a different address") {
                    sentTo = nil
                    code = ""
                    error = nil
                    notice = nil
                }
                .font(.footnote.weight(.semibold))
                .tint(SOTheme.textSecondary)
                .frame(minHeight: 44)

                Spacer()

                // Supabase rate-limits sends PER ADDRESS. Three impatient
                // taps burn the quota and lock the driver out of their own
                // account for the better part of an hour, so this stays
                // disabled longer than the mail usually takes.
                if EmailSignIn.resendAvailable(secondsSinceSend: secondsSinceSend) {
                    Button("Resend") { Task { await sendCode(resending: true) } }
                        .font(.footnote.weight(.semibold))
                        .tint(SOTheme.heatStart)
                        .frame(minHeight: 44)
                        .disabled(working)
                } else {
                    Text("Resend in 0:\(String(format: "%02d", EmailSignIn.resendCountdown(secondsSinceSend: secondsSinceSend)))")
                        .font(.footnote)
                        .foregroundStyle(SOTheme.textSecondary)
                        .frame(minHeight: 44)
                        .monospacedDigit()
                }
            }
        }
        .onReceive(tick) { _ in
            if sentTo != nil { secondsSinceSend += 1 }
        }
    }

    @MainActor
    private func sendCode(resending: Bool = false) async {
        guard let normalized = EmailSignIn.normalize(email) else {
            error = "That doesn't look like an email address."
            return
        }
        working = true
        defer { working = false }
        error = nil
        do {
            // Hand back the NORMALISED address and verify against that, not
            // against what was typed — " Me@Example.com " and
            // "me@example.com" are two different accounts to GoTrue, and the
            // mismatch surfaces as an invalid code rather than as a
            // mismatch, which sends you looking at the wrong thing.
            sentTo = try await environment.sendEmailCode(to: normalized)
            secondsSinceSend = 0
            code = ""
            codeFocused = true
            notice = resending ? "Sent again." : nil
        } catch SupabaseAPI.APIError.invalidEmail {
            error = "That doesn't look like an email address."
        } catch SupabaseAPI.APIError.http(let status, _) where status == 429 {
            error = "Too many requests. Wait a minute and try again."
        } catch {
            self.error = "Couldn't send the code. Check your connection and try again."
        }
    }

    @MainActor
    private func verifyCode() async {
        guard let sentTo, EmailSignIn.isCompleteCode(code), !working else { return }
        working = true
        defer { working = false }
        error = nil
        do {
            try await environment.verifyEmailCode(email: sentTo, code: code)
            dismiss()
        } catch SupabaseAPI.APIError.http(let status, _) where status == 403 || status == 401 {
            // GoTrue reports expiry and a wrong code identically, so the
            // message has to cover both without guessing which happened.
            error = "That code didn't work. It may have expired — try Resend."
            code = ""
        } catch {
            self.error = "Couldn't verify the code. Check your connection and try again."
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
