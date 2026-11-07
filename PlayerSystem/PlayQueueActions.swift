// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

extension PlayerModel {
    func synchronizeQueueOrder() {
        let items = queue
        let ids = items.map(\.id)
        let live = Set(ids)
        customQueueOrder.removeAll { !live.contains($0) }
        let known = Set(customQueueOrder)
        customQueueOrder.append(contentsOf: ids.filter { !known.contains($0) })
        if !browserQueuePathOrder.isEmpty {
            let orderRank = Dictionary(browserQueuePathOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
            let ranked = items.compactMap { item -> (Int, Int64)? in
                guard item.filename.hasPrefix("/") else { return nil }
                let std = URL(fileURLWithPath: item.filename).standardizedFileURL.path
                guard let rank = orderRank[std] else { return nil }
                return (rank, item.id)
            }
            if ranked.count == items.count && items.count > 1 {
                customQueueOrder = ranked.sorted { $0.0 < $1.0 }.map(\.1)
                if items.count >= browserQueuePathOrder.count {
                    browserQueuePathOrder.removeAll()
                }
            }
        }
        if !pendingPlayNextPaths.isEmpty {
            let pathMap = Dictionary(
                items.compactMap { item -> (String, Int64)? in
                    guard item.filename.hasPrefix("/") else { return nil }
                    return (URL(fileURLWithPath: item.filename).standardizedFileURL.path, item.id)
                }, uniquingKeysWith: { first, _ in first }
            )
            let matchedIDs = pendingPlayNextPaths.compactMap { pathMap[$0] }
            if matchedIDs.count == pendingPlayNextPaths.count {
                pendingPlayNextPaths.removeAll()
                playNextQueueItems(matchedIDs)
                return
            }
        }
        let membership = ids.sorted().map(String.init).joined(separator: ",")
        if membership != queueMembership {
            queueMembership = membership
            queueDateTask?.cancel(); queueDateTask = nil
            queueDates = queueDates.filter { live.contains($0.key) }
            queueDateMembership = ""
        }
        if queueSort != "created" {
            queueDateTask?.cancel(); queueDateTask = nil
            // Incomplete scans must be retried when creation-date sort is selected.
            if queueDateMembership.hasPrefix("pending:") { queueDateMembership = "" }
        } else if queueDateMembership != membership && queueDateMembership != "pending:" + membership {
            queueDateTask?.cancel()
            queueDateMembership = "pending:" + membership
            let files = items.filter { $0.filename.hasPrefix("/") }.map { ($0.id, $0.filename) }
            queueDateTask = Task { [weak self] in
                let scan = Task.detached(priority: .utility) {
                    var dates: [Int64: Date] = [:]
                    for (id, filename) in files {
                        guard !Task.isCancelled else { break }
                        if let date = try? URL(fileURLWithPath: filename).resourceValues(forKeys: [.creationDateKey]).creationDate {
                            dates[id] = date
                        }
                    }
                    return dates
                }
                let dates = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
                guard !Task.isCancelled, let self, self.queueSort == "created", self.queueMembership == membership else { return }
                self.queueDates = dates; self.queueDateMembership = membership; self.queueDateTask = nil
                self.synchronizeQueueOrder()
            }
        }
        let desired: [Int64]
        switch queueSort {
        case "name":
            desired = items.sorted {
                if $0.filename.hasPrefix("/") && $1.filename.hasPrefix("/") {
                    let dir0 = ($0.filename as NSString).deletingLastPathComponent
                    let dir1 = ($1.filename as NSString).deletingLastPathComponent
                    if dir0 != dir1 {
                        let dirCmp = dir0.localizedStandardCompare(dir1)
                        if dirCmp != .orderedSame { return dirCmp == .orderedAscending }
                    }
                }
                let comparison = $0.title.localizedStandardCompare($1.title)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }.map(\.id)
        case "created":
            guard queueDateMembership == membership else { return }
            desired = items.sorted {
                let a = queueDates[$0.id] ?? .distantFuture, b = queueDates[$1.id] ?? .distantFuture
                return a == b ? $0.id < $1.id : a < b
            }.map(\.id)
        default: desired = customQueueOrder
        }
        guard desired != ids else { queueOrderRequest = ""; return }
        let request = ids.map(String.init).joined(separator: ",") + ">" + desired.map(String.init).joined(separator: ",")
        guard queueOrderRequest != request else { return }
        queueOrderRequest = request
        session?.reorderPlaylist(desired.map { NSNumber(value: $0) }, expectedNextRevision: remoteNextRevision)
    }
    func moveQueueItems(from offsets: IndexSet, to destination: Int) {
        guard queueSort == "custom" else { return }
        var order = queue.map(\.id)
        order.move(fromOffsets: offsets, toOffset: destination)
        customQueueOrder = order
        synchronizeQueueOrder()
    }
    func playNextLocalFiles(_ urls: [URL]) {
        let expanded = FolderMedia.expandDroppedURLs(urls.filter(\.isFileURL)).media
        guard !expanded.isEmpty else { return }
        if !loaded && path.isEmpty && queue.isEmpty {
            openFiles(expanded, append: false)
            return
        }
        let targetPaths = expanded.map { $0.standardizedFileURL.path }
        let existingByPath = Dictionary(
            queue.compactMap { item -> (String, Int64)? in
                guard item.filename.hasPrefix("/") else { return nil }
                return (URL(fileURLWithPath: item.filename).standardizedFileURL.path, item.id)
            }, uniquingKeysWith: { first, _ in first }
        )
        let missingURLs = expanded.filter { existingByPath[$0.standardizedFileURL.path] == nil }
        if missingURLs.isEmpty {
            let ids = targetPaths.compactMap { existingByPath[$0] }
            playNextQueueItems(ids)
            osd.show("Play Next", symbol: "text.insert")
        } else {
            pendingPlayNextPaths = targetPaths
            openFiles(missingURLs, append: true)
            osd.show("Play Next", symbol: "text.insert")
        }
    }
    func playNextQueueItems(_ ids: [Int64]) {
        let currentID = queue.first(where: \.current)?.id
        let live = Set(queue.map(\.id))
        var selected = Set<Int64>()
        let orderedSelection = ids.filter { live.contains($0) && $0 != currentID && selected.insert($0).inserted }
        guard !orderedSelection.isEmpty else { return }
        var order = queue.map(\.id).filter { !selected.contains($0) }
        let insertIdx: Int
        if let currentID, let curIdx = order.firstIndex(of: currentID) {
            insertIdx = min(order.count, curIdx + 1)
        } else {
            insertIdx = 0
        }
        order.insert(contentsOf: orderedSelection, at: insertIdx)
        customQueueOrder = order
        if queueSort != "custom" {
            queueSort = "custom"
        } else {
            synchronizeQueueOrder()
        }
    }
    func removeQueueItems(_ ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        cancelFolderScan()
        for id in queue.map(\.id) where ids.contains(id) {
            session?.removePlaylistID(id)
        }
    }
    func clearInactiveQueueItems() {
        cancelFolderScan()
        let inactiveIDs = queue.filter { !$0.current }.map(\.id)
        guard !inactiveIDs.isEmpty else { return }
        command(["playlist-clear"])
    }
    func clearPlayQueue() {
        cancelFolderScan()
        savePosition()
        command(["playlist-clear"])
        command(["stop"])
        remoteEntries.removeAll()
        customQueueOrder.removeAll()
        browserQueuePathOrder.removeAll()
        pendingPlayNextPaths.removeAll()
        folderQueueStatus = ""
    }
}

