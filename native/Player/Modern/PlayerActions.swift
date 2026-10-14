// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import ImageIO

struct QueueItem: Identifiable {
    let id: Int64
    let title: String
    let filename: String
    let current: Bool
}
struct MediaChapter: Identifiable {
    let id: Int
    let title: String
    let time: Double
}

extension PlayerModel {
    var muted: Bool { snapshot["mute"] as? Bool ?? false }
    var queue: [QueueItem] {
        (snapshot["playlist"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? NSNumber, let filename = item["filename"] as? String else { return nil }
            return QueueItem(id: id.int64Value, title: item["title"] as? String ?? URL(fileURLWithPath: filename).lastPathComponent,
                             filename: filename, current: item["current"] as? Bool ?? false)
        }
    }
    var chapters: [MediaChapter] {
        (snapshot["chapter-list"] as? [[String: Any]] ?? []).enumerated().compactMap { index, item in
            guard let time = item["time"] as? Double, time.isFinite, time >= 0 else { return nil }
            return MediaChapter(id: index, title: item["title"] as? String ?? "Chapter \(index + 1)", time: time)
        }
    }
    var queueIndex: Int { Int(number("playlist-pos") ?? -1) }
    var canPrevious: Bool { queueIndex > 0 }
    var canNext: Bool { queueIndex >= 0 && queueIndex + 1 < queue.count }
    func previousFile() { guard canPrevious else { return }; cancelFolderScan(); savePosition(); command(["playlist-prev", "weak"]) }
    func nextFile() { guard canNext else { return }; cancelFolderScan(); savePosition(); command(["playlist-next", "weak"]) }
    func playQueueItem(_ id: Int64) {
        cancelFolderScan(); savePosition(); session?.playPlaylistID(id)
    }
    func removeQueueItem(_ id: Int64) {
        cancelFolderScan()
        session?.removePlaylistID(id)
    }
    func toggleMute() { command(["cycle", "mute"]) }
    func stepFrame(backward: Bool = false) {
        guard loaded else { return }
        // Explicit pause also cancels a pending resume after model warm-up.
        command(["set", "pause", "yes"])
        command([backward ? "frame-back-step" : "frame-step"])
    }
    func skip(_ direction: Double, long: Bool = false) {
        guard loaded else { return }
        seek(direction * (long ? longSeekSeconds : seekSeconds), relative: true)
    }
    func changeVolume(_ direction: Double) { setVolume(min(100, max(0, volume + direction * volumeStep))) }
    func handleDoubleClick() {
        if miniPlayer { toggleMiniPlayer(); return }
        switch doubleClickAction {
        case "pause": togglePause()
        case "none": break
        default: toggleFullScreen()
        }
    }
    func stop() { cancelFolderScan(); savePosition(); command(["stop"]) }
    func applyRepeat() {
        command(["set", "loop-file", repeatMode == "file" ? "inf" : "no"])
        command(["set", "loop-playlist", repeatMode == "queue" ? "inf" : "no"])
    }
    func clearRecent() {
        recent = []; UserDefaults.standard.removeObject(forKey: "recent")
        UserDefaults.standard.removeObject(forKey: "positions")
    }
    func showInFinder() {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    func saveScreenshot() {
        guard loaded else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)-\(Int(max(0, position)))s.png"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            // mpv window screenshot includes final scaling, excludes SwiftUI chrome.
            self?.command(["screenshot-to-file", url.path, "window"])
        }
    }
}

/// Serial, bounded metadata cache; never create another mpv session for queue artwork.
struct QueueMetadata: Sendable {
    var duration: Double?
    var size: Int64?
    var cover: Data?
}
actor QueueMetadataCache {
    static let shared = QueueMetadataCache()
    private var cache: [String: QueueMetadata] = [:]
    private var pending: [String: Task<QueueMetadata, Never>] = [:]
    private var tail: Task<QueueMetadata, Never>?
    func read(_ filename: String, cover: Bool) async -> QueueMetadata {
        let key = filename + (cover ? "|cover" : "|basic")
        if let value = cache[key] { return value }
        if let task = pending[key] { return await task.value }
        let previous = tail
        let task = Task.detached(priority: .utility) {
            _ = await previous?.value
            let url = URL(fileURLWithPath: filename)
            let attributes = try? url.resourceValues(forKeys: [.fileSizeKey])
            var result = QueueMetadata(size: attributes?.fileSize.map(Int64.init))
            let asset = AVURLAsset(url: url)
            if let time = try? await asset.load(.duration), time.seconds.isFinite, time.seconds > 0 { result.duration = time.seconds }
            if cover {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 192, height: 108)
                if let image = try? await generator.image(at: CMTime(seconds: min(5, (result.duration ?? 0) * 0.1), preferredTimescale: 600)).image {
                    let data = NSMutableData()
                    if let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) {
                        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
                        if CGImageDestinationFinalize(destination) { result.cover = data as Data }
                    }
                }
            }
            return result
        }
        tail = task; pending[key] = task
        let result = await task.value
        pending[key] = nil
        if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        return result
    }
}

extension PlayerModel {
    func synchronizeQueueOrder() {
        let items = queue
        let ids = items.map(\.id)
        let live = Set(ids)
        customQueueOrder.removeAll { !live.contains($0) }
        let known = Set(customQueueOrder)
        customQueueOrder.append(contentsOf: ids.filter { !known.contains($0) })
        let membership = ids.sorted().map(String.init).joined(separator: ",")
        if membership != queueMembership {
            queueMembership = membership
            queueDateTask?.cancel()
            let files = items.map { ($0.id, $0.filename) }
            queueDateTask = Task { [weak self] in
                let dates = await Task.detached(priority: .utility) {
                    Dictionary(uniqueKeysWithValues: files.compactMap { id, filename -> (Int64, Date)? in
                        guard let date = try? URL(fileURLWithPath: filename).resourceValues(forKeys: [.creationDateKey]).creationDate else { return nil }
                        return (id, date)
                    })
                }.value
                guard !Task.isCancelled, let self, self.queueMembership == membership else { return }
                self.queueDates = dates
                self.synchronizeQueueOrder()
            }
        }
        let desired: [Int64]
        switch queueSort {
        case "name":
            desired = items.sorted {
                let comparison = URL(fileURLWithPath: $0.filename).lastPathComponent.localizedStandardCompare(URL(fileURLWithPath: $1.filename).lastPathComponent)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }.map(\.id)
        case "created":
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
        session?.reorderPlaylist(desired.map { NSNumber(value: $0) })
    }
    func moveQueueItems(from offsets: IndexSet, to destination: Int) {
        guard queueSort == "custom" else { return }
        var order = queue.map(\.id)
        order.move(fromOffsets: offsets, toOffset: destination)
        customQueueOrder = order
        synchronizeQueueOrder()
    }
}

private struct QueueRow: View {
    @ObservedObject var model: PlayerModel
    let item: QueueItem
    @State private var metadata = QueueMetadata()
    var body: some View {
        HStack(spacing: 10) {
            Button { model.playQueueItem(item.id) } label: {
                HStack(spacing: 10) {
                    if model.queueDetailed {
                        Group {
                            if let data = metadata.cover, let image = NSImage(data: data) {
                                Image(nsImage: image).resizable().scaledToFill()
                            } else { Image(systemName: "film").frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
                        }.frame(width: 76, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            if item.current { Image(systemName: "play.fill").foregroundStyle(.tint) }
                            Text(item.title).lineLimit(2)
                        }
                        HStack {
                            Text(durationText).monospacedDigit()
                            if model.queueDetailed {
                                Text("·")
                                Text(metadata.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "N/A")
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(item.title)
            if !item.current {
                Button { model.removeQueueItem(item.id) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).accessibilityLabel("Remove \(item.title) from queue")
            }
        }.padding(.vertical, 4)
            .task(id: item.filename + String(model.queueDetailed)) {
                let result = await QueueMetadataCache.shared.read(item.filename, cover: model.queueDetailed)
                if !Task.isCancelled { metadata = result }
            }
    }
    private var durationText: String {
        guard let value = item.current && model.duration > 0 ? model.duration : metadata.duration,
              value.isFinite, value >= 0 else { return "N/A" }
        let seconds = Int(min(value, Double(Int32.max)))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
struct QueueView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: PlayerModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Play Queue").font(.headline)
                Spacer()
                NativePlayerMenu(model: model, symbol: "line.3.horizontal.decrease", help: "Queue sorting and appearance", entries: { model.queueMenuEntries() })
                    .frame(width: 28, height: 24)
                Button { model.queuePopover = false; openWindow(id: "player"); model.openPanel(append: true) } label: { Image(systemName: "plus") }.help("Add Files…")
            }.padding()
            if !model.folderQueueStatus.isEmpty { Text(model.folderQueueStatus).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom, 6) }
            if model.queue.isEmpty {
                ContentUnavailableView("No Videos Queued", systemImage: "list.bullet", description: Text("Open several files or add videos to the queue."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.queue) { item in
                        QueueRow(model: model, item: item).moveDisabled(model.queueSort != "custom")
                    }.onMove { model.moveQueueItems(from: $0, to: $1) }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
