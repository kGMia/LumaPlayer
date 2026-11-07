// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main enum NetworkServerSmoke {
    @MainActor static func main() throws {
        let suite = "iive.network-smoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let vault = NetworkServerKeychain(service: suite, allowInteraction: false)
        let store = NetworkServerStore(defaults: defaults, keychain: vault)
        let id = UUID()
        defer { try? vault.delete(id); defaults.removePersistentDomain(forName: suite) }
        let first = NetworkServerCredentials(address: "https://example.invalid/dav/?token=dummy-only", username: "test", password: "dummy-password-only")
        do { _ = try store.save(id: id, name: "Test Server", credentials: first) }
        catch {
            print("Keychain check unavailable without interaction: \(error.localizedDescription)")
            throw error
        }
        precondition(tryRead(vault, id) == first)
        let reopened = NetworkServerStore(defaults: defaults, keychain: vault)
        precondition(reopened.servers.count == 1 && reopened.lastSelected == id)
        let saved = String(data: defaults.data(forKey: "networkServers.v1")!, encoding: .utf8)!
        precondition(!saved.contains("dummy-password") && !saved.contains("token=") && !saved.contains("username"))
        let updated = NetworkServerCredentials(address: first.address, username: "updated-user", password: "updated-dummy")
        _ = try reopened.save(id: id, name: "Updated Server", credentials: updated)
        precondition(reopened.servers.count == 1 && tryRead(vault, id) == updated)
        try reopened.remove(id)
        precondition(reopened.servers.isEmpty && reopened.lastSelected == nil)
        do { _ = try vault.read(id); fatalError("Deleted credential still present") } catch {}
        print("PASS: real Keychain write/read/update/delete, saved-server reload, and no credentials/URL query in preferences")
    }
    static func tryRead(_ vault: NetworkServerKeychain, _ id: UUID) -> NetworkServerCredentials {
        try! vault.read(id)
    }
}
