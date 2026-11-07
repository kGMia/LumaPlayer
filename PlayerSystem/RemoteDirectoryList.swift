// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Selection and keyboard behavior use the native List; search never issues a
/// network request or changes the siblings passed to the playback queue.
struct RemoteDirectoryList: View {
    let rows: [RemoteBrowserRow]
    let locationKey: String
    let restoreSelection: UUID
    let busy: Bool
    let hasMore: Bool
    let canGoUp: Bool
    @Binding var selection: Set<String>
    let open: (String) -> Void
    let goUp: () -> Void
    let addToQueue: ([String]) -> Void
    let playNext: ([String]) -> Void
    @AppStorage("remoteBrowser.sort") private var sort: RemoteBrowserSort = .name
    @State private var query = ""
    @State private var visible: [RemoteBrowserRow] = []
    @State private var displayedLocation: String?
    @FocusState private var focus: Focus?
    private enum Focus: Hashable { case search, list }
    private var selected: RemoteBrowserRow? { selection.count == 1 ? visible.first { selection.contains($0.id) } : nil }
    private var selectedMedia: [String] { RemoteBrowserRow.selectedMedia(in: visible, selection: selection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Find in Folder", systemImage: "magnifyingglass") { focus = .search }
                    .labelStyle(.iconOnly).buttonStyle(.plain).keyboardShortcut("f", modifiers: .command)
                    .help("Find in this folder (⌘F)")
                TextField("Search This Folder", text: $query).textFieldStyle(.roundedBorder).focused($focus, equals: .search)
                    .onSubmit { focus = .list; if selection.isEmpty, let first = visible.first { selection = [first.id] } }
                    .onKeyPress(.escape) {
                        guard !query.isEmpty else { return .ignored }
                        query = ""; return .handled
                    }
                if !query.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { query = ""; focus = .search }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                }
                Picker("Sort", selection: $sort) {
                    ForEach(RemoteBrowserSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 170).accessibilityLabel("Sort folder contents")
            }
            ScrollViewReader { proxy in
                List(visible, selection: $selection) { row in
                    HStack {
                        Image(systemName: row.directory ? "folder" : row.playable ? "play.rectangle" : "doc")
                        Text(row.name).lineLimit(1)
                        Spacer()
                        if !row.directory, let size = row.size, size >= 0 {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.contentShape(Rectangle()).tag(row.id).id(row.id)
                }
                .focused($focus, equals: .list)
                .contextMenu(forSelectionType: String.self) { ids in
                    if ids.count == 1, let id = ids.first, let row = visible.first(where: { $0.id == id }) {
                        Button(row.directory ? String(localized: "Open Folder") : String(localized: "Play Media"), systemImage: row.directory ? "folder" : "play.fill") { activate(id) }
                            .disabled(busy || !row.canOpen)
                    }
                    let media = RemoteBrowserRow.selectedMedia(in: visible, selection: ids)
                    Button("Play Next", systemImage: "text.insert") { playNext(media) }
                        .disabled(busy || media.isEmpty)
                    Button("Add \(media.count) to Queue", systemImage: "text.badge.plus") { addToQueue(media) }
                        .disabled(busy || media.isEmpty)
                } primaryAction: { ids in if ids.count == 1, let id = ids.first { activate(id) } }
                .onKeyPress(.return) {
                    guard let selected, selected.canOpen, !busy else { return .ignored }
                    activate(selected.id); return .handled
                }
                .onKeyPress(keys: [.upArrow, .downArrow]) { event in
                    guard event.modifiers.contains(.command), !busy else { return .ignored }
                    if event.key == .upArrow, canGoUp { goUp(); return .handled }
                    if event.key == .downArrow, let selected, selected.canOpen { activate(selected.id); return .handled }
                    return .ignored
                }
                .overlay {
                    if visible.isEmpty && !busy {
                        Text(query.isEmpty ? String(localized: "No files in this folder") : hasMore ? String(localized: "No matches in loaded items") : String(localized: "No matching files"))
                            .foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
                .task(id: restoreSelection) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    updateVisible()
                    if let target = visible.first(where: { selection.contains($0.id) })?.id ?? visible.first?.id {
                        proxy.scrollTo(target, anchor: selection.isEmpty ? .top : .center)
                    }
                    if focus == nil { focus = .list }
                }
            }
            HStack {
                Text(hasMore ? "\(visible.count) of \(rows.count) loaded · Search and sort cover loaded items only" : "\(visible.count) of \(rows.count) items")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Play Next", systemImage: "text.insert") { playNext(selectedMedia) }
                    .disabled(busy || selectedMedia.isEmpty)
                Button("Add \(selectedMedia.count) to Queue", systemImage: "text.badge.plus") { addToQueue(selectedMedia) }
                    .disabled(busy || selectedMedia.isEmpty)
                Button(selected?.directory == true ? String(localized: "Open Folder") : String(localized: "Play"), systemImage: selected?.directory == true ? "folder" : "play.fill") {
                    if let selected { activate(selected.id) }
                }.disabled(busy || selected?.canOpen != true)
            }
            Text("⌘-click or Shift-click to select multiple items. Add to Queue skips folders and unsupported files.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: rows, initial: true) { _, _ in updateVisible() }
        .onChange(of: query) { _, _ in updateVisible() }
        .onChange(of: sort) { _, _ in updateVisible() }
        .onChange(of: locationKey) { _, _ in query = ""; updateVisible() }
    }
    private func updateVisible() {
        // Rows and location can change in the same SwiftUI update. Clear the old
        // folder's query before checking the restored selection in the new one.
        if displayedLocation != locationKey { displayedLocation = locationKey; query = "" }
        visible = sort.apply(to: rows, query: query)
        // A hidden selection must never let Return play an invisible file.
        selection.formIntersection(visible.map(\.id))
    }
    private func activate(_ id: String) {
        guard !busy, visible.contains(where: { $0.id == id && $0.canOpen }) else { return }
        selection = [id]; open(id)
    }
}

struct RemoteRetryBanner: View {
    let state: RemoteRetryState
    let cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if let seconds = state.secondsRemaining {
            HStack {
                Label("Server busy · retrying in \(seconds)s…", systemImage: "clock.arrow.circlepath")
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: seconds)
                Spacer()
                Button("Retry Now", systemImage: "arrow.clockwise") { state.retryNow() }
                Button("Cancel", systemImage: "xmark", action: cancel)
            }.font(.callout).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
