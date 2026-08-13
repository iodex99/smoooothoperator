import AuthenticationServices
import SwiftUI

/// Thin async wrapper around ASWebAuthenticationSession.
///
/// This is the entire OAuth integration: the system browser handles the
/// provider, shares no cookies with the app, and hands back only the
/// callback URL. No provider SDK ships in the binary.
enum WebAuthenticator {
    enum Failure: Error {
        case cancelled
        case failed
    }

    @MainActor
    static func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: Failure.cancelled)
                } else {
                    continuation.resume(throwing: Failure.failed)
                }
            }
            session.presentationContextProvider = ContextProvider.shared
            // Deliberately NON-ephemeral: reusing the system browser session
            // means a user already signed in to Google taps once instead of
            // retyping a password. (An ephemeral session would be the choice
            // if we wanted to force an account picker every time.)
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: Failure.failed)
            }
        }
    }

    /// ASWebAuthenticationSession needs a window to present over.
    private final class ContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        static let shared = ContextProvider()

        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}
