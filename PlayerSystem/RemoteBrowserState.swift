// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Observation

struct RemoteBrowserRow: Identifiable, Equatable {
    let id: String
    let name: String
    let directory: Bool
    let size: Int64?
    let playable: Bool
    var canOpen: Bool { directory || playable }
    init(_ item: WebDAVItem) {
        id = item.id; name = item.name; directory = item.directory; size = item.size
        playable = NetworkMediaRequest.directFormats[(item.name as NSString).pathExtension.lowercased()] != nil
    }
    init(_ item: OneDriveItem) {
        id = item.id; name = item.name; directory = item.folder != nil; size = item.size; playable = item.playable
    }
    static func selectedMedia(in rows: [Self], selection: Set<String>) -> [String] {
        // Preserve the visible sort order, never Set iteration order.
        rows.filter { selection.contains($0.id) && !$0.directory && $0.playable }.map(\.id)
    }
}

enum RemoteBrowserSort: String, CaseIterable {
    case name, nameDescending, smallest, largest
    var title: String {
        switch self {
        case .name: return String(localized: "Name · A–Z")
        case .nameDescending: return String(localized: "Name · Z–A")
        case .smallest: return String(localized: "Size · Smallest First")
        case .largest: return String(localized: "Size · Largest First")
        }
    }
    func apply(to rows: [RemoteBrowserRow], query: String) -> [RemoteBrowserRow] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return rows.filter { row in words.allSatisfy { row.name.localizedStandardContains($0) } }.sorted { a, b in
            if a.directory != b.directory { return a.directory }
            // Directory aggregate sizes aren't comparable to file sizes. Missing
            // file sizes stay last in both directions, never masquerading as zero.
            if !a.directory, self == .smallest || self == .largest {
                let x = a.size.flatMap { $0 >= 0 ? $0 : nil }, y = b.size.flatMap { $0 >= 0 ? $0 : nil }
                if let x, let y, x != y { return self == .smallest ? x < y : x > y }
                if (x == nil) != (y == nil) { return x != nil }
            }
            let comparison = a.name.localizedStandardCompare(b.name)
            if comparison != .orderedSame { return self == .nameDescending ? comparison == .orderedDescending : comparison == .orderedAscending }
            return a.id < b.id
        }
    }
}

/// Session-only directory snapshots. Never persist URLs, credentials or page links.
@MainActor final class RemoteDirectoryCache<Item> {
    struct Listing {
        var items: [Item]
        var next: String? = nil
        var seenPages: Set<String> = []
        var selection: Set<String> = []
        var incompleteReason: String? = nil
        var updated: TimeInterval
        func isFresh(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool { now - updated < 45 }
    }
    private var entries: [String: Listing] = [:]
    private var order: [String] = []
    private let capacity: Int
    private let itemBudget: Int
    init(capacity: Int = 12, itemBudget: Int = 10_000) {
        self.capacity = max(1, capacity); self.itemBudget = max(1, itemBudget)
    }
    func read(_ key: String) -> Listing? {
        guard let value = entries[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return value
    }
    func store(_ listing: Listing, for key: String) {
        remove(key)
        guard listing.items.count <= itemBudget else { return }
        entries[key] = listing; order.append(key)
        while entries.count > capacity || entries.values.reduce(0, { $0 + $1.items.count }) > itemBudget {
            guard let first = order.first else { break }; remove(first)
        }
    }
    func select(_ selection: Set<String>, in key: String) { entries[key]?.selection = selection }
    func remove(_ key: String) { entries[key] = nil; order.removeAll { $0 == key } }
    func clear() { entries.removeAll(); order.removeAll() }
}

@MainActor enum RemoteBrowserMemory {
    static let webDAV = RemoteDirectoryCache<WebDAVItem>()
    static let oneDrive = RemoteDirectoryCache<OneDriveItem>()
    struct DrivePosition {
        let location: OneDriveLocation
        let trail: [OneDriveItem]
    }
    private static var davPositions: [String: URL] = [:]
    private static var drivePositions: [String: DrivePosition] = [:]
    static func key(_ fields: [String]) -> String {
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func davKey(_ url: URL, user: String, password: String) -> String {
        key(["dav", url.absoluteString, user, password])
    }
    static func driveKey(_ location: OneDriveLocation) -> String {
        key(["drive", location.account, location.drive, location.folder])
    }
    static func davPosition(for connection: String) -> URL? { davPositions[connection] }
    static func rememberDAV(_ url: URL, connection: String) {
        if davPositions[connection] == nil && davPositions.count >= 12 { davPositions.removeAll() }
        davPositions[connection] = url
    }
    static func drivePosition(for account: String) -> DrivePosition? { drivePositions[account] }
    static func rememberDrive(_ position: DrivePosition) {
        if drivePositions[position.location.account] == nil && drivePositions.count >= 12 { drivePositions.removeAll() }
        drivePositions[position.location.account] = position
    }
    static func clear() {
        webDAV.clear(); davPositions.removeAll(); clearOneDrive()
    }
    static func clearOneDrive() { oneDrive.clear(); drivePositions.removeAll() }
}

/// Scoped to one browser operation; no timers survive dismissal or navigation.
@MainActor @Observable final class RemoteRetryState {
    private(set) var secondsRemaining: Int?
    private var waitID = UUID()
    private var skipWait = false
    func retryNow() { skipWait = true }
    func reset() { waitID = UUID(); secondsRemaining = nil; skipWait = false }
    func wait(seconds: TimeInterval) async throws {
        let id = UUID(); waitID = id; skipWait = false
        let clock = ContinuousClock(), end = ContinuousClock.now + .seconds(seconds)
        defer { if waitID == id { secondsRemaining = nil } }
        while clock.now < end {
            try Task.checkCancellation()
            guard waitID == id else { throw CancellationError() }
            if skipWait { break }
            let remaining = clock.now.duration(to: end).components
            secondsRemaining = max(1, Int(remaining.seconds) + (remaining.attoseconds > 0 ? 1 : 0))
            try await Task.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
    }
}

/// Each successful page is committed separately, so cancellation or a failed
/// request leaves the last continuation available. No URL reaches UI messages.
struct OneDriveListing {
    var items: [OneDriveItem] = []
    var next: String?
    var seenPages: Set<String> = []
    var incompleteReason: String?
    var itemLimit = 5_000
    var pageLimit = 100
    var isPartial: Bool { next != nil || incompleteReason != nil }

    mutating func append(_ page: OneDrivePage, after requested: String? = nil) throws {
        if let requested {
            guard requested == next, !seenPages.contains(requested), incompleteReason == nil else {
                throw NetworkMediaError.invalid("The folder page changed. Refresh the folder and try again.")
            }
            seenPages.insert(requested)
        }
        var known = Set(items.map(\.id)), overflow = false
        for item in page.value where known.insert(item.id).inserted {
            if items.count < itemLimit { items.append(item) } else { overflow = true }
        }
        items.sort {
            if ($0.folder != nil) != ($1.folder != nil) { return $0.folder != nil }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        next = page.nextLink
        if overflow || (items.count >= itemLimit && next != nil) {
            incompleteReason = "Showing the first \(itemLimit) items. Open a smaller folder to find other files."
        } else if let next, seenPages.contains(next) {
            incompleteReason = "The server repeated a folder page. Refresh to check the remaining files."
        } else if next != nil && seenPages.count + 1 >= pageLimit {
            incompleteReason = "The folder reached the \(pageLimit)-page browsing limit. Results are incomplete."
        }
        if incompleteReason != nil { next = nil }
    }
}
