// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine
import Security
import CryptoKit

struct OnlineMovie: Codable, Identifiable, Sendable {
    struct Named: Codable, Sendable { let name: String }
    struct Person: Codable, Sendable { let name: String; let job: String? }
    struct Credits: Codable, Sendable { let cast: [Person]; let crew: [Person] }
    let id: Int
    let title: String
    let originalTitle: String?
    let releaseDate: String?
    let overview: String?
    let runtime: Int?
    let genres: [Named]?
    let credits: Credits?
    var seriesTitle: String? = nil
    var seriesFirstAirDate: String? = nil
    var seriesID: Int? = nil
    var seasonNumber: Int? = nil
    var episodeNumber: Int? = nil
    var detailsURL: URL {
        if let seriesID, let seasonNumber, let episodeNumber {
            return URL(string: "https://www.themoviedb.org/tv/\(seriesID)/season/\(seasonNumber)/episode/\(episodeNumber)")!
        }
        return URL(string: "https://www.themoviedb.org/movie/\(id)")!
    }
    var posterPath: String? = nil
    var productionCompanies: [Named]? = nil
    var posterURL: URL? {
        guard let posterPath, posterPath.range(of: #"^/[A-Za-z0-9_-]+\.(jpg|png)$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500" + posterPath)
    }
    func searchHint(_ query: String) -> String? {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return nil }
        let fields: [(String, [String])] = [
            (String(localized: "Matched Title"), [title, originalTitle ?? "", seriesTitle ?? ""]),
            (String(localized: "Matched Cast or Crew"), (credits?.cast ?? []).map(\.name) + (credits?.crew ?? []).map(\.name)),
            (String(localized: "Matched Genre or Studio"), (genres ?? []).map(\.name) + (productionCompanies ?? []).map(\.name)),
            (String(localized: "Matched Overview"), [overview ?? ""])
        ]
        for (label, values) in fields {
            if let value = values.first(where: { value in words.contains(where: { value.localizedStandardContains($0) }) }) {
                return label + " · " + value
            }
        }
        return nil
    }
    var searchableText: String {
        let names = (genres ?? []).map(\.name) + (productionCompanies ?? []).map(\.name)
        let people = (credits?.cast ?? []).map(\.name) + (credits?.crew ?? []).map(\.name)
        let episode = seasonNumber.flatMap { season in episodeNumber.map { String(format: "S%02dE%02d", season, $0) } } ?? ""
        return ([title, originalTitle ?? "", seriesTitle ?? "", releaseDate ?? "", seriesFirstAirDate ?? "", overview ?? "", episode] + names + people)
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
    var year: String { String((releaseDate ?? "").prefix(4)) }
    func durationDifference(_ seconds: Double) -> Double? {
        guard seconds.isFinite, seconds > 0, let runtime, runtime > 0 else { return nil }
        return abs(Double(runtime) - seconds / 60)
    }
}

/// Filename/year create a query; duration only ranks returned candidates locally.
/// No file bytes, directories, URLs or exact duration are uploaded.
enum MovieFilenameQuery {
    static func episode(_ filename: String) -> (title: String, season: Int, episode: Int)? {
        let stem = (filename as NSString).deletingPathExtension
        // Require explicit season and episode. Do not guess absolute episode numbers.
        let pattern = #"(?i)(?:^|[ ._\-])(?:s(\d{1,2})[ ._\-]*e(\d{1,3})|(\d{1,2})x(\d{1,3}))(?!\d|[ ._\-]*[eE]\d|\s*-\s*\d{1,3}(?:\D|$))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
              let full = Range(match.range, in: stem) else { return nil }
        func number(_ index: Int) -> Int? { Range(match.range(at: index), in: stem).flatMap { Int(stem[$0]) } }
        guard let season = number(1) ?? number(3), let episode = number(2) ?? number(4), episode > 0 else { return nil }
        let title = parse(String(stem[..<full.lowerBound]) + ".mkv").title
        guard !title.isEmpty else { return nil }
        return (title, season, episode)
    }
    static func parse(_ filename: String) -> (title: String, year: String?) {
        var title = (filename as NSString).deletingPathExtension.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        let matches = (try? NSRegularExpression(pattern: #"\b(?:19|20)\d{2}\b"#))?.matches(in: title, range: NSRange(title.startIndex..., in: title)) ?? []
        let yearRange = matches.reversed().compactMap { Range($0.range, in: title) }.first { range in
            range.lowerBound != title.startIndex && (Int(title[range]) ?? Int.max) <= Calendar.current.component(.year, from: Date()) + 1
        }
        let year = yearRange.map { String(title[$0]) }
        if let yearRange { title = String(title[..<yearRange.lowerBound]) }
        if let technical = title.range(of: #"(?i)\b(?:2160p|1080p|720p|480p|bluray|blu-ray|web-dl|webrip|hdtv|remux|x264|x265|h264|h265|hevc)\b"#, options: .regularExpression) { title = String(title[..<technical.lowerBound]) }
        title = title.replacingOccurrences(of: #"[\[\](){}]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, year)
    }
    static func ordered(_ movies: [OnlineMovie], seconds: Double) -> [OnlineMovie] {
        movies.enumerated().sorted {
            let a = $0.element.durationDifference(seconds) ?? .infinity, b = $1.element.durationDifference(seconds) ?? .infinity
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }
}

struct EpisodeBatchKey: Hashable, Comparable, Sendable {
    let season: Int
    let episode: Int
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.season == rhs.season ? lhs.episode < rhs.episode : lhs.season < rhs.season
    }
}

struct EpisodeBatchFile: Identifiable, Sendable {
    let path: String
    let key: EpisodeBatchKey
    var id: String { path }
    static func candidates(paths: [String], anchor: String) -> [Self] {
        guard let reference = MovieFilenameQuery.episode(URL(fileURLWithPath: anchor).lastPathComponent) else { return [] }
        func normalized(_ title: String) -> String {
            title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .components(separatedBy: .alphanumerics.inverted).joined()
        }
        let referenceYear = MovieFilenameQuery.parse(URL(fileURLWithPath: anchor).lastPathComponent).year
        let videoExtensions: Set<String> = ["mkv", "mp4", "mov", "m4v", "avi", "webm", "ts", "m2ts", "mpg", "mpeg", "wmv"]
        return Set(paths).compactMap { path -> Self? in
            let url = URL(fileURLWithPath: path)
            guard path.hasPrefix("/"), videoExtensions.contains(url.pathExtension.lowercased()),
                  let parsed = MovieFilenameQuery.episode(url.lastPathComponent),
                  normalized(parsed.title) == normalized(reference.title) else { return nil }
            if let referenceYear, let year = MovieFilenameQuery.parse(url.lastPathComponent).year, year != referenceYear { return nil }
            return Self(path: path, key: EpisodeBatchKey(season: parsed.season, episode: parsed.episode))
        }.sorted { $0.key == $1.key ? $0.path < $1.path : $0.key < $1.key }
    }
}

struct OnlineSeriesSummary: Sendable {
    let title: String
    let posterURL: URL?
    let details: String
    let matchedFiles: Int
    static func resolve(_ movies: [OnlineMovie]) -> Self? {
        guard let first = movies.first, let seriesID = first.seriesID,
              movies.allSatisfy({ $0.seriesID == seriesID }) else { return nil }
        let title = first.seriesTitle ?? first.title.components(separatedBy: " · ").first ?? first.title
        let seasons = Set(movies.compactMap(\.seasonNumber)).sorted().map { String(format: "S%02d", $0) }.joined(separator: " / ")
        let year = first.seriesFirstAirDate.map { String($0.prefix(4)) } ?? ""
        let genres = first.genres?.prefix(2).map(\.name).joined(separator: " / ") ?? ""
        return Self(title: title, posterURL: movies.compactMap(\.posterURL).first,
                    details: [seasons, year, genres].filter { !$0.isEmpty }.joined(separator: " · "), matchedFiles: movies.count)
    }
}

struct MovieMetadataError: LocalizedError {
    let message: String
    var statusCode: Int? = nil
    var errorDescription: String? { message }
}

enum MovieMetadataToken {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.august.lumaplayer.tmdb", kSecAttrAccount as String: "read-token"] }
    static func read() throws -> String {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw MovieMetadataError(message: String(localized: "Save a TMDB Read Access Token in settings first."))
        }
        return token
    }
    static func save(_ input: String) throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count < 8192, !value.contains(where: { $0.isWhitespace }) else { throw MovieMetadataError(message: String(localized: "Enter a valid TMDB Read Access Token.")) }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MovieMetadataError(message: String(localized: "Could not save the token in Keychain.")) }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MovieMetadataError(message: String(localized: "Could not remove the token from Keychain.")) }
    }
}

private final class MovieAPIRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
actor OnlineMovieAPI {
    static let shared = OnlineMovieAPI()
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 20
        config.httpShouldSetCookies = false; config.urlCache = nil
        session = URLSession(configuration: config, delegate: MovieAPIRedirectPolicy(), delegateQueue: nil)
    }
    private func request<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem], token: String) async throws -> T {
        try Task.checkCancellation()
        var components = URLComponents(string: "https://api.themoviedb.org/3/" + path)!
        components.queryItems = query
        var request = URLRequest(url: components.url!); request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let message: String
            switch http.statusCode {
            case 401, 403: message = String(localized: "TMDB rejected the token. Check your API settings.")
            case 429: message = String(localized: "TMDB rate limit reached. Please try again later.")
            default: message = String(localized: "TMDB request failed (HTTP \(http.statusCode)).")
            }
            throw MovieMetadataError(message: message, statusCode: http.statusCode)
        }
        guard data.count < 2_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
    private struct Series: Decodable, Sendable {
        let id: Int
        let name: String
        let originalName: String?
        let firstAirDate: String?
        let posterPath: String?
        let genres: [OnlineMovie.Named]?
        let productionCompanies: [OnlineMovie.Named]?
    }
    private struct Episode: Decodable, Sendable {
        let id: Int
        let name: String
        let airDate: String?
        let overview: String?
        let runtime: Int?
        let credits: OnlineMovie.Credits?
    }
    func searchEpisodes(title: String, year: String, season: Int, episode: Int, seconds: Double, language: String) async throws -> [OnlineMovie] {
        guard (0...99).contains(season), (1...999).contains(episode) else { return [] }
        let token = try await Task.detached(priority: .userInitiated) { try MovieMetadataToken.read() }.value
        struct Results: Decodable, Sendable { let results: [Series] }
        var query = [URLQueryItem(name: "query", value: title), .init(name: "language", value: language), .init(name: "include_adult", value: "false")]
        if !year.isEmpty { query.append(.init(name: "first_air_date_year", value: year)) }
        let response: Results = try await request("search/tv", query: query, token: token)
        var matches: [OnlineMovie] = []
        for candidate in response.results.prefix(6) {
            do {
                let item: Episode = try await request("tv/\(candidate.id)/season/\(season)/episode/\(episode)", query: [.init(name: "language", value: language), .init(name: "append_to_response", value: "credits")], token: token)
                let series: Series = try await request("tv/\(candidate.id)", query: [.init(name: "language", value: language)], token: token)
                matches.append(Self.movie(series: series, item: item, season: season, episode: episode))
            } catch let error as MovieMetadataError where error.statusCode == 404 {
                // A title candidate without the requested episode is not a match.
                continue
            }
        }
        try Task.checkCancellation()
        await OnlinePosterCache.shared.prefetch(matches.compactMap(\.posterURL))
        return MovieFilenameQuery.ordered(matches, seconds: seconds)
    }
    private static func movie(series: Series, item: Episode, season: Int, episode: Int) -> OnlineMovie {
        let code = String(format: "S%02dE%02d", season, episode)
        var movie = OnlineMovie(id: item.id, title: "\(series.name) · \(code) · \(item.name)", originalTitle: series.originalName, releaseDate: item.airDate, overview: item.overview, runtime: item.runtime, genres: series.genres, credits: item.credits)
        movie.seriesTitle = series.name; movie.seriesFirstAirDate = series.firstAirDate
        movie.seriesID = series.id; movie.seasonNumber = season; movie.episodeNumber = episode
        movie.posterPath = series.posterPath; movie.productionCompanies = series.productionCompanies
        return movie
    }

    /// One confirmed series, one credential read, bounded sequential requests.
    /// Repeated copies of an episode share a result. Cancellation stops the batch.
    func resolveBatch(seriesID: Int, episodes: [EpisodeBatchKey], language: String,
                      receive: @MainActor @Sendable (EpisodeBatchKey, OnlineMovie?) -> Void) async throws {
        guard seriesID > 0, episodes.count <= 50 else { throw URLError(.badURL) }
        let token = try await Task.detached(priority: .userInitiated) { try MovieMetadataToken.read() }.value
        let series: Series = try await request("tv/\(seriesID)", query: [.init(name: "language", value: language)], token: token)
        for key in Set(episodes).sorted() {
            try Task.checkCancellation()
            guard (0...99).contains(key.season), (1...999).contains(key.episode) else { continue }
            do {
                let item: Episode = try await request("tv/\(seriesID)/season/\(key.season)/episode/\(key.episode)", query: [.init(name: "language", value: language), .init(name: "append_to_response", value: "credits")], token: token)
                try Task.checkCancellation()
                let movie = Self.movie(series: series, item: item, season: key.season, episode: key.episode)
                await OnlinePosterCache.shared.prefetch([movie.posterURL].compactMap { $0 })
                await receive(key, movie)
            } catch let error as MovieMetadataError where error.statusCode == 404 {
                try Task.checkCancellation()
                await receive(key, nil)
            }
            // Keep batches gentle on the provider, without blocking the main thread.
            try await Task.sleep(for: .milliseconds(180))
        }
    }
    func search(title: String, year: String, seconds: Double, language: String) async throws -> [OnlineMovie] {
        try Task.checkCancellation()
        let token = try await Task.detached(priority: .userInitiated) { try MovieMetadataToken.read() }.value
        try Task.checkCancellation()
        struct Results: Decodable, Sendable { let results: [OnlineMovie] }
        var query = [URLQueryItem(name: "query", value: title), URLQueryItem(name: "include_adult", value: "false"), URLQueryItem(name: "language", value: language)]
        if !year.isEmpty { query.append(.init(name: "primary_release_year", value: year)) }
        let response: Results = try await request("search/movie", query: query, token: token)
        var detailed: [OnlineMovie] = []
        // Six bounded detail requests; cancellation propagates to URLSession.
        for result in response.results.prefix(6) {
            let detail: OnlineMovie = try await request("movie/\(result.id)", query: [.init(name: "language", value: language), .init(name: "append_to_response", value: "credits")], token: token)
            detailed.append(detail)
        }
        try Task.checkCancellation()
        await OnlinePosterCache.shared.prefetch(detailed.compactMap(\.posterURL))
        return MovieFilenameQuery.ordered(detailed, seconds: seconds)
    }
}

@MainActor final class OnlineMovieLibrary: ObservableObject {
    static let shared = OnlineMovieLibrary()
    @Published var enabled = UserDefaults.standard.bool(forKey: "onlineMovieMetadata.enabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "onlineMovieMetadata.enabled")
            searchRevision &+= 1
            if !enabled { Task { await OnlinePosterCache.shared.cancelPending() } }
        }
    }
    @Published private(set) var searchRevision: UInt64 = 0
    private struct Record: Codable, Sendable { let stamp: PlaybackFileStamp; let movie: OnlineMovie; let saved: Date }
    @Published private var records: [String: Record] = [:] {
        didSet { searchRevision &+= 1 }
    }
    @Published private var stamps: [String: PlaybackFileStamp] = [:]
    private var validations: [String: UUID] = [:]
    private static let key = "onlineMovieMetadata.matches.v1"
    init() {
        records = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }
    private func key(_ path: String) -> String { SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() }
    func validate(_ path: String, prefetchPoster: Bool = true) async {
        guard enabled, path.hasPrefix("/"), records[key(path)] != nil else { return }
        let cacheKey = key(path), ticket = UUID()
        validations[cacheKey] = ticket
        let stamp = await Task.detached(priority: .utility) { PlaybackFileStamp.read(path) }.value
        guard !Task.isCancelled, enabled, validations[cacheKey] == ticket else { return }
        validations[cacheKey] = nil
        if stamps[cacheKey] != stamp { stamps[cacheKey] = stamp }
        if prefetchPoster, let url = movie(for: path)?.posterURL { await OnlinePosterCache.shared.prefetch([url]) }
    }
    func movie(for path: String) -> OnlineMovie? {
        guard enabled, let stamp = stamps[key(path)], let record = records[key(path)], stamp == record.stamp else { return nil }
        return record.movie
    }
    /// Validates saved matches for the entire search pool, not only visible rows.
    /// Does not fetch metadata, artwork, or decode media.
    func searchIndex(paths: [String]) async -> [String: String] {
        guard enabled, !records.isEmpty else { return [:] }
        let snapshot = records, revision = searchRevision
        let work = Task.detached(priority: .utility) {
            var index: [String: String] = [:]
            for path in Set(paths) where path.hasPrefix("/") {
                guard !Task.isCancelled else { return [String: String]() }
                let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
                guard let record = snapshot[key], PlaybackFileStamp.read(path) == record.stamp else { continue }
                index[path] = record.movie.searchableText
            }
            return index
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled, enabled, searchRevision == revision else { return [:] }
        return result
    }
    func hasSavedMatch(_ path: String) -> Bool { records[key(path)] != nil }
    func confirm(_ movie: OnlineMovie, path: String, stamp: PlaybackFileStamp) {
        confirmBatch([(path, stamp, movie)])
    }
    func confirmBatch(_ items: [(String, PlaybackFileStamp, OnlineMovie)]) {
        guard enabled, !items.isEmpty else { return }
        var nextRecords = records
        var nextStamps = stamps
        let savedAt = Date()
        for (path, stamp, movie) in items {
            validations[key(path)] = nil
            nextRecords[key(path)] = Record(stamp: stamp, movie: movie, saved: savedAt)
            nextStamps[key(path)] = stamp
        }
        if nextRecords.count > 100 {
            nextRecords = Dictionary(uniqueKeysWithValues: nextRecords.sorted {
                $0.value.saved == $1.value.saved ? $0.key < $1.key : $0.value.saved > $1.value.saved
            }.prefix(100).map { ($0.key, $0.value) })
        }
        stamps = nextStamps.filter { nextRecords[$0.key] != nil }
        records = nextRecords // Publish a batch once, not once per episode.
        persist()
        let urls = items.compactMap { $0.2.posterURL }
        Task { if enabled { await OnlinePosterCache.shared.prefetch(urls) } }
    }
    /// Call only after a successful in-app move; verify the destination before transfer.
    func relocate(from oldPath: String, to newPath: String) async {
        guard let record = records[key(oldPath)], records[key(newPath)] == nil else { return }
        let newStamp = await Task.detached(priority: .utility) { PlaybackFileStamp.read(newPath) }.value
        guard newStamp == record.stamp, records[key(oldPath)]?.saved == record.saved,
              records[key(newPath)] == nil else { return }
        var next = records
        next[key(newPath)] = record; next[key(oldPath)] = nil
        validations[key(oldPath)] = nil
        stamps[key(oldPath)] = nil; stamps[key(newPath)] = newStamp
        records = next; persist()
    }
    func remove(_ path: String) {
        let cacheKey = key(path)
        validations[cacheKey] = nil; stamps[cacheKey] = nil
        guard records[cacheKey] != nil else { return }
        records.removeValue(forKey: cacheKey); persist()
    }
    func clear() { validations.removeAll(); records.removeAll(); stamps.removeAll(); UserDefaults.standard.removeObject(forKey: Self.key) }
    private func persist() { if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: Self.key) } }
}
