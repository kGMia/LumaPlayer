// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct OnlineMovieSettings: View {
    @ObservedObject private var library = OnlineMovieLibrary.shared
    @State private var token = ""
    @State private var message = ""
    var body: some View {
        Section("Online Movie Information") {
            Toggle("Enable online movie information", isOn: $library.enabled)
            Text("Searches only when requested. Sends the edited movie title and year to TMDB; duration is compared locally. Turning this off hides online information and cancels searches. NFO and embedded metadata take priority.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("TMDB Read Access Token", text: $token)
            HStack {
                Button("Save Token") {
                    do { try MovieMetadataToken.save(token); token = ""; message = String(localized: "Token saved in Keychain.") }
                    catch { message = error.localizedDescription }
                }.disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove Token") {
                    do { try MovieMetadataToken.remove(); library.enabled = false; message = String(localized: "Token removed.") }
                    catch { message = error.localizedDescription }
                }
                Link("Get API Access", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
            }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            Button("Clear Online Matches") { library.clear() }
            DisclosureGroup("Credits · TMDB") {
                Image("TMDBLogo").resizable().scaledToFit().frame(width: 110, height: 36).accessibilityLabel("TMDB")
                Link("The Movie Database", destination: URL(string: "https://www.themoviedb.org")!)
                Text(verbatim: "This product uses the TMDB API but is not endorsed or certified by TMDB.").font(.caption)
            }
        }
    }
}

struct OnlineMovieControls: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject private var library = OnlineMovieLibrary.shared
    @State private var showSearch = false
    var body: some View {
        if library.enabled {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Find Movie Information…", systemImage: "magnifyingglass") { showSearch = true }
                        .disabled(!model.loaded || !model.hasMotionVideo || !model.path.hasPrefix("/"))
                    if library.movie(for: model.path) != nil {
                        Button("Remove Match", systemImage: "xmark.circle") { library.remove(model.path) }.labelStyle(.iconOnly)
                    }
                }
                if let movie = library.movie(for: model.path) {
                    Link("TMDB · \(movie.title)", destination: URL(string: "https://www.themoviedb.org/movie/\(movie.id)")!).font(.caption)
                }
            }
            .task(id: "\(model.path)|\((model.snapshot["media-epoch"] as? NSNumber)?.uint64Value ?? 0)") { await library.validate(model.path) }
            .sheet(isPresented: $showSearch) {
                OnlineMovieSearchView(path: model.path, seconds: model.duration)
            }
            .onChange(of: model.path) { showSearch = false }
            .onChange(of: library.enabled) { if !library.enabled { showSearch = false } }
        }
    }
}

private struct OnlineMovieSearchView: View {
    let path: String
    let seconds: Double
    @ObservedObject private var library = OnlineMovieLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var year: String
    @State private var language = "en-US"
    @State private var results: [OnlineMovie] = []
    @State private var status = ""
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var stamp: PlaybackFileStamp?
    init(path: String, seconds: Double) {
        self.path = path; self.seconds = seconds
        let parsed = MovieFilenameQuery.parse(URL(fileURLWithPath: path).lastPathComponent)
        _title = State(initialValue: parsed.title); _year = State(initialValue: parsed.year ?? "")
        let preferred = Locale.preferredLanguages.first ?? "en"
        _language = State(initialValue: preferred.hasPrefix("zh") ? (preferred.contains("Hant") || preferred.contains("TW") ? "zh-TW" : "zh-CN") : "en-US")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find Movie Information…").font(.title2.bold())
            Text("Movie matching uses filename and runtime. Review candidates before applying; different cuts may have different runtimes. TV episodes are not matched in this version.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Movie Title", text: $title)
                TextField("Year", text: $year).frame(width: 70)
                Picker("Language", selection: $language) {
                    Text("English").tag("en-US"); Text("简体中文").tag("zh-CN"); Text("繁體中文（台灣）").tag("zh-TW")
                }.frame(width: 150)
                Button("Search", action: search).disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if busy { ProgressView("Searching TMDB…").controlSize(.small) }
            if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if seconds.isFinite && seconds > 0 { Text("Local duration: \(Int(seconds / 60)) min").font(.caption).foregroundStyle(.secondary) }
            List(results) { movie in
                HStack(alignment: .top, spacing: 12) {
                    if let url = movie.posterURL {
                        OnlineMoviePoster(url: url).frame(width: 64, height: 96).clipped()
                    }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(movie.title).font(.headline)
                        Text(movie.year).foregroundStyle(.secondary)
                        Spacer()
                        Button("Use This Match") { confirm(movie) }.disabled(busy || stamp == nil)
                    }
                    if let original = movie.originalTitle, original != movie.title { Text(original).font(.caption).foregroundStyle(.secondary) }
                    if let runtime = movie.runtime, runtime > 0 {
                        if let difference = movie.durationDifference(seconds) { Text("\(runtime) min · difference \(Int(difference.rounded())) min").font(.caption) }
                        else { Text("\(runtime) min").font(.caption) }
                    } else { Text("Runtime unavailable").font(.caption).foregroundStyle(.secondary) }
                    if let overview = movie.overview, !overview.isEmpty {
                        DisclosureGroup { Text(overview).font(.caption).textSelection(.enabled) } label: {
                            Text(overview).font(.caption).lineLimit(2)
                        }
                    }
                }
                }.padding(.vertical, 6)
            }
            HStack {
                Link("Data: TMDB", destination: URL(string: "https://www.themoviedb.org")!).font(.caption)
                Spacer()
                if busy { Button("Cancel Search") { task?.cancel(); busy = false; status = "" } }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 720, height: 520)
        .onDisappear { task?.cancel() }
        .onChange(of: library.enabled) { if !library.enabled { task?.cancel(); dismiss() } }
    }
    private func search() {
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let year = year.trimmingCharacters(in: .whitespacesAndNewlines)
        guard library.enabled, query.count <= 200,
              year.isEmpty || year.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil else {
            status = String(localized: "Enter a movie title and an optional four-digit year."); return
        }
        task?.cancel(); results = []; stamp = nil; status = ""; busy = true
        let language = language
        task = Task {
            let initialStamp = await Task.detached(priority: .utility) { PlaybackFileStamp.read(path) }.value
            do {
                guard let initialStamp else { throw MovieMetadataError(message: String(localized: "The local media file is unavailable.")) }
                let movies = try await OnlineMovieAPI.shared.search(title: query, year: year, seconds: seconds, language: language)
                try Task.checkCancellation()
                guard library.enabled else { return }
                stamp = initialStamp; results = movies; busy = false
                if movies.isEmpty { status = String(localized: "No movie candidates found. Try editing the title or clearing the year.") }
            } catch {
                guard !Task.isCancelled else { return }
                status = error.localizedDescription; busy = false
            }
        }
    }
    private func confirm(_ movie: OnlineMovie) {
        guard let stamp, library.enabled else { return }
        task?.cancel(); busy = true
        task = Task {
            let current = await Task.detached(priority: .utility) { PlaybackFileStamp.read(path) }.value
            guard !Task.isCancelled, library.enabled else { return }
            guard current == stamp else { busy = false; status = String(localized: "The file changed. Search again before applying a match."); return }
            library.confirm(movie, path: path, stamp: stamp); dismiss()
        }
    }
}

/// Native asynchronous loading; image requests never receive the API credential.
struct OnlineMoviePoster: View {
    let url: URL
    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    .overlay { Image(systemName: "film").foregroundStyle(.secondary) }
                    .aspectRatio(2 / 3, contentMode: .fit)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
