// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct NetworkMediaSheet: View {
    @ObservedObject var model: PlayerModel
    var initialServerID: UUID? = nil
    @State private var oneDriveBrowser = false
    private let servers = NetworkServerStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var serverID: UUID?
    @State private var serverName = ""
    @State private var appeared = false
    @State private var operation = "Reading folder…"
    @Environment(\.dismiss) private var dismiss
    @State private var address = "https://"
    @State private var username = ""
    @State private var password = ""
    @State private var append = false
    @State private var items: [WebDAVItem] = []
    @State private var folder: URL?
    @State private var listingCredentials: (String, String)?
    @State private var busy = false
    @State private var retry = RemoteRetryState()
    @State private var message = ""
    @State private var task: Task<Void, Never>?
    @State private var ticket = UUID()
    @State private var connectionKey: String?
    @State private var connectionAuth: String?
    @State private var connectionURL: URL?
    @State private var listingKey: String?
    @State private var selection: Set<String> = []
    @State private var restoreSelection = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Open Network", systemImage: "network").font(.title2.bold())
                Spacer()
                Button("OneDrive…", systemImage: "cloud") { oneDriveBrowser = true }
            }
            HStack {
                Picker("Saved server", selection: Binding(get: { serverID?.uuidString ?? "" }, set: { value in
                    if let id = UUID(uuidString: value) { loadServer(id) } else { newConnection() }
                })) {
                    Text("New Connection").tag("")
                    ForEach(servers.servers) { Text($0.name).tag($0.id.uuidString) }
                }
                Button("New", systemImage: "plus") { newConnection() }
            }.disabled(busy)
            HStack {
                TextField("Server name (optional)", text: $serverName)
                    .textInputBorderShape(.roundedRectangle)
                Button(serverID == nil ? String(localized: "Save Server") : String(localized: "Save Changes"), systemImage: "key") { saveServer() }
            }.disabled(busy)
            TextField("Media URL or WebDAV folder URL", text: $address)
                .textInputBorderShape(.roundedRectangle)
                .disabled(busy)
            HStack {
                TextField("Username (optional)", text: $username)
                    .textInputBorderShape(.roundedRectangle)
                SecureField("Password", text: $password)
                    .textInputBorderShape(.roundedRectangle)
            }.disabled(busy)
            HStack {
                Toggle("Add to play queue", isOn: $append)
                Spacer()
                Button("Browse WebDAV", systemImage: "folder.badge.gearshape") { browse() }.disabled(busy)
                Button("Play URL", systemImage: "play.fill") { playAddress() }.disabled(busy)
                    .buttonStyle(.borderedProminent)
            }
            Toggle("Add Media from the Same Folder", isOn: $model.autoQueueFolder)
            Text("Save Server remembers this connection in macOS Keychain. WebDAV supports Basic authentication; media redirects are resolved without sending credentials to other hosts. Authenticated playlists are not supported.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if address.lowercased().hasPrefix("http://") || address.lowercased().hasPrefix("dav://") {
                Label("HTTP sends credentials and media without encryption. Use HTTPS when available.", systemImage: "lock.open")
                    .font(.caption).foregroundStyle(.secondary)
            }
            RemoteRetryBanner(state: retry) { task?.cancel(); retry.reset(); ticket = UUID(); busy = false; message = "Request cancelled." }
            if busy && retry.secondsRemaining == nil { ProgressView(operation).controlSize(.small) }
            if let folder {
                HStack {
                    Button("Up", systemImage: "arrow.up", action: goUp)
                        .disabled(busy || folder.path == "/" || folder.path.isEmpty)
                    Text(folder.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        address = folder.absoluteString; browse(force: true)
                    }.disabled(busy).keyboardShortcut("r", modifiers: .command)
                }
            }
            if folder != nil {
                RemoteDirectoryList(rows: items.map(RemoteBrowserRow.init), locationKey: listingKey ?? "",
                    restoreSelection: restoreSelection, busy: busy, hasMore: false,
                    canGoUp: folder.map { !$0.path.isEmpty && $0.path != "/" } ?? false,
                    selection: $selection, open: openItem, goUp: goUp,
                    addToQueue: { appendSelected($0) }, playNext: { appendSelected($0, next: true) })
                    .frame(minHeight: 210, idealHeight: 290)
            }

            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(22).frame(width: 610)
        .sheet(isPresented: $oneDriveBrowser) { OneDriveBrowser(model: model) }
        .onAppear {
            guard !appeared else { return }; appeared = true
            if let id = initialServerID ?? servers.lastSelected, servers.servers.contains(where: { $0.id == id }) { loadServer(id) }
        }
        .onDisappear {
            if let listingKey { RemoteBrowserMemory.webDAV.select(selection, in: listingKey) }
            task?.cancel(); retry.reset(); ticket = UUID(); password = ""; listingCredentials = nil
        }
    }
    private func goUp() {
        guard !busy, let folder, !folder.path.isEmpty, folder.path != "/" else { return }
        address = folder.deletingLastPathComponent().absoluteString; browse()
    }
    private func appendSelected(_ ids: [String], next: Bool = false) {
        guard !busy, let folder else { return }
        guard listingCredentials?.0 == username, listingCredentials?.1 == password else {
            message = "Credentials changed. Browse the folder again."; return
        }
        let indexed = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let media = RemoteMediaBatch.media(ids.compactMap { indexed[$0] })
        guard !media.isEmpty else { return }
        openWindow(id: "player")
        let origin = RemoteMediaOrigin.webDAV(.init(address: folder.absoluteString, username: username, password: password))
        if next { model.playNextRemoteBatch(media, origin: origin) }
        else { model.appendRemoteBatch(media, origin: origin) }
        message = model.folderQueueStatus; selection = []
        if let listingKey { RemoteBrowserMemory.webDAV.select([], in: listingKey) }
    }
    private func openItem(_ id: String) {
        guard !busy, let item = items.first(where: { $0.id == id }) else { return }
        guard listingCredentials?.0 == username, listingCredentials?.1 == password else {
            message = "Credentials changed. Browse the folder again."; return
        }
        if let listingKey { RemoteBrowserMemory.webDAV.select([item.id], in: listingKey) }
        if item.directory { address = item.url.absoluteString; browse() }
        else { play(item.url, fileName: item.name) }
    }
    private func playAddress() {
        do { play(try NetworkMediaRequest.parse(address)) }
        catch { message = error.localizedDescription }
    }
    private func play(_ url: URL, fileName: String? = nil) {
        if let item = items.first(where: { $0.url == url && !$0.directory }) {
            openWindow(id: "player")
            model.openWebDAV(item, siblings: items, credentials: NetworkServerCredentials(address: folder?.absoluteString ?? address, username: username, password: password), append: append)
            if append { message = "Added to play queue." } else { dismiss() }
            return
        }
        task?.cancel(); let id = UUID(); ticket = id
        let user = username, secret = password, shouldAppend = append
        busy = true; operation = "Connecting to media…"; message = ""
        task = Task {
            do {
                let request = try await NetworkPlaybackResolver.prepare(url, username: user, password: secret, fileName: fileName)
                guard !Task.isCancelled, ticket == id else { return }
                busy = false
                openWindow(id: "player")
                model.openNetwork(request, append: shouldAppend)
                if shouldAppend { message = "Added to play queue." } else { dismiss() }
            } catch {
                guard !Task.isCancelled, ticket == id else { return }
                busy = false
                message = NetworkMediaError.message(for: error)
            }
        }
    }
    private func newConnection() {
        task?.cancel(); retry.reset(); ticket = UUID(); busy = false
        serverID = nil; serverName = ""; address = "https://"; username = ""; password = ""
        items = []; folder = nil; listingCredentials = nil; message = ""
        listingKey = nil; connectionKey = nil; connectionAuth = nil; connectionURL = nil; selection = []
    }
    private func loadServer(_ id: UUID) {
        newConnection(); serverID = id
        serverName = servers.servers.first(where: { $0.id == id })?.name ?? ""
        do {
            let saved = try servers.credentials(for: id)
            address = saved.address; username = saved.username; password = saved.password
            let key = RemoteBrowserMemory.davKey(try NetworkMediaRequest.parse(saved.address, webDAV: true), user: username, password: password)
            connectionKey = key
            connectionAuth = RemoteBrowserMemory.key([username, password])
            connectionURL = try NetworkMediaRequest.parse(saved.address, webDAV: true)
            servers.select(id)
            if let remembered = RemoteBrowserMemory.davPosition(for: key) {
                address = remembered.absoluteString; browse()
            }
        } catch { message = error.localizedDescription }
    }
    private func saveServer() {
        do {
            serverID = try servers.save(id: serverID, name: serverName,
                credentials: NetworkServerCredentials(address: address, username: username, password: password))
            if let serverID { serverName = servers.servers.first(where: { $0.id == serverID })?.name ?? serverName }
            connectionKey = RemoteBrowserMemory.davKey(try NetworkMediaRequest.parse(address, webDAV: true), user: username, password: password)
            connectionAuth = RemoteBrowserMemory.key([username, password])
            connectionURL = try NetworkMediaRequest.parse(address, webDAV: true)
            if let folder, let connectionURL, WebDAVDirectory.sameOrigin(folder, connectionURL),
               listingCredentials?.0 == username, listingCredentials?.1 == password,
               let connectionKey { RemoteBrowserMemory.rememberDAV(folder, connection: connectionKey) }
            message = "Connection saved in Keychain. Use Save Changes after editing it."
        } catch { message = error.localizedDescription }
    }
    private func browse(force: Bool = false) {
        task?.cancel(); retry.reset(); ticket = UUID(); busy = false; message = ""
        if let listingKey { RemoteBrowserMemory.webDAV.select(selection, in: listingKey) }
        do {
            var url = try NetworkMediaRequest.parse(address, webDAV: true)
            if !url.path.hasSuffix("/") { url.appendPathComponent("") }
            let user = username, secret = password, id = UUID()
            if connectionAuth != RemoteBrowserMemory.key([user, secret]) ||
                connectionURL.map({ !WebDAVDirectory.sameOrigin($0, url) }) == true {
                connectionKey = nil; connectionAuth = nil; connectionURL = nil
            }
            let key = RemoteBrowserMemory.davKey(url, user: user, password: secret)
            let sameListing = key == listingKey
            let cached = RemoteBrowserMemory.webDAV.read(key)
            if !sameListing {
                items = cached?.items ?? []; selection = cached?.selection ?? []
                listingKey = key; folder = url; listingCredentials = (user, secret)
                restoreSelection = UUID()
            }
            if !force, let cached, cached.isFresh() {
                if let connectionKey { RemoteBrowserMemory.rememberDAV(url, connection: connectionKey) }
                message = "Recent folder listing · Refresh to check for changes."
                return
            }
            ticket = id; busy = true; operation = "Reading folder…"
            task = Task {
                do {
                    let entries = try await NetworkRequestPolicy.$retryWait.withValue({ seconds in try await retry.wait(seconds: seconds) }) {
                        try await WebDAVDirectory.read(url, username: user, password: secret)
                    }
                    guard !Task.isCancelled, ticket == id else { return }
                    items = entries; folder = url; listingCredentials = (user, secret); busy = false
                    selection.formIntersection(entries.map(\.id))
                    RemoteBrowserMemory.webDAV.store(.init(items: entries, selection: selection,
                        updated: ProcessInfo.processInfo.systemUptime), for: key)
                    if let connectionKey { RemoteBrowserMemory.rememberDAV(url, connection: connectionKey) }
                    if !sameListing { restoreSelection = UUID() }
                    if entries.isEmpty { message = "This folder has no accessible children." }
                } catch {
                    guard !Task.isCancelled, ticket == id else { return }
                    busy = false
                    // Retain visible rows on transient failures, but never reuse
                    // a rejected listing as a fresh result on the next visit.
                    RemoteBrowserMemory.webDAV.remove(key)
                    // URLSession descriptions can contain signed URLs. Display only safe detail.
                    message = NetworkMediaError.message(for: error)
                }
            }
        } catch { busy = false; message = error.localizedDescription }
    }
}


struct NetworkServerSettings: View {
    @ObservedObject var model: PlayerModel
    private let servers = NetworkServerStore.shared
    @State private var showingBrowser = false
    @State private var selected: UUID?
    @State private var message = ""
    var body: some View {
        Form {
            Section("WebDAV & Network Media") {
                Button("Open Network…", systemImage: "network") { selected = servers.lastSelected; showingBrowser = true }
                Text("Browse a WebDAV folder, play a media URL, or save a server. Connections are available from File → Open Network (⌘N).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            OneDriveSettingsSection(model: model)
            Section("Resume Network Media") {
                Toggle("Remember WebDAV & OneDrive Progress", isOn: $model.rememberNetworkProgress)
                Text("Requires Resume Videos Where You Left Off in General. Stores up to 100 file identity hashes and positions; credentials and temporary download URLs are not included. Reopen the file from its network browser to resume.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Live streams, pasted URLs, query-based WebDAV addresses and servers without file version markers are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear Saved Network Progress", systemImage: "trash") { model.clearRemotePlaybackMemory() }
                if !model.networkResumeStatus.isEmpty { Text(model.networkResumeStatus).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Streaming Cache") {
                Picker("Buffer Budget", selection: $model.networkCachePolicy) {
                    ForEach(NetworkCachePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(model.networkCachePolicy.summary).font(.caption).foregroundStyle(.secondary)
                Text("Applies when opening or reconnecting HTTP(S) media. Hidden queue items do not start metadata reads; buffering gives playback priority. RTSP keeps its existing settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Remote Folder Browsing") {
                Text("Folder listings and the last visited folder are remembered for this app session. Refresh checks the server again; quitting clears this cache. Addresses and page links are not written to preferences.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear Folder Browsing Cache", systemImage: "trash") {
                    RemoteBrowserMemory.clear(); message = "Folder browsing cache cleared."
                }
            }
            Section("Saved Servers") {
                if servers.servers.isEmpty { Text("No saved servers. Open Network and choose Save Server.").foregroundStyle(.secondary) }
                ForEach(servers.servers) { server in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(server.name)
                            Text(server.host).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open / Edit") { selected = server.id; showingBrowser = true }
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            do { try servers.remove(server.id); RemoteBrowserMemory.clear(); message = "Server and its saved Keychain record removed." }
                            catch { message = error.localizedDescription }
                        }
                    }
                }
            }
            Section("Privacy & Compatibility") {
                Text("Complete addresses, usernames and passwords are stored in your login Keychain, not plain preferences. Removing a server deletes that saved connection; it does not change files on the server or stop already queued playback.")
                Text("Use HTTPS when available. Same-origin media redirects preserve login; redirects to a different origin do not receive your credentials. Login-required HLS playlists and web-page login flows are not supported.")
            }.font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Section { Text(message).textSelection(.enabled) } }
        }.formStyle(.grouped)
        .sheet(isPresented: $showingBrowser) { NetworkMediaSheet(model: model, initialServerID: selected) }
    }
}
