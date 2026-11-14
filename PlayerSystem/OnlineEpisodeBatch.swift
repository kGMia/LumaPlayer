// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

struct OnlineEpisodeBatchView: View {
    let anchorPath: String
    let anchor: OnlineMovie
    let queuePaths: [String]
    @ObservedObject private var library = OnlineMovieLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var files: [EpisodeBatchFile] = []
    @State private var selected: Set<String> = []
    @State private var results: [String: OnlineMovie] = [:]
    @State private var stamps: [String: PlaybackFileStamp] = [:]
    @State private var notes: [String: String] = [:]
    @State private var status = ""
    @State private var completed = 0
    @State private var total = 0
    @State private var busy = false
    @State private var language: String = {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? (preferred.contains("Hant") || preferred.contains("TW") || preferred.contains("HK") ? "zh-TW" : "zh-CN") : "en-US"
    }()
    @State private var task: Task<Void, Never>?
    @State private var choosingFiles = false
    @State private var scopedURLs: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Batch Match Episodes…").font(.title2.bold())
            Text(anchor.title).font(.headline).textSelection(.enabled)
            Text("Uses the confirmed series for matching filenames in this folder and queue. Review each result before applying. Existing matches start unchecked. Up to 50 files per batch.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Add Files…", systemImage: "plus") { choosingFiles = true }
                Button("Select All") { selected = Set(files.map(\.path)) }
                Button("Deselect All") { selected = [] }
                Spacer()
                Picker("Language", selection: $language) {
                    Text("English").tag("en-US")
                    Text("简体中文").tag("zh-CN")
                    Text("繁體中文（台灣）").tag("zh-TW")
                }.frame(width: 180)
            }.disabled(busy)
            List(files) { file in
                HStack(alignment: .top) {
                    Toggle(isOn: Binding(get: { selected.contains(file.path) }, set: { checked in
                        if checked { selected.insert(file.path) } else { selected.remove(file.path) }
                    })) { EmptyView() }.labelsHidden().accessibilityLabel(URL(fileURLWithPath: file.path).lastPathComponent).disabled(busy)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(URL(fileURLWithPath: file.path).lastPathComponent).lineLimit(2)
                            .help(file.path)
                        Text(String(format: "S%02dE%02d", file.key.season, file.key.episode))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let movie = results[file.path] {
                            Label("Ready to Apply", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                            Text(movie.title).font(.callout).textSelection(.enabled)
                            if let runtime = movie.runtime { Text("\(runtime) min").font(.caption).foregroundStyle(.secondary) }
                        } else if let note = notes[file.path] {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        } else if library.hasSavedMatch(file.path) {
                            Text("Already matched").font(.caption).foregroundStyle(.secondary)
                        } else { Text("Not Searched").font(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(.vertical, 4)
            }
            if files.isEmpty && !busy {
                Text("No matching episode files. Add local files with the same series title and explicit season/episode numbers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if busy { ProgressView(value: Double(completed), total: Double(max(total, 1))) }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button("Search Selected") { search() }.disabled(busy || selected.isEmpty)
                if !results.isEmpty || !notes.isEmpty {
                    Button("Retry Remaining") { search(remainingOnly: true) }
                        .disabled(busy || !selected.contains(where: { results[$0] == nil }))
                }
                Button("Apply Selected Results", action: apply).disabled(busy || !selected.contains(where: { results[$0] != nil }))
                Spacer()
                if busy { Button("Cancel") {
                    task?.cancel(); busy = false
                    for file in files where selected.contains(file.path) && results[file.path] == nil && notes[file.path] == nil {
                        notes[file.path] = String(localized: "Canceled")
                    }
                } }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 760, height: 570)
        .task { await discover() }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.movie, .video, .data], allowsMultipleSelection: true) { result in
            do {
                let urls = try result.get()
                for url in urls where url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
                merge(urls.map(\.path))
            } catch { status = error.localizedDescription }
        }
        .onChange(of: library.enabled) { if !library.enabled { task?.cancel(); dismiss() } }
        .onDisappear {
            task?.cancel()
            for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
            scopedURLs = []
        }
    }

    private func discover() async {
        let directory = URL(fileURLWithPath: anchorPath).deletingLastPathComponent()
        let paths = await Task.detached(priority: .utility) {
            // A single directory only; no recursive metadata probing or decoder work.
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).prefix(2000).map(\.path)
        }.value
        guard !Task.isCancelled else { return }
        merge(queuePaths.filter { URL(fileURLWithPath: $0).deletingLastPathComponent() == directory } + paths + [anchorPath])
    }
    private func merge(_ paths: [String]) {
        let previous = Set(files.map(\.path))
        let all = EpisodeBatchFile.candidates(paths: files.map(\.path) + paths, anchor: anchorPath)
        let prioritized = all.filter { !library.hasSavedMatch($0.path) } + all.filter { library.hasSavedMatch($0.path) }
        files = Array(prioritized.prefix(50))
        selected.formUnion(files.filter { !previous.contains($0.path) && !library.hasSavedMatch($0.path) }.map(\.path))
        selected.formIntersection(Set(files.map(\.path)))
        if all.count > 50 { status = String(localized: "Showing the first 50 matching files. Process additional episodes in a later batch.") }
    }
    private func search(remainingOnly: Bool = false) {
        guard library.enabled, let seriesID = anchor.seriesID else { return }
        let work = files.filter { selected.contains($0.path) && (!remainingOnly || results[$0.path] == nil) }
        task?.cancel(); busy = true; completed = 0; total = work.count; status = ""
        for file in work { results[file.path] = nil; stamps[file.path] = nil; notes[file.path] = nil }
        let language = language
        task = Task {
            let observed = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: work.compactMap { file in PlaybackFileStamp.read(file.path).map { (file.path, $0) } })
            }.value
            guard !Task.isCancelled, library.enabled else { return }
            let valid = work.filter { observed[$0.path] != nil }
            for file in work where observed[file.path] == nil {
                notes[file.path] = String(localized: "The local media file is unavailable."); completed += 1
            }
            do {
                if !valid.isEmpty {
                    try await OnlineMovieAPI.shared.resolveBatch(seriesID: seriesID, episodes: valid.map(\.key), language: language) { key, movie in
                        guard !Task.isCancelled, library.enabled else { return }
                        for file in valid where file.key == key {
                            results[file.path] = movie; stamps[file.path] = observed[file.path]
                            if movie == nil { notes[file.path] = String(localized: "Episode not found in this series.") }
                            completed += 1
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                status = String(localized: "Search finished. Review the results, then apply selected matches.")
            } catch {
                guard !Task.isCancelled else { return }
                status = error.localizedDescription
                for file in valid where results[file.path] == nil && notes[file.path] == nil {
                    notes[file.path] = String(localized: "Search interrupted. Retry remaining items.")
                }
            }
            busy = false
        }
    }
    private func apply() {
        let pending = files.compactMap { file -> (String, PlaybackFileStamp, OnlineMovie)? in
            guard selected.contains(file.path), let movie = results[file.path], let stamp = stamps[file.path] else { return nil }
            return (file.path, stamp, movie)
        }
        guard library.enabled, !pending.isEmpty else { return }
        task?.cancel(); busy = true
        task = Task {
            let valid = await Task.detached(priority: .utility) {
                pending.filter { PlaybackFileStamp.read($0.0) == $0.1 }
            }.value
            guard !Task.isCancelled, library.enabled else { return }
            library.confirmBatch(valid) // One preferences write for the entire batch.
            let saved = Set(valid.map { $0.0 })
            for (path, _, _) in pending {
                if saved.contains(path) { selected.remove(path); results[path] = nil }
                else {
                    notes[path] = String(localized: "The file changed. Search again before applying a match.")
                    results[path] = nil; stamps[path] = nil
                }
            }
            status = String(localized: "Applied \(valid.count) matches; skipped \(pending.count - valid.count) changed files.")
            busy = false
        }
    }
}
