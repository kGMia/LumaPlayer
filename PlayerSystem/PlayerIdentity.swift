// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum PlayerIdentity {
    static let bundleIdentifier = "com.august.lumaplayer"
    static let legacyBundleIdentifier = "org.iina-community.video-enhancer.player"
    static let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Luma Player"
    static let redirectURI = "msauth.\(bundleIdentifier)://auth"
    private static let migrationKey = "identity.importedPreferences.v1"

    /// Import app preferences once, before any models or @AppStorage read them.
    /// Keep the legacy domain intact and never overwrite existing new-app values.
    /// Tokens remain in Keychain; the new access group requires a fresh login.
    @MainActor @discardableResult
    static func migratePreferences(defaults: UserDefaults = .standard,
                                   destination: String = bundleIdentifier,
                                   source: String = legacyBundleIdentifier) -> Int {
        guard destination != source else { return 0 }
        let current = defaults.persistentDomain(forName: destination) ?? [:]
        guard current[migrationKey] as? Bool != true else { return 0 }
        let old = defaults.persistentDomain(forName: source) ?? [:]
        var merged = current, count = 0
        for (key, value) in old where current[key] == nil {
            guard key != migrationKey, key != "oneDrive.accountID",
                  !key.hasPrefix("NS"), !key.hasPrefix("Apple"),
                  !key.hasPrefix("com.apple.") else { continue }
            merged[key] = value
            count += 1
        }
        merged[migrationKey] = true
        defaults.setPersistentDomain(merged, forName: destination)
        return count
    }
}
