import GoogleSignIn
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum GoogleAuthService {
    @MainActor
    static func identityToken(nonce: String) async throws -> String {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !clientID.hasPrefix("REPLACE_ME") else {
            throw AppError.configuration
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

#if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else {
            throw AppError.missingPresentationAnchor
        }
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: root,
            hint: nil,
            additionalScopes: nil,
            nonce: nonce
        )
#elseif os(macOS)
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first else {
            throw AppError.missingPresentationAnchor
        }
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: window,
            hint: nil,
            additionalScopes: nil,
            nonce: nonce
        )
#endif
        guard let token = result.user.idToken?.tokenString else { throw AppError.missingIDToken }
        return token
    }

    static func handle(_ url: URL) {
        GIDSignIn.sharedInstance.handle(url)
    }

    static func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }
}
