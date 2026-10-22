import CryptoKit
import Foundation
import Observation
import Supabase

/// The optional backend (Supabase). A build without a host and anon key (`Secrets.xcconfig`, kept out of git) has no
/// account features at all, and OneShot works as before: everything on the device.
enum Cloud {
    /// The anon key is public by design (Row Level Security guards the data); the service key never ships.
    static let client: SupabaseClient? = {
        let info = Bundle.main.infoDictionary
        guard let host = info?["SupabaseHost"] as? String, !host.isEmpty,
              let key = info?["SupabaseAnonKey"] as? String, !key.isEmpty,
              let url = URL(string: "https://\(host)") else { return nil }
        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }()

    static var isConfigured: Bool { client != nil }
}

/// Who is signed in, if anyone. Signing in is optional: it adds backup and sync across the owner's devices.
@MainActor
@Observable
final class Account {
    static let shared = Account()

    private(set) var email: String?
    var isSignedIn: Bool { email != nil }

    private init() {
        guard let client = Cloud.client else { return }
        Task { [weak self] in
            for await (_, session) in client.auth.authStateChanges {
                self?.email = session.flatMap { $0.isExpired ? nil : $0.user.email }
            }
        }
    }

    /// Emails a 6-digit code; a new address gets an account.
    func sendCode(to email: String) async throws {
        try await require().auth.signInWithOTP(email: email, shouldCreateUser: true)
    }

    /// Where Google sends the user back; must be in the project's Auth › URL Configuration › Redirect URLs.
    static let redirect = URL(string: "oneshot://login-callback")!

    /// Google, in the system's sign-in sheet (Supabase OAuth; no Google SDK). Offering it means Sign in with Apple must
    /// be offered too before App Store review (guideline 4.8).
    func signInWithGoogle() async throws {
        try await require().auth.signInWithOAuth(provider: .google, redirectTo: Self.redirect) { session in
            session.prefersEphemeralWebBrowserSession = true   // no shared Safari cookies: always the account picker
        }
    }

    /// Sign in with Apple: the identity token from the system sheet, checked by Supabase against the nonce whose
    /// SHA-256 went into the request (so a captured token can't be replayed). Guideline 4.8, since Google is offered.
    func signInWithApple(idToken: String, nonce: String) async throws {
        try await require().auth.signInWithIdToken(credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
    }

    /// Accounts given a password in the Supabase dashboard (App Review's demo account) can sign in without a code.
    func signIn(email: String, password: String) async throws {
        try await require().auth.signIn(email: email, password: password)
    }

    func verify(email: String, code: String) async throws {
        try await require().auth.verifyOTP(email: email, token: code, type: .email)
    }

    /// Signs out; the shop stays on this device.
    func signOut() async throws {
        SyncEngine.shared.reset()   // first: signing out offline must still stop syncing this account
        email = nil
        try await require().auth.signOut()
    }

    /// Deletes the account and everything stored for it on the server (Edge Function `delete-account`, which holds the
    /// service key). App Store 5.1.1(v). The device's own copy is a separate choice (`Store.eraseEverything`).
    func deleteAccount() async throws {
        let client = try require()
        try await client.functions.invoke("delete-account")
        try? await client.auth.signOut()   // the user is gone; clear the local session either way
        email = nil
        SyncEngine.shared.reset()
    }

    private func require() throws -> SupabaseClient {
        guard let client = Cloud.client else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: String(localized: "Accounts aren't available in this build.")])
        }
        return client
    }
}

/// A fresh random nonce for Sign in with Apple, and its SHA-256 for the request.
enum AppleNonce {
    static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return UUID().uuidString + UUID().uuidString }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
