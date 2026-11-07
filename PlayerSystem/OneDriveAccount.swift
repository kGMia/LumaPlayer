// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Observation
import MSAL

/// Authentication is owned by MSAL (system web session, PKCE, Keychain and
/// refresh). The player stores only public configuration and an account ID.
@MainActor @Observable final class OneDriveAccount {
    static let shared = OneDriveAccount()
    static let scopes = ["https://graph.microsoft.com/Files.Read"]
    static let redirectURI = PlayerIdentity.redirectURI
    private(set) var clientID = UserDefaults.standard.string(forKey: "oneDrive.clientID") ?? ""
    private(set) var accountID = UserDefaults.standard.string(forKey: "oneDrive.accountID") ?? ""
    private(set) var name = "OneDrive"
    private(set) var busy = false
    @ObservationIgnored private var application: MSALPublicClientApplication?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var refresh: Task<String, Error>?
    var identity: String { clientID + ":" + accountID }
    var connected: Bool { !clientID.isEmpty && !accountID.isEmpty }

    private func app() throws -> MSALPublicClientApplication {
        if let application { return application }
        guard UUID(uuidString: clientID) != nil else { throw NetworkMediaError.invalid("Enter the Application (client) ID from your Microsoft app registration first.") }
        let authority = try MSALAADAuthority(url: URL(string: "https://login.microsoftonline.com/common")!)
        let config = MSALPublicClientApplicationConfig(clientId: clientID, redirectUri: Self.redirectURI, authority: authority)
        // Use only this application's entitled group, without Microsoft's
        // cross-application SSO group. Tokens never go into plain preferences.
        config.cacheConfig.keychainSharingGroup = Bundle.main.bundleIdentifier ?? PlayerIdentity.bundleIdentifier
        let value = try MSALPublicClientApplication(configuration: config)
        application = value
        return value
    }
    func configure(_ text: String) async throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard UUID(uuidString: value) != nil else { throw NetworkMediaError.invalid("The client ID must be a UUID, not a secret or tenant ID.") }
        guard !busy else { return }
        if value != clientID {
            try await disconnect()
            application = nil; clientID = value
            UserDefaults.standard.set(value, forKey: "oneDrive.clientID")
        }
        _ = try app()
    }
    func signIn() async throws {
        guard !busy else { return }
        guard let controller = NSApp.keyWindow?.contentViewController ?? NSApp.mainWindow?.contentViewController else {
            throw NetworkMediaError.invalid("Open the player or settings window before signing in.")
        }
        busy = true; defer { busy = false }
        let app = try app(), ticket = epoch
        let web = MSALWebviewParameters(authPresentationViewController: controller)
        web.webviewType = .authenticationSession
        let parameters = MSALInteractiveTokenParameters(scopes: Self.scopes, webviewParameters: web)
        parameters.promptType = .selectAccount
        let result: MSALResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                app.acquireToken(with: parameters) { result, error in
                    if let result { continuation.resume(returning: result) }
                    else { continuation.resume(throwing: Self.safeError(error)) }
                }
            }
        } onCancel: { _ = MSALPublicClientApplication.cancelCurrentWebAuthSession() }
        try Task.checkCancellation()
        guard epoch == ticket else { throw CancellationError() }
        accountID = result.account.identifier ?? ""
        guard !accountID.isEmpty else { throw NetworkMediaError.invalid("Microsoft did not return an account identifier.") }
        name = result.account.username ?? "OneDrive"
        RemoteBrowserMemory.clearOneDrive()
        UserDefaults.standard.set(accountID, forKey: "oneDrive.accountID")
    }
    func disconnect() async throws {
        guard !busy else { return }
        busy = true; epoch = UUID()
        defer { busy = false }
        // Let a pending SDK refresh settle before removing its cache entry.
        if let refresh { _ = try? await refresh.value; self.refresh = nil }
        if !accountID.isEmpty {
            let app = try app()
            if let account = try app.allAccounts().first(where: { $0.identifier == accountID }) { try app.remove(account) }
        }
        RemoteBrowserMemory.clearOneDrive()
        accountID = ""; name = "OneDrive"
        UserDefaults.standard.removeObject(forKey: "oneDrive.accountID")
    }
    func token(for expected: String, force: Bool = false) async throws -> String {
        guard connected, expected == identity, !busy else { throw NetworkMediaError.invalid("Sign in to the OneDrive account used by this queue in Network settings.") }
        let ticket = epoch
        if let refresh {
            let token = try await refresh.value
            guard ticket == epoch, expected == identity else { throw CancellationError() }
            if !force { return token }
        }
        let app = try app()
        guard let account = try? app.account(forIdentifier: accountID) else { throw NetworkMediaError.invalid("The OneDrive login has expired. Sign in again in Network settings.") }
        let parameters = MSALSilentTokenParameters(scopes: Self.scopes, account: account)
        parameters.forceRefresh = force
        let work = Task<String, Error> {
            try await withCheckedThrowingContinuation { continuation in
                app.acquireTokenSilent(with: parameters) { result, error in
                    if let result { continuation.resume(returning: result.accessToken) }
                    else { continuation.resume(throwing: Self.safeError(error)) }
                }
            }
        }
        refresh = work
        defer { refresh = nil }
        let token = try await work.value
        try Task.checkCancellation()
        guard ticket == epoch, expected == identity else { throw CancellationError() }
        return token
    }
    nonisolated private static func safeError(_ error: Error?) -> Error {
        // SDK descriptions may carry account details or callback URLs.
        let code = (error as NSError?)?.code ?? 0
        return NetworkMediaError.invalid("Microsoft sign-in could not finish (code \(code)). Check the client ID, registered redirect URI and account permissions, then sign in again.")
    }
}
