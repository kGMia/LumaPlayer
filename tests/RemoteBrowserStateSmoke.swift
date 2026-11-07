// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main enum RemoteBrowserStateSmoke {
    @MainActor static func main() async throws {
        let retry = RemoteRetryState()
        let operation = Task { try await retry.wait(seconds: 12) }
        while retry.secondsRemaining == nil { await Task.yield() }
        precondition((retry.secondsRemaining ?? 0) > 0)
        retry.retryNow(); try await operation.value
        precondition(retry.secondsRemaining == nil)
        let canceled = Task { try await retry.wait(seconds: 12) }
        while retry.secondsRemaining == nil { await Task.yield() }
        canceled.cancel()
        do { try await canceled.value; fatalError("Cancellation ignored") } catch is CancellationError {}
        precondition(retry.secondsRemaining == nil)
        let old = Task { try await retry.wait(seconds: 12) }
        while retry.secondsRemaining == nil { await Task.yield() }
        retry.reset()
        do { try await old.value; fatalError("Reset ignored") } catch is CancellationError {}
        print("PASS: retry countdown, retry-now, cancellation and stale operation reset")
        func row(_ name: String, size: Int64? = nil, directory: Bool = false, id: String? = nil) -> RemoteBrowserRow {
            RemoteBrowserRow(WebDAVItem(url: URL(string: "https://example.invalid/")!.appendingPathComponent(id ?? name),
                name: name, directory: directory, size: size))
        }
        let rows = [row("Clip 10.mp4", size: 200), row("Clip 2.mp4", size: 10), row("Folder", directory: true),
                    row("Café.mov"), row("unknown.mkv", size: -1)]
        precondition(RemoteBrowserSort.name.apply(to: rows, query: "").map(\.name) == ["Folder", "Café.mov", "Clip 2.mp4", "Clip 10.mp4", "unknown.mkv"])
        precondition(RemoteBrowserSort.nameDescending.apply(to: rows, query: "").first?.directory == true)
        precondition(RemoteBrowserSort.largest.apply(to: rows, query: "").map(\.name) == ["Folder", "Clip 10.mp4", "Clip 2.mp4", "Café.mov", "unknown.mkv"])
        precondition(RemoteBrowserSort.smallest.apply(to: rows, query: "")[1].name == "Clip 2.mp4")
        precondition(RemoteBrowserSort.name.apply(to: rows, query: "  CLIP  2 ").map(\.name) == ["Clip 2.mp4"])
        precondition(RemoteBrowserSort.name.apply(to: rows, query: "cafe").map(\.name) == ["Café.mov"])
        precondition(RemoteBrowserSort.name.apply(to: rows, query: "nothing").isEmpty)
        let duplicates = [row("same.mp4", id: "b"), row("same.mp4", id: "a")]
        precondition(RemoteBrowserSort.name.apply(to: duplicates, query: "").first?.id.hasSuffix("/a") == true)
        precondition(!row("notes.txt").canOpen && row("folder", directory: true).canOpen && row("video.mkv").canOpen)
        let batchRows = RemoteBrowserSort.largest.apply(to: rows + [row("notes.txt")], query: "")
        let batchIDs = RemoteBrowserRow.selectedMedia(in: batchRows, selection: Set(batchRows.map(\.id)))
        precondition(batchIDs == batchRows.filter { !$0.directory && $0.playable }.map(\.id))
        precondition(!batchIDs.contains(where: { $0.hasSuffix("Folder") || $0.hasSuffix("notes.txt") }))
        let a = WebDAVItem(url: URL(string: "https://example.invalid/b.mp4")!, name: "b.mp4", directory: false, size: nil)
        let b = WebDAVItem(url: URL(string: "https://example.invalid/a.mp4")!, name: "a.mp4", directory: false, size: nil)
        let directory = WebDAVItem(url: URL(string: "https://example.invalid/sub/")!, name: "sub", directory: true, size: nil)
        precondition(RemoteMediaBatch.media([a, directory, b, a]).map(\.name) == ["b.mp4", "a.mp4"])
        func driveItem(_ id: String) throws -> OneDriveItem {
            try JSONDecoder().decode(OneDriveItem.self, from: JSONSerialization.data(withJSONObject: ["id": id, "name": "Clip \(id).mkv"]))
        }
        let d1 = try driveItem("1"), d2 = try driveItem("2"), d3 = try driveItem("3")
        var listing = OneDriveListing(itemLimit: 3, pageLimit: 3)
        try listing.append(.init(value: [d2, d2], nextLink: "page-2"))
        precondition(listing.items.count == 1 && listing.isPartial)
        let retained = listing // Snapshot while a later network read is pending/cancelled.
        do {
            try listing.append(.init(value: [d3], nextLink: nil), after: "stale-page")
            fatalError("Unexpected page accepted")
        } catch {}
        precondition(listing.items.map(\.id) == retained.items.map(\.id) && listing.next == retained.next)
        try listing.append(.init(value: [d2, d1], nextLink: "page-3"), after: "page-2")
        precondition(listing.items.map(\.id) == ["1", "2"])
        try listing.append(.init(value: [d3], nextLink: nil), after: "page-3")
        precondition(listing.items.count == 3 && !listing.isPartial) // Exactly at limit can be complete.
        var limited = OneDriveListing(itemLimit: 2)
        try limited.append(.init(value: [d1, d2, d3], nextLink: nil))
        precondition(limited.items.count == 2 && limited.isPartial && limited.next == nil)
        var paged = OneDriveListing(pageLimit: 2)
        try paged.append(.init(value: [], nextLink: "page-2"))
        try paged.append(.init(value: [], nextLink: "page-3"), after: "page-2")
        precondition(paged.isPartial && paged.next == nil && paged.incompleteReason?.contains("page") == true)
        var repeated = OneDriveListing()
        try repeated.append(.init(value: [d1], nextLink: "repeat"))
        try repeated.append(.init(value: [d2], nextLink: "repeat"), after: "repeat")
        precondition(repeated.items.count == 2 && repeated.next == nil && repeated.isPartial)
        print("PASS: incremental page merge, unique item budget, stale page rejection, retained progress, exact completion, item/page caps and pagination cycles")
        let cache = RemoteDirectoryCache<String>(capacity: 2, itemBudget: 4)
        cache.store(.init(items: ["a", "b"], next: "page-2", seenPages: ["page-1"], updated: 100), for: "one")
        cache.store(.init(items: ["partial"], incompleteReason: "Result limit", updated: 99), for: "partial")
        precondition(cache.read("partial")?.incompleteReason == "Result limit")
        cache.remove("partial")
        cache.select(["a", "b"], in: "one")
        let saved = cache.read("one")!
        precondition(saved.selection == ["a", "b"] && saved.next == "page-2" && saved.seenPages == ["page-1"])
        precondition(saved.isFresh(now: 144) && !saved.isFresh(now: 145))
        cache.store(.init(items: ["c"], updated: 101), for: "two")
        _ = cache.read("one") // LRU access, not a freshness extension.
        cache.store(.init(items: ["d"], updated: 102), for: "three")
        precondition(cache.read("two") == nil && cache.read("one")?.updated == 100)
        cache.store(.init(items: ["e", "f", "g"], updated: 103), for: "four")
        precondition(cache.read("one") == nil && cache.read("four")?.items.count == 3)
        cache.store(.init(items: ["1", "2", "3", "4", "5"], updated: 104), for: "oversized")
        precondition(cache.read("oversized") == nil)
        let url = URL(string: "https://example.invalid/dav/?token=test")!
        let accountKey = RemoteBrowserMemory.davKey(url, user: "a", password: "one")
        precondition(accountKey != RemoteBrowserMemory.davKey(url, user: "a", password: "two"))
        precondition(accountKey != RemoteBrowserMemory.davKey(url, user: "b", password: "one"))
        precondition(!accountKey.contains("token") && accountKey.count == 64)
        let location = OneDriveLocation(account: "account-a", drive: "drive", folder: "folder")
        precondition(RemoteBrowserMemory.driveKey(location) != RemoteBrowserMemory.driveKey(.init(account: "account-b", drive: "drive", folder: "folder")))
        RemoteBrowserMemory.rememberDAV(url, connection: accountKey)
        RemoteBrowserMemory.rememberDrive(.init(location: location, trail: []))
        precondition(RemoteBrowserMemory.davPosition(for: accountKey) == url)
        precondition(RemoteBrowserMemory.drivePosition(for: "account-a")?.location == location)
        precondition(RemoteBrowserMemory.drivePosition(for: "account-b") == nil)
        RemoteBrowserMemory.clearOneDrive()
        precondition(RemoteBrowserMemory.drivePosition(for: "account-a") == nil && RemoteBrowserMemory.davPosition(for: accountKey) == url)
        RemoteBrowserMemory.clear(); cache.clear()
        precondition(RemoteBrowserMemory.davPosition(for: accountKey) == nil && cache.read("four") == nil)
        print("PASS: batch selection/order/deduplication, natural sorting, search, directory budgets, multi-selection restoration and credential/account isolation. No GUI or remote service used.")
    }
}
