// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct OnlineMovieSettings: View {
    @ObservedObject private var library = OnlineMovieLibrary.shared
    @State private var token = ""
    @State private var message = ""
    var body: some View {
        Section("Online Movie Information") {
            Toggle("Enable online movie information", isOn: $library.enabled)
            Text("Searches only when requested. Sends the edited title, year and episode numbers to TMDB; duration is compared locally. Turning this off hides online information and cancels searches. NFO and embedded metadata take priority.")
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
            Button("Clear Poster Cache") {
                Task {
                    await OnlinePosterCache.shared.clear()
                    OnlineSummaryArtwork.clearCache()
                    message = String(localized: "Poster cache cleared.")
                }
            }
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
    @State private var showBatch = false
    @State private var showMatch = false
    var body: some View {
        if library.enabled {
            HStack(spacing: 8) {
                Button("Find Movie or TV Information…", systemImage: "magnifyingglass") { showSearch = true }
                    .labelStyle(.iconOnly)
                    .help("Find Movie or TV Information…")
                    .disabled(!model.loaded || !model.hasMotionVideo || !model.path.hasPrefix("/"))
                if let movie = library.movie(for: model.path) {
                    Link("TMDB · \(movie.title)", destination: movie.detailsURL)
                        .font(.caption).lineLimit(1).truncationMode(.tail)
                        .help(movie.title)
                } else {
                    Text("TMDB").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let movie = library.movie(for: model.path) {
                    Menu {
                        Button("View Match…", systemImage: "info.circle") { showMatch = true }
                        Button("Change Match…", systemImage: "magnifyingglass") { showSearch = true }
                        if movie.seriesID != nil {
                            Button("Batch Match Episodes…", systemImage: "rectangle.stack.badge.plus") { showBatch = true }
                                .disabled(MovieFilenameQuery.episode(URL(fileURLWithPath: model.path).lastPathComponent) == nil)
                        }
                        Button("Remove Match", systemImage: "xmark.circle") { library.remove(model.path) }
                    } label: { Label("More", systemImage: "ellipsis") }
                    .labelStyle(.iconOnly).menuIndicator(.hidden).fixedSize()
                }
            }.controlSize(.small)
            .task(id: "\(model.path)|\((model.snapshot["media-epoch"] as? NSNumber)?.uint64Value ?? 0)") { await library.validate(model.path) }
            .popover(isPresented: $showMatch) {
                if let movie = library.movie(for: model.path) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Online Match").font(.headline)
                        Text(movie.title).font(.body.weight(.medium)).textSelection(.enabled)
                        if let original = movie.originalTitle { Text(original).font(.caption).foregroundStyle(.secondary) }
                        if let season = movie.seasonNumber, let episode = movie.episodeNumber {
                            Text(String(format: "S%02dE%02d", season, episode)).monospaced()
                        }
                        Link("Source: TMDB", destination: movie.detailsURL)
                        Text("Local NFO and embedded metadata take priority. Removing a match does not change your files.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(16).frame(width: 300)
                }
            }
            .sheet(isPresented: $showSearch) {
                OnlineMovieSearchView(path: model.path, seconds: model.duration)
            }
            .sheet(isPresented: $showBatch) {
                if let movie = library.movie(for: model.path) {
                    OnlineEpisodeBatchView(anchorPath: model.path, anchor: movie, queuePaths: model.queue.map(\.filename))
                }
            }
            .onChange(of: model.path) { showSearch = false; showBatch = false; showMatch = false }
            .onChange(of: library.enabled) { if !library.enabled { showSearch = false; showBatch = false; showMatch = false } }
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
    @State private var isEpisode = false
    @State private var season = "1"
    @State private var episode = "1"
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
        if let item = MovieFilenameQuery.episode(URL(fileURLWithPath: path).lastPathComponent) {
            _title = State(initialValue: item.title); _isEpisode = State(initialValue: true)
            _season = State(initialValue: String(item.season)); _episode = State(initialValue: String(item.episode))
        }
        if let match = OnlineMovieLibrary.shared.movie(for: path) {
            _title = State(initialValue: match.seriesTitle ?? (match.seriesID == nil ? match.title : match.title.components(separatedBy: " · ").first ?? match.title))
            _year = State(initialValue: match.seriesID == nil ? match.year : String((match.seriesFirstAirDate ?? "").prefix(4)))
            _isEpisode = State(initialValue: match.seriesID != nil)
            if let value = match.seasonNumber { _season = State(initialValue: String(value)) }
            if let value = match.episodeNumber { _episode = State(initialValue: String(value)) }
        }
        let preferred = Locale.preferredLanguages.first ?? "en"
        let savedLanguage = UserDefaults.standard.string(forKey: "onlineMovieMetadata.language")
        _language = State(initialValue: savedLanguage ?? (preferred.hasPrefix("zh") ? (preferred.contains("Hant") || preferred.contains("TW") ? "zh-TW" : "zh-CN") : "en-US"))
    }
    private var queryIdentity: String { "\(title)|\(year)|\(language)|\(isEpisode)|\(season)|\(episode)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find Movie or TV Information…").font(.title2.bold())
            Text("Review the title and runtime before applying. For episodes, enter the series title, premiere year, season and episode. Special episodes use season 0.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Media Type", selection: $isEpisode) {
                    Text("Movie").tag(false)
                    Text("TV Episode").tag(true)
                }.pickerStyle(.segmented).frame(width: 230)
                if isEpisode {
                    TextField("Season", text: $season).frame(width: 90)
                    TextField("Episode", text: $episode).frame(width: 90)
                }
            }.disabled(busy)
            HStack {
                TextField("Title", text: $title)
                TextField("Year", text: $year).frame(width: 70)
                Picker("Language", selection: $language) {
                    Text("English").tag("en-US"); Text("简体中文").tag("zh-CN"); Text("繁體中文（台灣）").tag("zh-TW")
                }.frame(width: 150)
                Button("Search", action: search).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.disabled(busy).onSubmit { if !busy { search() } }
            if busy { ProgressView("Searching TMDB…").controlSize(.small) }
            if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if !busy && results.isEmpty && !status.isEmpty && !year.isEmpty {
                Button("Search Without Year") { year = ""; search() }
            }
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
        .onChange(of: queryIdentity) {
            if !busy { results = []; stamp = nil; status = "" }
        }
        .onDisappear { task?.cancel() }
        .onChange(of: library.enabled) { if !library.enabled { task?.cancel(); dismiss() } }
    }
    private func search() {
        guard !busy else { return }
        UserDefaults.standard.set(language, forKey: "onlineMovieMetadata.language")
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let year = year.trimmingCharacters(in: .whitespacesAndNewlines)
        guard library.enabled, !query.isEmpty, query.count <= 200,
              year.isEmpty || year.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil else {
            status = String(localized: "Enter a movie title and an optional four-digit year."); return
        }
        let seasonValue = Int(season), episodeValue = Int(episode)
        guard !isEpisode || (seasonValue.map { (0...99).contains($0) } == true && episodeValue.map { (1...999).contains($0) } == true) else {
            status = String(localized: "Enter season 0–99 and episode 1–999."); return
        }
        let searchEpisode = isEpisode
        task?.cancel(); results = []; stamp = nil; status = ""; busy = true
        let language = language
        task = Task {
            let initialStamp = await Task.detached(priority: .utility) { PlaybackFileStamp.read(path) }.value
            do {
                guard let initialStamp else { throw MovieMetadataError(message: String(localized: "The local media file is unavailable.")) }
                let movies: [OnlineMovie]
                if searchEpisode, let seasonValue, let episodeValue {
                    movies = try await OnlineMovieAPI.shared.searchEpisodes(title: query, year: year, season: seasonValue, episode: episodeValue, seconds: seconds, language: language)
                } else {
                    movies = try await OnlineMovieAPI.shared.search(title: query, year: year, seconds: seconds, language: language)
                }
                try Task.checkCancellation()
                guard library.enabled else { return }
                stamp = initialStamp; results = movies; busy = false
                if movies.isEmpty { status = String(localized: "No matching candidates found. Check the title, year and episode numbers.") }
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

/// Shared decoded/disk cache; downloads never receive the API credential.
struct OnlineMoviePoster: View {
    let url: URL
    @ObservedObject private var library = OnlineMovieLibrary.shared
    @State private var image: CGImage?
    @State private var failed = false
    @State private var attempt = 0
    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    .overlay {
                        if failed {
                            Button("Retry", systemImage: "arrow.clockwise") { attempt += 1 }
                                .labelStyle(.iconOnly).buttonStyle(.plain).help("Retry")
                        } else { ProgressView().controlSize(.small) }
                    }
                    .aspectRatio(2 / 3, contentMode: .fit)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: "\(url.absoluteString)|\(attempt)|\(library.enabled)") {
            image = nil; failed = false
            guard library.enabled else { return }
            let result = await OnlinePosterCache.shared.image(for: url)
            guard !Task.isCancelled, library.enabled else { return }
            image = result; failed = result == nil
        }
    }
}

/// Both summary presentations share the same artwork precedence and theme source.
@MainActor final class OnlineSummaryArtwork: ObservableObject {
    private struct Entry { let image: NSImage; let theme: MediaArtworkTheme?; let bytes: Int }
    private static var cache: [String: Entry] = [:]
    private static var order: [String] = []
    @Published private var revision = 0
    private var failedIdentity: String?
    private var generation = 0
    private static func key(_ path: String, _ url: URL) -> String { path + "|" + url.absoluteString }
    private func entry(path: String, url: URL?) -> Entry? {
        guard let url, QueueMetadataCache.cachedDedicatedArtwork(path).image == nil else { return nil }
        return Self.cache[Self.key(path, url)]
    }
    func image(for path: String, url: URL?) -> NSImage? { entry(path: path, url: url)?.image }
    func theme(for path: String, url: URL?) -> MediaArtworkTheme? { entry(path: path, url: url)?.theme }
    func awaitingImage(path: String, url: URL?) -> Bool {
        guard let url, QueueMetadataCache.cachedDedicatedArtwork(path).image == nil else { return false }
        return entry(path: path, url: url) == nil && failedIdentity != Self.key(path, url)
    }
    func load(path: String, url: URL?) async {
        generation += 1
        let ticket = generation
        guard let url, !path.isEmpty else { revision += 1; return }
        let identity = Self.key(path, url)
        // A revisited card renders synchronously from the bounded presentation cache.
        if Self.cache[identity] != nil {
            Self.order.removeAll { $0 == identity }; Self.order.append(identity)
            revision += 1; return
        }
        let local = await Task.detached(priority: .utility) { QueueMetadataCache.detailArtwork(path) }.value
        guard !Task.isCancelled, ticket == generation else { return }
        if local != nil { revision += 1; return }
        guard let pixels = await OnlinePosterCache.shared.image(for: url) else {
            if !Task.isCancelled, ticket == generation { failedIdentity = identity; revision += 1 }
            return
        }
        guard !Task.isCancelled, ticket == generation else { return }
        let resolved = await Task.detached(priority: .utility) {
            let image = NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height))
            return (image, MediaArtworkTheme.resolve(for: url.absoluteString, image: image))
        }.value
        guard !Task.isCancelled, ticket == generation else { return }
        Self.cache[identity] = Entry(image: resolved.0, theme: resolved.1, bytes: pixels.bytesPerRow * pixels.height)
        Self.order.removeAll { $0 == identity }; Self.order.append(identity)
        var cost = Self.cache.values.reduce(0) { $0 + $1.bytes }
        while Self.order.count > 32 || cost > 32 * 1024 * 1024 {
            let oldest = Self.order.removeFirst()
            cost -= Self.cache.removeValue(forKey: oldest)?.bytes ?? 0
        }
        failedIdentity = nil; revision += 1
    }
    static func clearCache() { cache.removeAll(); order.removeAll() }
}
