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
    var posterPath: String? = nil
    var productionCompanies: [Named]? = nil
    var posterURL: URL? {
        guard let posterPath, posterPath.range(of: #"^/[A-Za-z0-9_-]+\.(jpg|png)$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500" + posterPath)
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

struct MovieMetadataError: LocalizedError {
    let message: String
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
            throw MovieMetadataError(message: message)
        }
        guard data.count < 2_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
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
        return MovieFilenameQuery.ordered(detailed, seconds: seconds)
    }
}

@MainActor final class OnlineMovieLibrary: ObservableObject {
    static let shared = OnlineMovieLibrary()
    @Published var enabled = UserDefaults.standard.bool(forKey: "onlineMovieMetadata.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "onlineMovieMetadata.enabled") }
    }
    private struct Record: Codable { let stamp: PlaybackFileStamp; let movie: OnlineMovie; let saved: Date }
    @Published private var records: [String: Record] = [:]
    @Published private var stamps: [String: PlaybackFileStamp] = [:]
    private static let key = "onlineMovieMetadata.matches.v1"
    init() {
        records = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }
    private func key(_ path: String) -> String { SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() }
    func validate(_ path: String) async {
        guard enabled, path.hasPrefix("/"), records[key(path)] != nil else { return }
        stamps.removeValue(forKey: key(path))
        let stamp = await Task.detached(priority: .utility) { PlaybackFileStamp.read(path) }.value
        guard !Task.isCancelled, enabled else { return }
        stamps[key(path)] = stamp
    }
    func movie(for path: String) -> OnlineMovie? {
        guard enabled, let stamp = stamps[key(path)], let record = records[key(path)], stamp == record.stamp else { return nil }
        return record.movie
    }
    func confirm(_ movie: OnlineMovie, path: String, stamp: PlaybackFileStamp) {
        guard enabled else { return }
        records[key(path)] = Record(stamp: stamp, movie: movie, saved: Date()); stamps[key(path)] = stamp
        if records.count > 100 { records = Dictionary(uniqueKeysWithValues: records.sorted { $0.value.saved > $1.value.saved }.prefix(100).map { ($0.key, $0.value) }) }
        stamps = stamps.filter { records[$0.key] != nil }
        persist()
    }
    func remove(_ path: String) { records.removeValue(forKey: key(path)); persist() }
    func clear() { records.removeAll(); stamps.removeAll(); UserDefaults.standard.removeObject(forKey: Self.key) }
    private func persist() { if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: Self.key) } }
}
