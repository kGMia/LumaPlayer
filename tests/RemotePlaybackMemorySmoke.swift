// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main enum RemotePlaybackMemorySmoke {
    @MainActor static func main() throws {
        let base = URL(string: "https://example.test/dav/")!
        let file = base.appendingPathComponent("private movie.mp4")
        let identity = RemotePlaybackIdentity.webDAV(url: file, server: base, username: "private-user")!
        precondition(identity == RemotePlaybackIdentity.webDAV(url: URL(string: "https://EXAMPLE.test:443/dav/private%20movie.mp4")!, server: base, username: "private-user"))
        precondition(identity != RemotePlaybackIdentity.webDAV(url: file, server: base, username: "another-user"))
        precondition(RemotePlaybackIdentity.webDAV(url: URL(string: file.absoluteString + "?token=secret")!, server: base, username: "private-user") == nil)
        precondition(RemotePlaybackIdentity.webDAV(url: file, server: URL(string: base.absoluteString + "?account=secret")!, username: "") == nil)
        precondition(RemotePlaybackIdentity.oneDrive(account: "a", drive: "d", item: "i") != RemotePlaybackIdentity.oneDrive(account: "b", drive: "d", item: "i"))
        func response(_ code: Int, _ fields: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: file, statusCode: code, httpVersion: "HTTP/1.1", headerFields: fields)!
        }
        let version = RemoteContentVersion.read(response(206, ["Content-Range":"bytes 0-0/1000", "Content-Length":"1", "ETag":"private-version"]))!
        precondition(version.size == 1000)
        precondition(RemoteContentVersion.read(response(206, ["Content-Length":"1", "ETag":"v"])) == nil)
        precondition(RemoteContentVersion.read(response(200, ["Content-Length":"1000"])) == nil)
        precondition(RemoteContentVersion.read(response(200, ["Content-Length":"1000", "Last-Modified":"Wed, 21 Oct 2026 00:00:00 GMT"])) != nil)
        let suite = "iive-remote-memory-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RemotePlaybackMemory(defaults: defaults)
        store.save(identity: identity, revision: version.digest, position: 42, duration: 100)
        let disk = RemotePlaybackMemory(defaults: defaults)
        precondition(disk.position(for: identity, revision: version.digest) == 42)
        disk.resetPosition(for: identity)
        precondition(RemotePlaybackMemory(defaults: defaults).position(for: identity, revision: version.digest) == nil)
        disk.save(identity: identity, revision: version.digest, position: 42, duration: 100)
        let bytes = defaults.data(forKey: "remotePlaybackMemory.v1")!
        let text = String(decoding: bytes, as: UTF8.self)
        for privateValue in ["https", "example.test", "private-user", "private movie", "private-version", "secret"] { precondition(!text.contains(privateValue)) }
        let changed = RemoteContentVersion(size: 1001, validator: "private-version").digest
        precondition(disk.position(for: identity, revision: changed) == nil)
        precondition(RemotePlaybackMemory(defaults: defaults).position(for: identity, revision: version.digest) == nil)
        store.save(identity: identity, revision: version.digest, position: 95, duration: 100)
        precondition(store.position(for: identity, revision: version.digest) == nil)
        store.save(identity: identity, revision: version.digest, position: .nan, duration: 100)
        precondition(store.position(for: identity, revision: version.digest) == nil)
        for i in 0..<101 {
            store.save(identity: RemotePlaybackIdentity.digest(["file", String(i)]), revision: version.digest, position: 20, duration: 100)
        }
        let saved = try JSONSerialization.jsonObject(with: defaults.data(forKey: "remotePlaybackMemory.v1")!) as! [String: Any]
        precondition(saved.count == 100)
        store.clear()
        precondition(defaults.data(forKey: "remotePlaybackMemory.v1") == nil)
        print("PASS: stable/account-scoped identities, private query exclusion, fresh version headers, persistence, invalidation, completed media, bounds and clear")
    }
}
