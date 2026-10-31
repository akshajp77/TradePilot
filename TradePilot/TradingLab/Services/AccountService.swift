import Foundation
import SwiftUI
import AuthenticationServices
import CryptoKit
import Security
#if canImport(UIKit)
import UIKit
#endif
import Combine

nonisolated enum AccountError: Error, Equatable {
    case signedOut
    case network
    case server(status: Int, code: String, message: String)

    var message: String {
        switch self {
        case .signedOut: return "Sign in to sync."
        case .network: return "No connection to the Trading Lab server."
        case .server(_, _, let message): return message
        }
    }
}

nonisolated struct RemoteSession: Identifiable, Decodable, Sendable {
    let id: String
    let deviceName: String
    let createdAt: String
    let lastUsedAt: String
    let current: Bool
}

/// Sign in with Apple → server session. The refresh token lives in the Keychain (this device only);
/// the 15-minute access token lives in memory. Refreshes are single-flight.
@MainActor
final class AccountService: ObservableObject {
    @Published private(set) var signedIn: Bool
    @Published private(set) var alias: String?
    @Published private(set) var isPublic = false
    @Published private(set) var busy = false

    private var accessToken: String?
    private var accessExpiresAt = Date.distantPast
    private var refreshTask: Task<Bool, Never>?
    private var rawNonce: String?

    private struct TokenResponse: Decodable {
        struct User: Decodable { let id: String; let alias: String?; let isPublic: Bool }
        let accessToken: String
        let accessExpiresAt: String
        let refreshToken: String
        let sessionId: String
        let user: User?
    }
    private struct ErrorBody: Decodable { let code: String?; let error: String? }

    init() {
        signedIn = Keychain.read(.refreshToken) != nil
    }

    /// Signs out locally if the Apple ID was disconnected from this app in Settings.
    func verifyAppleCredential() async {
        guard signedIn, let userID = Keychain.read(.appleUserID) else { return }
        let state: ASAuthorizationAppleIDProvider.CredentialState = await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in continuation.resume(returning: state) }
        }
        if state == .revoked || state == .notFound { clearLocal() }
    }

    // MARK: Sign in with Apple

    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let nonce = Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "")
        rawNonce = nonce
        request.requestedScopes = []
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns nil on success, or a message to show.
    func complete(_ result: Result<ASAuthorization, Error>) async -> String? {
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return nil }
            return "Sign in with Apple failed: \(error.localizedDescription)"
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken, let identityToken = String(data: tokenData, encoding: .utf8),
                  let nonce = rawNonce else { return "Apple did not return a sign-in token." }
            let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            busy = true
            defer { busy = false; rawNonce = nil }
            var fields: [String: String] = ["identityToken": identityToken, "nonce": nonce, "deviceName": Self.deviceName]
            if let code { fields["authorizationCode"] = code }
            do {
                let (data, status) = try await raw("POST", "auth/apple", body: Self.json(fields), token: nil)
                guard status == 200 || status == 201 else { return Self.errorMessage(data, status: status) }
                let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
                store(tokens)
                Keychain.save(credential.user, for: .appleUserID)
                alias = tokens.user?.alias
                isPublic = tokens.user?.isPublic ?? false
                signedIn = true
                return nil
            } catch {
                return AccountError.network.message
            }
        }
    }

    // MARK: Sign in with Google

    /// Google sign-in: OAuth authorization code with PKCE in a secure browser sheet. The app gets a Google ID token
    /// and the server verifies it. Returns nil on success or cancel, or a message to show.
    func signInWithGoogle(session: WebAuthenticationSession) async -> String? {
        let clientID = AppConfig.googleClientID
        guard clientID.hasSuffix(".apps.googleusercontent.com"), !clientID.hasPrefix("YOUR_") else {
            return "Google sign-in isn't set up in this build yet."
        }
        let verifier = Self.randomURLSafe(32)
        let nonce = Self.randomURLSafe(32)
        let state = Self.randomURLSafe(16)
        let redirect = AppConfig.googleRedirectURI
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid"),
            URLQueryItem(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "nonce", value: Self.sha256Hex(nonce)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        guard let url = components.url else { return "Google sign-in could not start." }

        busy = true
        defer { busy = false }
        let callback: URL
        do {
            callback = try await session.authenticate(using: url, callbackURLScheme: AppConfig.googleCallbackScheme, preferredBrowserSession: .ephemeral)
        } catch {
            return nil // The user closed the sheet.
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            return error == "access_denied" ? nil : "Google sign-in was not completed (\(error))."
        }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            return "Google sign-in could not be verified. Please try again."
        }
        do {
            guard let idToken = try await Self.exchangeGoogleCode(code, verifier: verifier, redirect: redirect, clientID: clientID) else {
                return "Google did not return a sign-in token."
            }
            let (data, status) = try await raw("POST", "auth/google", body: Self.json(["idToken": idToken, "nonce": nonce, "deviceName": Self.deviceName]), token: nil)
            guard status == 200 || status == 201 else { return Self.errorMessage(data, status: status) }
            let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
            store(tokens)
            alias = tokens.user?.alias
            isPublic = tokens.user?.isPublic ?? false
            signedIn = true
            return nil
        } catch {
            return AccountError.network.message
        }
    }

    // MARK: Sign in with email

    /// Asks the server to email a 6-digit code. Returns nil when sent, or a message to show.
    func requestEmailCode(_ email: String) async -> String? {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@"), address.contains(".") else { return "Enter a valid email address." }
        busy = true
        defer { busy = false }
        do {
            let (data, status) = try await raw("POST", "auth/email/start", body: Self.json(["email": address]), token: nil)
            return status == 200 ? nil : Self.errorMessage(data, status: status)
        } catch {
            return AccountError.network.message
        }
    }

    /// Checks the emailed code and signs in. Returns nil on success, or a message to show.
    func verifyEmailCode(_ email: String, code: String) async -> String? {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return "Enter the 6-digit code from the email." }
        busy = true
        defer { busy = false }
        do {
            let body = Self.json(["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "code": digits, "deviceName": Self.deviceName])
            let (data, status) = try await raw("POST", "auth/email/verify", body: body, token: nil)
            guard status == 200 || status == 201 else { return Self.errorMessage(data, status: status) }
            let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
            store(tokens)
            alias = tokens.user?.alias
            isPublic = tokens.user?.isPublic ?? false
            signedIn = true
            return nil
        } catch {
            return AccountError.network.message
        }
    }

    private nonisolated static func exchangeGoogleCode(_ code: String, verifier: String, redirect: String, clientID: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Exchange: Decodable {
            let idToken: String?
            enum CodingKeys: String, CodingKey { case idToken = "id_token" }
        }
        return try JSONDecoder().decode(Exchange.self, from: data).idToken
    }

    private nonisolated static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private nonisolated static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Authorized requests

    /// Sends an authorized request, refreshing the access token first if needed and retrying once on 401.
    func send(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> (Data, Int) {
        guard signedIn else { throw AccountError.signedOut }
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        for attempt in 0..<2 {
            if accessToken == nil || accessExpiresAt.timeIntervalSinceNow < 30 {
                guard await refresh() else { throw AccountError.signedOut }
            }
            let (data, status) = try await raw(method, path, body: body, token: accessToken)
            if status == 401 && attempt == 0 { accessToken = nil; continue }
            return (data, status)
        }
        throw AccountError.signedOut
    }

    private func refresh() async -> Bool {
        if let refreshTask { return await refreshTask.value }
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            for attempt in 0..<2 {
                guard let token = Keychain.read(.refreshToken) else { self.clearLocal(); return false }
                guard let (data, status) = try? await self.raw("POST", "auth/refresh", body: Self.json(["refreshToken": token]), token: nil) else {
                    return false // offline: keep the session, try again later
                }
                if status == 200, let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data) {
                    self.store(tokens)
                    return true
                }
                let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.code
                if code == "stale" && attempt == 0 { try? await Task.sleep(for: .milliseconds(300)); continue }
                if status == 401 { self.clearLocal() }
                return false
            }
            return false
        }
        refreshTask = task
        let ok = await task.value
        refreshTask = nil
        return ok
    }

    private func store(_ tokens: TokenResponse) {
        Keychain.save(tokens.refreshToken, for: .refreshToken)
        accessToken = tokens.accessToken
        accessExpiresAt = Parse.iso8601(tokens.accessExpiresAt) ?? Date().addingTimeInterval(600)
    }

    private nonisolated static func json(_ fields: [String: String]) -> Data? {
        try? JSONSerialization.data(withJSONObject: fields)
    }

    private nonisolated func raw(_ method: String, _ path: String, body: Data?, token: String?) async throws -> (Data, Int) {
        var request = URLRequest(url: AppConfig.api(path), timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch { throw AccountError.network }
    }

    nonisolated static func errorMessage(_ data: Data, status: Int) -> String {
        (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "The server returned an error (\(status))."
    }

    private func clearLocal() {
        Keychain.delete(.refreshToken)
        Keychain.delete(.appleUserID)
        accessToken = nil
        accessExpiresAt = .distantPast
        signedIn = false
        alias = nil
        isPublic = false
    }

    // MARK: Account operations

    func loadProfile() async {
        guard let (data, status) = try? await send("GET", "me"), status == 200,
              let me = try? JSONDecoder().decode(TokenResponse.User.self, from: data) else { return }
        alias = me.alias
        isPublic = me.isPublic
    }

    /// Returns nil on success, or a message.
    func updateProfile(alias newAlias: String?, isPublic newPublic: Bool) async -> String? {
        do {
            let (data, status) = try await send("PATCH", "profile", json: ["alias": newAlias.map { $0 as Any } ?? NSNull(), "isPublic": newPublic])
            guard status == 200 else { return Self.errorMessage(data, status: status) }
            alias = newAlias?.isEmpty == false ? newAlias : nil
            isPublic = newPublic
            return nil
        } catch { return (error as? AccountError)?.message ?? AccountError.network.message }
    }

    func sessions() async -> [RemoteSession]? {
        struct Envelope: Decodable { let sessions: [RemoteSession] }
        guard let (data, status) = try? await send("GET", "sessions"), status == 200 else { return nil }
        return try? JSONDecoder().decode(Envelope.self, from: data).sessions
    }

    func revoke(session id: String) async -> Bool {
        guard let (_, status) = try? await send("DELETE", "sessions/\(id)") else { return false }
        return status == 204
    }

    func signOut() async {
        _ = try? await send("POST", "auth/logout")
        clearLocal()
    }

    /// Deletes the server account, its synced copy and public record, and revokes the Apple token.
    /// Local practice data stays on this device.
    func deleteAccount() async -> String? {
        do {
            let (data, status) = try await send("DELETE", "account")
            guard status == 200 || status == 204 else { return Self.errorMessage(data, status: status) }
            clearLocal()
            return nil
        } catch { return (error as? AccountError)?.message ?? AccountError.network.message }
    }

    static var deviceName: String {
        #if os(iOS)
        return UIDevice.current.model
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }
}

/// "Continue with Google" for onboarding and Settings. Failures are passed to `onMessage`.
struct GoogleSignInButton: View {
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.theme) private var theme
    @ObservedObject var account: AccountService
    let onMessage: (String) -> Void

    var body: some View {
        Button {
            Task {
                if let message = await account.signInWithGoogle(session: webAuthenticationSession) { onMessage(message) }
            }
        } label: {
            HStack(spacing: Space.s8) {
                Image(systemName: "g.circle.fill")
                Text("Continue with Google")
            }
            .font(theme.label)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(account.busy)
    }
}

/// "Continue with email": type an address, get a 6-digit code, type it back. Failures are passed to `onMessage`.
struct EmailSignInView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var account: AccountService
    let onMessage: (String) -> Void
    @State private var expanded = false
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false

    var body: some View {
        if !expanded {
            Button {
                expanded = true
            } label: {
                HStack(spacing: Space.s8) {
                    Image(systemName: "envelope.fill")
                    Text("Continue with email")
                }
                .font(theme.label)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(account.busy)
        } else {
            VStack(alignment: .leading, spacing: Space.s8) {
                TextField("you@example.com", text: $email)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .emailKeyboard()
                    .disabled(codeSent)
                    .textFieldStyle(.roundedBorder)
                if codeSent {
                    TextField("6-digit code", text: $code)
                        .textContentType(.oneTimeCode)
                        .appNumberKeyboard(.whole)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: code) { _, value in code = String(value.filter(\.isNumber).prefix(6)) }
                    Button {
                        Task { if let message = await account.verifyEmailCode(email, code: code) { onMessage(message) } }
                    } label: {
                        Text("Sign in").font(theme.label).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.busy || code.count != 6)
                    HStack {
                        Button("Use a different email") { codeSent = false; code = "" }
                        Spacer()
                        Button("Send a new code") { Task { await send() } }.disabled(account.busy)
                    }
                    .font(theme.meta)
                    Text("We sent a code to \(email). It expires in 10 minutes.")
                        .font(theme.meta).foregroundStyle(theme.muted)
                } else {
                    Button {
                        Task { await send() }
                    } label: {
                        Text("Email me a code").font(theme.label).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.busy || email.isEmpty)
                }
            }
        }
    }

    private func send() async {
        if let message = await account.requestEmailCode(email) { onMessage(message) } else { codeSent = true; code = "" }
    }
}

private extension View {
    @ViewBuilder func emailKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.emailAddress).textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}
