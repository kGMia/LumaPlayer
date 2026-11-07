// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main enum PlayerIdentitySmoke {
    @MainActor static func main() {
        let source = "test.luma.legacy.\(UUID())", destination = "test.luma.current.\(UUID())"
        let defaults = UserDefaults(suiteName: destination)!
        defer { defaults.removePersistentDomain(forName: source); defaults.removePersistentDomain(forName: destination) }
        let history = Data([1, 2, 3])
        defaults.setPersistentDomain(["showTimelinePreview": true, "volume": 80,
            "localPlaybackMemory.v1": history, "networkServers.v1": history,
            "oneDrive.clientID": "public-client-id", "oneDrive.accountID": "old-login",
            "NSWindow Frame IIVE.MainWindow": "old-window", "AppleLanguages": ["en"]], forName: source)
        defaults.setPersistentDomain(["volume": 20], forName: destination)
        let copied = PlayerIdentity.migratePreferences(defaults: defaults, destination: destination, source: source)
        precondition(copied == 4)
        precondition(defaults.integer(forKey: "volume") == 20)
        precondition(defaults.bool(forKey: "showTimelinePreview"))
        precondition(defaults.data(forKey: "localPlaybackMemory.v1") == history)
        precondition(defaults.data(forKey: "networkServers.v1") == history)
        precondition(defaults.string(forKey: "oneDrive.clientID") == "public-client-id")
        let current = defaults.persistentDomain(forName: destination)!
        precondition(current["oneDrive.accountID"] == nil && current["AppleLanguages"] == nil)
        precondition(defaults.persistentDomain(forName: source)?["oneDrive.accountID"] as? String == "old-login")
        defaults.removeObject(forKey: "showTimelinePreview")
        precondition(PlayerIdentity.migratePreferences(defaults: defaults, destination: destination, source: source) == 0)
        precondition(defaults.object(forKey: "showTimelinePreview") == nil)
        precondition(PlayerIdentity.redirectURI == "msauth.com.august.lumaplayer://auth")
        print("PASS: one-time preference import, history/server metadata preservation, existing-value precedence, old domain retained, old login/system preferences excluded; isolated test suites only")
    }
}
