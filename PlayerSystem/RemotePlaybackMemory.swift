// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

/// No URLs, account names, tokens or header values are persisted as readable text.
enum RemotePlaybackIdentity {
    static func digest(_ fields: [String]) -> String {
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func webDAV(url: URL, server: URL, username: String) -> String? {
        // Query-based identities can represent either expiring tokens or different
        // files/accounts. Do not guess by stripping them and merging histories.
        guard url.query == nil, url.fragment == nil, server.query == nil, server.fragment == nil,
              let p = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = p.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = p.host?.lowercased(), p.user == nil, p.password == nil else { return nil }
        return digest(["webdav-v1", scheme, host, String(p.port ?? (scheme == "https" ? 443 : 80)),
                       username, p.percentEncodedPath])
    }
    static func oneDrive(account: String, drive: String, item: String) -> String? {
        guard !account.isEmpty, !drive.isEmpty, !item.isEmpty else { return nil }
        return digest(["onedrive-v1", account, drive, item])
    }
}

@MainActor final class RemotePlaybackMemory {
    private struct Record: Codable {
        let revision: String
        let position: Double
        let duration: Double
        let updated: Date
    }
    private let defaults: UserDefaults
    private let storageKey = "remotePlaybackMemory.v1"
    private var records: [String: Record]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode([String: Record].self, from: $0)
        } ?? [:]
    }
    func position(for identity: String, revision: String) -> Double? {
        guard let saved = records[identity] else { return nil }
        guard saved.revision == revision else { records[identity] = nil; persist(); return nil }
        guard saved.position.isFinite, saved.duration.isFinite,
              saved.position > 5, saved.position < saved.duration - 10 else { return nil }
        return saved.position
    }
    func save(identity: String, revision: String, position: Double, duration: Double) {
        guard identity.count == 64, revision.count == 64,
              identity.allSatisfy({ $0.isHexDigit }), revision.allSatisfy({ $0.isHexDigit }),
              position.isFinite, duration.isFinite, position >= 0, duration > 0 else { return }
        records[identity] = Record(revision: revision, position: position < duration - 10 ? position : 0,
                                   duration: duration, updated: Date())
        if records.count > 100 {
            records = Dictionary(uniqueKeysWithValues: records.sorted { $0.value.updated > $1.value.updated }
                .prefix(100).map { ($0.key, $0.value) })
        }
        persist()
    }
    func clear() { records.removeAll(); defaults.removeObject(forKey: storageKey) }
    func resetPosition(for identity: String) {
        guard let old = records[identity] else { return }
        records[identity] = Record(revision: old.revision, position: 0, duration: old.duration, updated: Date())
        persist()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: storageKey) }
    }
}
