// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation
import Security
import LocalAuthentication

struct SavedNetworkServer: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var host: String
}
struct NetworkServerCredentials: Codable, Equatable, Sendable {
    var address: String
    var username: String
    var password: String
}

/// URLs may include private query parameters, so keep the complete connection
/// record in Keychain. UserDefaults contains only ID, display name and hostname.
struct NetworkServerKeychain {
    var service = "io.iive.player.network-servers.v1"
    var allowInteraction = true
    private func query(_ id: UUID) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        if !allowInteraction {
            let context = LAContext(); context.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = context
        }
        return q
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            // Never fall back to storing a password in preferences.
            throw NetworkMediaError.invalid("Keychain could not be accessed (\(status)). Unlock your login keychain or allow \(PlayerIdentity.displayName) access, then try again.")
        }
    }
    func read(_ id: UUID) throws -> NetworkServerCredentials {
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { throw NetworkMediaError.invalid("Saved connection was not found in Keychain. Re-enter its address and credentials, then save again.") }
        try check(status)
        guard let data = result as? Data, let value = try? JSONDecoder().decode(NetworkServerCredentials.self, from: data) else {
            throw NetworkMediaError.invalid("Saved connection data is invalid. Re-enter and save this connection.")
        }
        return value
    }
    func write(_ value: NetworkServerCredentials, id: UUID) throws {
        let data = try JSONEncoder().encode(value)
        let q = query(id)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "\(PlayerIdentity.displayName) · Network Server"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        try check(status)
    }
    func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}

@MainActor @Observable final class NetworkServerStore {
    static let shared = NetworkServerStore()
    private(set) var servers: [SavedNetworkServer]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: NetworkServerKeychain
    @ObservationIgnored private let key = "networkServers.v1"
    var lastSelected: UUID? { defaults.string(forKey: "networkServers.last").flatMap(UUID.init(uuidString:)) }
    init(defaults: UserDefaults = .standard, keychain: NetworkServerKeychain = NetworkServerKeychain()) {
        self.defaults = defaults; self.keychain = keychain
        servers = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([SavedNetworkServer].self, from: $0) } ?? []
    }
    func credentials(for id: UUID) throws -> NetworkServerCredentials { try keychain.read(id) }
    func select(_ id: UUID) { defaults.set(id.uuidString, forKey: "networkServers.last") }
    @discardableResult
    func save(id: UUID?, name: String, credentials: NetworkServerCredentials) throws -> UUID {
        let url = try NetworkMediaRequest.parse(credentials.address, webDAV: true)
        _ = try NetworkMediaRequest.authorization(username: credentials.username, password: credentials.password)
        let id = id ?? UUID()
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = SavedNetworkServer(id: id, name: title.isEmpty ? (url.host ?? "WebDAV") : String(title.prefix(100)), host: url.host ?? "")
        let value = NetworkServerCredentials(address: url.absoluteString, username: credentials.username, password: credentials.password)
        try keychain.write(value, id: id)
        var updated = servers
        if let index = updated.firstIndex(where: { $0.id == id }) { updated[index] = server } else { updated.append(server) }
        defaults.set(try JSONEncoder().encode(updated), forKey: key)
        servers = updated; select(id)
        return id
    }
    func remove(_ id: UUID) throws {
        try keychain.delete(id)
        let updated = servers.filter { $0.id != id }
        defaults.set(try JSONEncoder().encode(updated), forKey: key)
        servers = updated
        if lastSelected == id { defaults.removeObject(forKey: "networkServers.last") }
    }
}
