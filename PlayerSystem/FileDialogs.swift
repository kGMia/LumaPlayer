// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Observation
import UniformTypeIdentifiers

extension Notification.Name {
    static let defaultBrowserFolderDidChange = Notification.Name("LumaDefaultBrowserFolderChanged")
}

/// One file operation at a time, presented by its originating window. Keep this
/// state outside PlayerModel's broad ObservableObject updates.
@MainActor @Observable final class PlayerFileDialogs {
    enum Host { case player, settings, mini }
    var activeHost: Host = .player
    private(set) var owner: Host = .player
    private(set) var operation: UUID?
    var importing = false
    var exporting = false
    private(set) var title = ""
    private(set) var types: [UTType] = [.data]
    private(set) var multiple = false
    private(set) var directory: URL?
    private(set) var filename = ""
    private(set) var document: PlayerExportDocument?
    @ObservationIgnored private var importCompletion: ((Result<[URL], Error>) -> Void)?
    @ObservationIgnored private var exportCompletion: ((Result<URL, Error>) -> Void)?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var accessedURLs: Set<URL> = []

    var isBusy: Bool { operation != nil }

    func importFiles(title: String.LocalizationValue, types: [UTType] = [.data], multiple: Bool = false,
                     directory: URL? = nil, completion: @escaping (Result<[URL], Error>) -> Void) {
        guard !isBusy else { return }
        operation = UUID(); owner = activeHost
        self.title = String(localized: title); self.types = types; self.multiple = multiple; self.directory = directory
        importCompletion = completion
        importing = true
    }

    func export(title: String.LocalizationValue, filename: String, type: UTType, directory: URL? = nil,
                load: @escaping @MainActor () async throws -> Data,
                completion: @escaping (Result<URL, Error>) -> Void) {
        guard !isBusy else { return }
        let id = UUID()
        operation = id; owner = activeHost
        self.title = String(localized: title); self.filename = filename; types = [type]; self.directory = directory
        exportCompletion = completion
        preparation = Task { @MainActor [weak self] in
            do {
                let data = try await load()
                guard let self, self.operation == id, !Task.isCancelled else { return }
                self.document = PlayerExportDocument(data: data)
                self.preparation = nil
                self.exporting = true
            } catch {
                guard let self, self.operation == id, !Task.isCancelled else { return }
                self.finishExport(.failure(error), operation: id)
            }
        }
    }

    func finishImport(_ result: Result<[URL], Error>, operation id: UUID?) {
        guard let id, operation == id, let completion = importCompletion else { return }
        // mpv consumes paths asynchronously, including items queued for later.
        // Keep granted scopes until the player session closes, not just this callback.
        if case .success(let urls) = result {
            for url in urls where !accessedURLs.contains(url) {
                if url.startAccessingSecurityScopedResource() { accessedURLs.insert(url) }
            }
        }
        reset()
        completion(result)
    }

    func finishExport(_ result: Result<URL, Error>, operation id: UUID?) {
        guard let id, operation == id, let completion = exportCompletion else { return }
        if case .success(let url) = result, !accessedURLs.contains(url), url.startAccessingSecurityScopedResource() {
            accessedURLs.insert(url)
        }
        reset()
        completion(result)
    }

    func cancel(for host: Host) {
        guard owner == host else { return }
        reset()
    }

    func saveDefaultBrowserFolder(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: "browser.defaultFolderBookmark")
        UserDefaults.standard.set(url.path, forKey: "browser.defaultFolderPath")
        NotificationCenter.default.post(name: .defaultBrowserFolderDidChange, object: nil)
    }

    func restoreDefaultBrowserFolder() throws -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "browser.defaultFolderBookmark") else { return nil }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        // Reuse an existing scope; each successful start is paired with shutdown.
        if !accessedURLs.contains(url), url.startAccessingSecurityScopedResource() { accessedURLs.insert(url) }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw CocoaError(.fileReadNoPermission) }
        if stale { try saveDefaultBrowserFolder(url) }
        return url
    }

    func clearDefaultBrowserFolder() {
        UserDefaults.standard.removeObject(forKey: "browser.defaultFolderBookmark")
        UserDefaults.standard.removeObject(forKey: "browser.defaultFolderPath")
        NotificationCenter.default.post(name: .defaultBrowserFolderDidChange, object: nil)
        // Keep any active playback scope alive until session shutdown.
    }

    func shutdown() {
        reset()
        for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
        accessedURLs.removeAll()
    }

    private func reset() {
        preparation?.cancel(); preparation = nil
        importing = false; exporting = false
        operation = nil; document = nil
        importCompletion = nil; exportCompletion = nil
    }
}

/// Immutable bytes captured before showing the save dialog. SwiftUI owns the
/// replacement confirmation and file write; a canceled export never touches its destination.
struct PlayerExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct PlayerFileDialogPresenter: ViewModifier {
    @Bindable var dialogs: PlayerFileDialogs
    let host: PlayerFileDialogs.Host
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        let id = dialogs.operation
        let importPresented = Binding(get: { dialogs.owner == host && dialogs.importing },
            set: { if dialogs.owner == host && dialogs.operation == id { dialogs.importing = $0 } })
        let exportPresented = Binding(get: { dialogs.owner == host && dialogs.exporting },
            set: { if dialogs.owner == host && dialogs.operation == id { dialogs.exporting = $0 } })
        content
            .fileImporter(isPresented: importPresented, allowedContentTypes: dialogs.types,
                          allowsMultipleSelection: dialogs.multiple,
                          onCompletion: { dialogs.finishImport($0, operation: id) },
                          onCancellation: { if dialogs.operation == id { dialogs.cancel(for: host) } })
            .fileExporter(isPresented: exportPresented, document: dialogs.document,
                          contentTypes: dialogs.types, defaultFilename: dialogs.filename,
                          onCompletion: { dialogs.finishExport($0, operation: id) },
                          onCancellation: { if dialogs.operation == id { dialogs.cancel(for: host) } })
            .fileDialogConfirmationLabel(dialogs.exporting ? String(localized: "Save") : dialogs.types == [.folder] ? String(localized: "Choose Folder") : String(localized: "Open"))
            .fileDialogMessage(dialogs.title)
            .fileDialogDefaultDirectory(dialogs.directory)
            .fileDialogCustomizationID(dialogs.exporting ? "luma.export" : dialogs.types == [.folder] ? "luma.folder" : "luma.open")
            .onChange(of: activeState, initial: true) { _, state in
                if state == .key { dialogs.activeHost = host }
            }
            .onDisappear {
                dialogs.cancel(for: host)
                if dialogs.activeHost == host { dialogs.activeHost = .player }
            }
    }
}

extension View {
    func playerFileDialogs(_ dialogs: PlayerFileDialogs, host: PlayerFileDialogs.Host) -> some View {
        modifier(PlayerFileDialogPresenter(dialogs: dialogs, host: host))
    }
}
