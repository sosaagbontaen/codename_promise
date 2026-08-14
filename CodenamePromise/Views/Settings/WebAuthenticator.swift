import AuthenticationServices
import Foundation
import UIKit

/// Wraps `ASWebAuthenticationSession` for the Notion sign-in.
///
/// The system session is what makes this safe: the page runs outside the app, so the user is
/// typing their Notion password into Notion's own site in a browser they can inspect — this
/// app never sees a password field, and never receives the resulting token. It only learns
/// that the flow finished, then asks the backend what the truth is.
@MainActor
final class WebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Outcome {
        case completed
        case cancelled
        case failed(String)
    }

    /// Held for the lifetime of the session — releasing it dismisses the sheet.
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async -> Outcome {
        await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { _, error in
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    continuation.resume(returning: .cancelled)
                } else if let error {
                    continuation.resume(returning: .failed(error.localizedDescription))
                } else {
                    // The callback URL carries no secret — the token stayed on the server —
                    // so there is nothing to parse out of it.
                    continuation.resume(returning: .completed)
                }
            }
            session.presentationContextProvider = self
            // A fresh session each time, so signing in as a different Notion user works
            // without the browser silently reusing the previous account.
            session.prefersEphemeralWebBrowserSession = true

            self.session = session
            if !session.start() {
                continuation.resume(returning: .failed("Couldn't open the sign-in page."))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}
