// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct OneDriveSettingsSection: View {
    @ObservedObject var model: PlayerModel
    private let account = OneDriveAccount.shared
    @State private var clientID = ""
    @State private var message = ""
    @State private var task: Task<Void, Never>?
    @State private var browser = false
    var body: some View {
        Section("OneDrive · Preview") {
            TextField("Application (client) ID", text: $clientID)
                .textFieldStyle(.roundedBorder).disabled(account.busy)
            Text("Register a public-client Microsoft application first. Use delegated Files.Read access and this redirect URI:")
                .font(.caption).foregroundStyle(.secondary)
            Text(OneDriveAccount.redirectURI).font(.caption.monospaced()).textSelection(.enabled)
            HStack {
                Button("Save Client ID") { run { try await account.configure(clientID) } }.disabled(account.busy)
                Button(account.connected ? String(localized: "Change Account…") : String(localized: "Sign In…"), systemImage: "person.crop.circle") {
                    run { try await account.configure(clientID); try await account.signIn() }
                }.disabled(account.busy || UUID(uuidString: clientID.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                Button("Browse…", systemImage: "cloud") { browser = true }.disabled(!account.connected || account.busy)
                if account.connected {
                    Button("Disconnect", role: .destructive) { run { try await account.disconnect() } }.disabled(account.busy)
                }
            }
            if account.busy { ProgressView("Connecting to Microsoft…").controlSize(.small) }
            Text(account.connected ? String(localized: "Connected · \(account.name)") : String(localized: "Not signed in"))
                .font(.caption).foregroundStyle(.secondary)
            Text("Tokens stay in MSAL's application Keychain cache. Disconnect removes this app's cached login; already opened download streams can continue. No client secret is required.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Microsoft app registration instructions", destination: URL(string: "https://learn.microsoft.com/en-us/entra/msal/objc/install-and-configure-msal")!)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .onAppear { clientID = account.clientID }
        .onDisappear { task?.cancel() }
        .sheet(isPresented: $browser) { OneDriveBrowser(model: model) }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        task?.cancel(); message = ""
        task = Task {
            do { try await operation(); if !Task.isCancelled { message = "Updated." } }
            catch { if !Task.isCancelled { message = oneDriveMessage(error) } }
        }
    }
}

func oneDriveMessage(_ error: Error) -> String {
    NetworkMediaError.message(for: error)
}

struct OneDriveBrowser: View {
    @ObservedObject var model: PlayerModel
    private let account = OneDriveAccount.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var trail: [OneDriveItem] = []
    @State private var location: OneDriveLocation?
    @State private var listing = OneDriveListing()
    private var items: [OneDriveItem] { listing.items }
    private var next: String? { listing.next }
    private var seenPages: Set<String> { listing.seenPages }
    @State private var loadingRemaining = false
    @State private var busy = false
    @State private var retry = RemoteRetryState()
    @State private var message = ""
    @State private var append = false
    @State private var task: Task<Void, Never>?
    @State private var ticket = UUID()
    @State private var selection: Set<String> = []
    @State private var restoreSelection = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("OneDrive", systemImage: "cloud").font(.title2.bold())
                Spacer()
                Button("Root", systemImage: "house") { loadRoot() }.disabled(busy || !account.connected)
                Button("Refresh", systemImage: "arrow.clockwise") { refresh() }.disabled(busy || !account.connected)
                    .keyboardShortcut("r", modifiers: .command)
            }
            if !account.connected {
                ContentUnavailableView("Sign In First", systemImage: "person.crop.circle", description: Text("Open Settings → Network to configure your Microsoft client ID and sign in."))
            } else {
                HStack {
                    Button("Back", systemImage: "chevron.left", action: goUp)
                        .disabled(busy || trail.count <= 1)
                    Text(trail.map(\.name).joined(separator: " / ")).lineLimit(1).truncationMode(.middle)
                }
                RemoteDirectoryList(rows: items.map(RemoteBrowserRow.init),
                    locationKey: location.map(RemoteBrowserMemory.driveKey) ?? "",
                    restoreSelection: restoreSelection, busy: busy, hasMore: listing.isPartial,
                    canGoUp: trail.count > 1, selection: $selection, open: openItem, goUp: goUp,
                    addToQueue: { appendSelected($0) }, playNext: { appendSelected($0, next: true) })
                if next != nil {
                    HStack {
                        Button("Load More…", systemImage: "ellipsis") { more() }
                        Button("Load Remaining Items", systemImage: "arrow.down.circle") { more(all: true) }
                            .help("Read the rest of this folder so search and sorting include all available items, up to the browsing limit.")
                        Spacer()
                    }.disabled(busy)
                }
                if let reason = listing.incompleteReason {
                    Label(reason, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Toggle("Add to play queue", isOn: $append)
                    Spacer()
                    Toggle("Add Media from the Same Folder", isOn: $model.autoQueueFolder)
                }.disabled(busy)
            }
            RemoteRetryBanner(state: retry, cancel: cancelRead)
            if busy && retry.secondsRemaining == nil {
                HStack {
                    ProgressView(loadingRemaining ? "Loading folder · \(items.count) items available…" : "Reading OneDrive…")
                        .controlSize(.small)
                    Spacer()
                    Button("Cancel", systemImage: "xmark", action: cancelRead)
                }
            }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(22).frame(width: 650, height: 520)
        .onAppear { restore() }
        .onChange(of: account.identity) { _, _ in
            listing = OneDriveListing(); location = nil; trail = []; selection = []
            restore()
        }
        .onDisappear { rememberSelection(); task?.cancel(); retry.reset(); ticket = UUID() }
    }
    private func goUp() {
        guard !busy, trail.count > 1, let location else { return }
        load(trail[trail.count - 2], drive: location.drive, addToTrail: false)
    }
    private func appendSelected(_ ids: [String], next: Bool = false) {
        guard !busy, let location, location.account == account.identity else { return }
        let indexed = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let media = ids.compactMap { indexed[$0] }.filter(\.playable).map { $0.mediaItem(drive: location.drive) }
        guard !media.isEmpty else { return }
        openWindow(id: "player")
        if next { model.playNextRemoteBatch(media, origin: .oneDrive(location)) }
        else { model.appendRemoteBatch(media, origin: .oneDrive(location)) }
        message = model.folderQueueStatus; selection = []
        RemoteBrowserMemory.oneDrive.select([], in: RemoteBrowserMemory.driveKey(location))
    }
    private func openItem(_ id: String) {
        guard !busy, let location, let item = items.first(where: { $0.id == id }) else { return }
        RemoteBrowserMemory.oneDrive.select([id], in: RemoteBrowserMemory.driveKey(location))
        if item.folder != nil { load(item, drive: location.drive) }
        else if item.playable { play(item, location: location) }
    }
    private func cancelRead() {
        task?.cancel(); retry.reset(); ticket = UUID(); busy = false; loadingRemaining = false
        message = next != nil
            ? "Request cancelled. Loaded items are kept; Load Remaining Items resumes from the next page."
            : "Request cancelled."
    }
    private func start(_ operation: @escaping @MainActor (UUID) async throws -> Void) {
        task?.cancel(); retry.reset(); let id = UUID(); ticket = id; busy = true; loadingRemaining = false; message = ""
        task = Task {
            do {
                try await NetworkRequestPolicy.$retryWait.withValue({ seconds in try await retry.wait(seconds: seconds) }) {
                    try await operation(id)
                }
            }
            catch { if !Task.isCancelled, ticket == id { message = oneDriveMessage(error) } }
            if ticket == id { busy = false; loadingRemaining = false }
        }
    }
    private func loadRoot() {
        guard account.connected else { return }
        rememberSelection()
        let identity = account.identity
        start { id in
            let root = try await OneDriveClient.root(account: identity)
            let place = OneDriveLocation(account: identity, drive: root.drive, folder: root.item.id)
            let page = try await OneDriveClient.page(place)
            guard !Task.isCancelled, ticket == id, account.identity == identity else { return }
            var updated = OneDriveListing(); try updated.append(page)
            selection = []; trail = [root.item]; location = place; accept(updated)
            restoreSelection = UUID()
        }
    }
    private func rememberSelection() {
        if let location { RemoteBrowserMemory.oneDrive.select(selection, in: RemoteBrowserMemory.driveKey(location)) }
    }
    private func restore() {
        task?.cancel(); retry.reset(); ticket = UUID(); busy = false; message = ""
        guard account.connected else { return }
        if let saved = RemoteBrowserMemory.drivePosition(for: account.identity) {
            navigate(saved.location, trail: saved.trail)
        } else { loadRoot() }
    }
    private func refresh() {
        guard let location else { loadRoot(); return }
        navigate(location, trail: trail, force: true)
    }
    private func load(_ folder: OneDriveItem, drive: String, addToTrail: Bool = true) {
        let place = OneDriveLocation(account: account.identity, drive: drive, folder: folder.id)
        let targetTrail = addToTrail ? trail + [folder] : Array(trail.dropLast())
        navigate(place, trail: targetTrail)
    }
    private func navigate(_ place: OneDriveLocation, trail targetTrail: [OneDriveItem], force: Bool = false) {
        rememberSelection()
        let sameListing = location == place
        let key = RemoteBrowserMemory.driveKey(place)
        let cached = RemoteBrowserMemory.oneDrive.read(key)
        let refreshPages = min(100, (sameListing ? seenPages.count : cached?.seenPages.count ?? 0) + 1)
        // Keep the same List and row IDs for refresh; SwiftUI retains its scroll
        // position. Returning to a cached folder restores its selected row.
        if !sameListing {
            listing = OneDriveListing(items: cached?.items ?? [], next: cached?.next,
                seenPages: cached?.seenPages ?? [], incompleteReason: cached?.incompleteReason)
            selection = cached?.selection ?? []
            location = place; trail = targetTrail; restoreSelection = UUID()
        }
        if !force, let cached, cached.isFresh() {
            task?.cancel(); retry.reset(); ticket = UUID(); busy = false
            message = "Recent folder listing · Refresh to check for changes."
            RemoteBrowserMemory.rememberDrive(.init(location: place, trail: targetTrail))
            return
        }
        start { id in
            do {
                var updated = OneDriveListing()
                try updated.append(try await OneDriveClient.page(place))
                // Refresh the pages already visible without counting duplicates
                // toward the item budget or silently presenting a truncated list.
                for _ in 1..<refreshPages {
                    guard let link = updated.next else { break }
                    let page = try await OneDriveClient.page(place, next: link)
                    try Task.checkCancellation()
                    try updated.append(page, after: link)
                }
                guard !Task.isCancelled, ticket == id, account.identity == place.account else { return }
                location = place; trail = targetTrail; accept(updated)
                if !sameListing { restoreSelection = UUID() }
            } catch {
                if !Task.isCancelled, ticket == id { RemoteBrowserMemory.oneDrive.remove(key) }
                throw error
            }
        }
    }
    private func more(all: Bool = false) {
        guard !busy, let place = location, next != nil else { return }
        start { id in
            loadingRemaining = all
            var updated = listing
            repeat {
                guard let link = updated.next else { break }
                let page = try await OneDriveClient.page(place, next: link)
                guard !Task.isCancelled, ticket == id, account.identity == place.account, location == place else { return }
                try updated.append(page, after: link)
                accept(updated)
                // Publish each page, retaining usable results even if a later
                // request fails, is rate-limited, or is explicitly cancelled.
                await Task.yield()
                try Task.checkCancellation()
            } while all && updated.next != nil
            message = updated.incompleteReason ?? (updated.next == nil
                ? "All \(items.count) items loaded. Search and sorting now cover this folder."
                : "\(items.count) items loaded. More items are available.")
        }
    }
    private func accept(_ updated: OneDriveListing) {
        listing = updated
        selection.formIntersection(items.map(\.id))
        if let location {
            RemoteBrowserMemory.oneDrive.store(.init(items: items, next: next, seenPages: seenPages,
                selection: selection, incompleteReason: listing.incompleteReason,
                updated: ProcessInfo.processInfo.systemUptime), for: RemoteBrowserMemory.driveKey(location))
            RemoteBrowserMemory.rememberDrive(.init(location: location, trail: trail))
        }
    }
    private func play(_ item: OneDriveItem, location: OneDriveLocation) {
        let enqueueFolder = model.autoQueueFolder, shouldAppend = append
        start { id in
            let siblings = enqueueFolder ? try await OneDriveClient.siblings(location) : [item.mediaItem(drive: location.drive)]
            guard !Task.isCancelled, ticket == id, account.identity == location.account else { return }
            openWindow(id: "player")
            model.openRemote(item.mediaItem(drive: location.drive), siblings: siblings, origin: .oneDrive(location), append: shouldAppend)
            if shouldAppend { message = "Added to play queue." } else { dismiss() }
        }
    }
}
