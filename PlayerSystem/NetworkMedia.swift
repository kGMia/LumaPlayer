// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

struct RemoteContentVersion: Sendable {
    let size: Int64
    let validator: String
    var digest: String {
        SHA256.hash(data: Data("\(size):\(validator)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func read(_ response: HTTPURLResponse) -> Self? {
        guard [200, 206].contains(response.statusCode) else { return nil }
        let length: Int64?
        if response.statusCode == 206 {
            // Content-Length is the one-byte probe length, not the media size.
            guard let range = response.value(forHTTPHeaderField: "Content-Range"), range.lowercased().hasPrefix("bytes "),
                  range.split(separator: "/").count == 2 else { return nil }
            length = range.split(separator: "/").last.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
        } else { length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) }
        guard let length, length > 0 else { return nil }
        let etag = response.value(forHTTPHeaderField: "ETag") ?? ""
        let modified = response.value(forHTTPHeaderField: "Last-Modified") ?? ""
        guard !etag.isEmpty || !modified.isEmpty else { return nil }
        return Self(size: length, validator: !etag.isEmpty ? "etag:" + etag : "modified:" + modified)
    }
}

enum NetworkCachePolicy: String, CaseIterable, Sendable {
    case economical, balanced, resilient
    var title: String {
        switch self { case .economical: return String(localized: "Economical"); case .balanced: return String(localized: "Balanced"); case .resilient: return String(localized: "Unstable Connection") }
    }
    var forwardMiB: Int { switch self { case .economical: return 32; case .balanced: return 64; case .resilient: return 128 } }
    var backwardMiB: Int { switch self { case .economical: return 8; case .balanced: return 16; case .resilient: return 16 } }
    var seconds: Int { switch self { case .economical: return 10; case .balanced: return 30; case .resilient: return 60 } }
    var summary: String { String(localized: "Up to \(seconds)s ahead, \(forwardMiB) MiB forward / \(backwardMiB) MiB backward packet budgets per player window. Actual buffering also depends on bitrate.") }
    func applying(to options: [String: String], url: URL) -> [String: String] {
        // Live RTSP retains its existing latency behavior.
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return options }
        var result = options
        result["cache-secs"] = String(seconds)
        result["demuxer-readahead-secs"] = String(seconds)
        result["demuxer-max-bytes"] = "\(forwardMiB)MiB"
        result["demuxer-max-back-bytes"] = "\(backwardMiB)MiB"
        result["cache-pause-wait"] = self == .resilient ? "2" : "1"
        return result
    }
}


enum NetworkMediaError: LocalizedError {
    case invalid(String.LocalizationValue)
    case http(Int)
    case retryLater(Int, TimeInterval?)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return String(localized: message)
        case .retryLater(let status, _): return Self.http(status).errorDescription
        case .http(let status):
            let reason: String
            switch status {
            case 401: reason = String(localized: "Authentication rejected. Check the saved account or sign in again.")
            case 403: reason = String(localized: "Access denied. Reopen the file to refresh its link; check account permissions if it persists.")
            case 404, 410: reason = String(localized: "File or folder is missing, or its link expired. Browse the server and reopen it.")
            case 408, 504: reason = String(localized: "The server did not respond in time. Check the connection and try again.")
            case 429: reason = String(localized: "Too many requests. Wait before trying again.")
            case 500...599: reason = String(localized: "The server is temporarily unavailable. Try again later.")
            case 300...399: reason = String(localized: "This address redirects to another location. Use the final folder address.")
            default: reason = String(localized: "The server rejected the request. Check the address and server configuration.")
            }
            return String(localized: "HTTP \(status): \(reason)")
        }
    }
    /// Never expose URLSession's raw descriptions, which can contain signed URLs.
    static func message(for error: Error) -> String {
        if let known = error as? Self { return known.localizedDescription }
        if error is CancellationError { return String(localized: "Request cancelled.") }
        if error is DecodingError { return String(localized: "The server returned an unreadable response. Try again or check the service configuration.") }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: ns.code) {
            case .cancelled: return String(localized: "Request cancelled.")
            case .timedOut: return String(localized: "The server did not respond in time. Check the connection and try again.")
            case .notConnectedToInternet, .dataNotAllowed: return String(localized: "Network access is unavailable. Restore the connection, then try again.")
            case .cannotFindHost, .dnsLookupFailed: return String(localized: "Cannot find the server. Check its address and your DNS or VPN connection.")
            case .cannotConnectToHost: return String(localized: "Cannot connect to the server. Check its availability, port and VPN connection.")
            case .networkConnectionLost: return String(localized: "The connection was interrupted while reading. Restore the connection, then retry.")
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                return String(localized: "TLS verification failed. Check the server certificate and system date.")
            case .userAuthenticationRequired, .userCancelledAuthentication:
                return String(localized: "Authentication is required. Check the saved account or sign in again.")
            case .cannotDecodeContentData, .cannotDecodeRawData, .badServerResponse:
                return String(localized: "The server returned an unreadable response. Check the service configuration and try again.")
            default: break
            }
        }
        return String(localized: "The network request failed. Check the connection and server availability, then try again.")
    }
}

enum NetworkRequestPolicy {
    static let idleTimeout: TimeInterval = 20
    static let resourceTimeout: TimeInterval = 30
    static let redirectTimeout: TimeInterval = 25
    static func configuration(remaining: TimeInterval = resourceTimeout) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = min(idleTimeout, remaining)
        config.timeoutIntervalForResource = remaining
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        return config
    }
    // Only user-visible browsing operations opt in to longer waits. Background
    // metadata and playback-link resolution keep their existing short budget.
    @TaskLocal static var retryWait: (@Sendable (TimeInterval) async throws -> Void)?
    static func waitForRetry(status: Int, delay: TimeInterval?, attempt: Int) async throws -> Bool {
        guard status == 429 || status == 503, let delay, delay.isFinite, delay >= 1 else { return false }
        try Task.checkCancellation()
        if let retryWait {
            guard attempt < 2, delay <= 120 else { return false }
            try await retryWait(delay)
        } else {
            guard attempt < 1, delay <= 5 else { return false }
            try await Task.sleep(for: .seconds(delay))
        }
        try Task.checkCancellation()
        return true
    }
    static func shortRetryDelay(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let seconds = retryDelay(value, now: now), seconds <= 5 else { return nil }
        return seconds
    }
    static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return 1 }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds: TimeInterval
        if let number = Double(text) { seconds = number }
        else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let date = formatter.date(from: text) else { return nil }
            seconds = date.timeIntervalSince(now)
        }
        guard seconds.isFinite else { return nil }
        return max(1, seconds)
    }
}
struct NetworkMediaRequest: Sendable {
    let url: URL
    let options: [String: String]
    var contentVersion: RemoteContentVersion? = nil
    static let directFormats = ["mp4":"mov", "m4v":"mov", "mov":"mov", "m4a":"mov", "m4b":"mov",
        "mkv":"matroska", "webm":"matroska", "mka":"matroska", "avi":"avi", "ts":"mpegts", "m2ts":"mpegts",
        "mpg":"mpeg", "mpeg":"mpeg", "mts":"mpegts", "wmv":"asf", "wma":"asf", "flv":"flv", "3gp":"mov",
        "aiff":"aiff", "aif":"aiff", "caf":"caf", "oga":"ogg", "ogv":"ogg", "mp3":"mp3", "flac":"flac", "wav":"wav", "aac":"aac", "ogg":"ogg", "opus":"ogg"]
    static func parse(_ text: String, webDAV: Bool = false) throws -> URL {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              var parts = URLComponents(string: text) else { throw NetworkMediaError.invalid("Enter a valid network URL.") }
        parts.scheme = parts.scheme?.lowercased()
        if parts.scheme == "dav" { parts.scheme = "http" }
        if parts.scheme == "davs" { parts.scheme = "https" }
        let allowed = webDAV ? ["http", "https"] : ["http", "https", "rtsp", "rtsps"]
        guard allowed.contains(parts.scheme?.lowercased() ?? ""), !(parts.host ?? "").isEmpty,
              parts.user == nil, parts.password == nil, let url = parts.url else {
            throw NetworkMediaError.invalid("Use an HTTP(S) or RTSP URL. Enter credentials in the separate fields, not in the URL.")
        }
        return url
    }
    static func title(_ url: URL) -> String {
        let text = url.lastPathComponent.isEmpty ? (url.host ?? "Network Media") : url.lastPathComponent
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })).prefix(240).description
            .replacingOccurrences(of: "$", with: "＄")
    }
    static func authorization(username: String, password: String) throws -> String? {
        guard !username.isEmpty || !password.isEmpty else { return nil }
        guard !username.isEmpty, !username.contains(":"),
              !(username + password).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw NetworkMediaError.invalid("Enter a username without ':' or control characters.")
        }
        return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }
    init(url: URL, username: String = "", password: String = "", directFileName: String? = nil) throws {
        let url = try Self.parse(url.absoluteString)
        self.url = url
        var options = ["tls-verify":"yes", "cache":"yes", "pause":"no", "demuxer-max-bytes":"64MiB",
                       "demuxer-max-back-bytes":"16MiB", "force-media-title":Self.title(url),
                       "sub-auto":"no", "audio-file-auto":"no"]
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { options["network-timeout"] = String(Int(NetworkRequestPolicy.idleTimeout)) }
        let authorization = try Self.authorization(username: username, password: password)
        if authorization != nil || directFileName != nil {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let format = Self.directFormats[(directFileName.map { ($0 as NSString).pathExtension } ?? url.pathExtension).lowercased()] else {
                throw NetworkMediaError.invalid("Authenticated playback requires a direct MP4/MKV/MOV/WebM/AVI/TS or supported audio file, not a playlist.")
            }
            // The pinned build uses FFmpeg HTTP (HAVE_LIBCURL=0). Do not forward
            // the Authorization field across redirects or a nested media manifest.
            if let authorization { options["http-header-fields"] = "Authorization: " + authorization }
            if let directFileName { options["force-media-title"] = directFileName.replacingOccurrences(of: "$", with: "＄") }
            options["stream-lavf-o"] = "max_redirects=0"
            options["demuxer"] = "lavf"
            options["access-references"] = "no"
            options["demuxer-lavf-format"] = format
        }
        self.options = options
    }
}
struct WebDAVItem: Identifiable, Sendable {
    var id: String { url.absoluteString }
    let url: URL
    let name: String
    let directory: Bool
    let size: Int64?
    var created: Date? = nil
    var modified: Date? = nil
}
enum RemoteMediaBatch {
    static func media(_ items: [WebDAVItem]) -> [WebDAVItem] {
        var seen = Set<URL>()
        return items.filter {
            !$0.directory && NetworkMediaRequest.directFormats[($0.name as NSString).pathExtension.lowercased()] != nil &&
                seen.insert($0.url).inserted
        }
    }
}
private final class NoDAVRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum WebDAVDirectory {
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ u: URL) -> Int { u.port ?? (u.scheme?.lowercased() == "https" ? 443 : 80) }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
    }
    static func read(_ url: URL, username: String, password: String) async throws -> [WebDAVItem] {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do { return try await readOnce(url, username: username, password: password) }
            catch NetworkMediaError.retryLater(let status, let delay) {
                guard try await NetworkRequestPolicy.waitForRetry(status: status, delay: delay, attempt: attempt) else {
                    throw NetworkMediaError.http(status)
                }
                attempt += 1
            }
        }
    }
    private static func readOnce(_ url: URL, username: String, password: String) async throws -> [WebDAVItem] {
        let config = NetworkRequestPolicy.configuration()
        let session = URLSession(configuration: config, delegate: NoDAVRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = config.timeoutIntervalForRequest
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(try NetworkMediaRequest.authorization(username: username, password: password), forHTTPHeaderField: "Authorization")
        request.httpBody = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:creationdate/><d:getlastmodified/></d:prop></d:propfind>".utf8)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw NetworkMediaError.invalid("Invalid WebDAV response.") }
        guard http.statusCode == 207 else {
            if http.statusCode == 429 || http.statusCode == 503 {
                throw NetworkMediaError.retryLater(http.statusCode,
                    NetworkRequestPolicy.retryDelay(http.value(forHTTPHeaderField: "Retry-After")))
            }
            throw NetworkMediaError.http(http.statusCode)
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 4 * 1024 * 1024 else { throw NetworkMediaError.invalid("This directory is too large (4 MiB response limit). Open a smaller folder.") }
            data.append(byte)
        }
        return try parse(data, base: url)
    }
    static func parse(_ data: Data, base: URL) throws -> [WebDAVItem] {
        guard data.count <= 4 * 1024 * 1024, data.range(of: Data("<!DOCTYPE".utf8)) == nil else { throw NetworkMediaError.invalid("Invalid or oversized directory response.") }
        let delegate = DAVParser(base: base)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.valid else { throw NetworkMediaError.invalid("Invalid WebDAV directory XML.") }
        return delegate.items.sorted { a,b in
            if a.directory != b.directory { return a.directory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
private final class DAVParser: NSObject, XMLParserDelegate {
    let base: URL
    var items: [WebDAVItem] = []
    var valid = false
    private var path: [String] = []
    private var text = "", href = "", name = "", size: Int64?, collection = false
    private var propName = "", propSize: Int64?, propCollection = false, status = ""
    private var created: Date?, modified: Date?, propCreated: Date?, propModified: Date?
    private var seen: Set<String> = []
    private var accepted = false
    init(base: URL) { self.base = base }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
        path.append(namespaceURI == "DAV:" ? name : ""); text = ""
        if path.count == 1 { valid = name == "multistatus" && namespaceURI == "DAV:" }
        if name == "response", namespaceURI == "DAV:" { href = ""; self.name = ""; size = nil; collection = false; accepted = false; created = nil; modified = nil }
        if name == "propstat", namespaceURI == "DAV:" { propName = ""; propSize = nil; propCollection = false; status = ""; propCreated = nil; propModified = nil }
        if path.suffix(3) == ["prop", "resourcetype", "collection"] { propCollection = true }
        if path.count > 32 { parser.abortParsing() }
    }
    // Reject internal entity declarations too: UTF-16 XML can bypass the cheap
    // UTF-8 DOCTYPE precheck, and external-entity resolution alone is insufficient.
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { path.removeLast(); text = "" }
        guard namespaceURI == "DAV:" else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.suffix(2) == ["response", "href"] { href = value }
        if path.suffix(2) == ["prop", "displayname"] { propName = value }
        if path.suffix(2) == ["prop", "getcontentlength"] { propSize = Int64(value) }
        if path.suffix(2) == ["prop", "creationdate"] {
            let iso = ISO8601DateFormatter()
            propCreated = iso.date(from: value)
            if propCreated == nil { iso.formatOptions.insert(.withFractionalSeconds); propCreated = iso.date(from: value) }
        }
        if path.suffix(2) == ["prop", "getlastmodified"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            propModified = formatter.date(from: value)
        }
        if path.suffix(2) == ["propstat", "status"] { status = value }
        if name == "propstat", status.split(separator: " ").dropFirst().first == "200" {
            accepted = true
            if let propCreated { created = propCreated }; if let propModified { modified = propModified }
            if !propName.isEmpty { self.name = propName }; if let propSize { size = propSize }; collection = collection || propCollection
        }
        if name == "response", accepted, !href.isEmpty, let url = URL(string: href, relativeTo: base)?.absoluteURL,
           WebDAVDirectory.sameOrigin(url, base), url.user == nil, url.password == nil,
           url.standardized.path != base.standardized.path, !seen.contains(url.absoluteString) {
            let parent = base.path.hasSuffix("/") ? base.path : base.path + "/"
            guard url.standardized.path.hasPrefix(parent) else { return }
            guard items.count < 5000 else { parser.abortParsing(); return }
            seen.insert(url.absoluteString)
            items.append(WebDAVItem(url: url, name: self.name.isEmpty ? NetworkMediaRequest.title(url) : self.name,
                                    directory: collection, size: size, created: created, modified: modified))
        }
    }
}

/// Resolve WebDAV GET redirects before handing the final direct file to mpv.
/// Credentials follow only the original origin; cross-origin CDN URLs are anonymous.
/// A one-byte Range request checks access without downloading the video.
enum NetworkPlaybackResolver {
    static func prepare(_ original: URL, username: String, password: String, fileName: String? = nil) async throws -> NetworkMediaRequest {
        let original = try NetworkMediaRequest.parse(original.absoluteString)
        guard ["http", "https"].contains(original.scheme ?? "") else {
            return try NetworkMediaRequest(url: original, username: username, password: password)
        }
        let authorization = try NetworkMediaRequest.authorization(username: username, password: password)
        // Public manifests retain mpv's nested-request handling. Only authenticated
        // direct files need the explicit credential boundary and preflight.
        guard authorization != nil || fileName != nil else { return try NetworkMediaRequest(url: original) }
        let sourceName = (fileName.flatMap { NetworkMediaRequest.directFormats[($0 as NSString).pathExtension.lowercased()] != nil ? $0 : nil }) ?? original.lastPathComponent
        _ = try NetworkMediaRequest(url: original, username: username, password: password, directFileName: sourceName)
        var current = original
        var visited = Set<String>()
        var maySendCredentials = true
        let deadline = ProcessInfo.processInfo.systemUptime + NetworkRequestPolicy.redirectTimeout
        for _ in 0..<8 {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw URLError(.timedOut) }
            guard visited.insert(current.absoluteString).inserted else { throw NetworkMediaError.invalid("The server returned a redirect loop.") }
            let config = NetworkRequestPolicy.configuration(remaining: remaining)
            let session = URLSession(configuration: config, delegate: NoDAVRedirect(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: current, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = config.timeoutIntervalForRequest
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            if maySendCredentials { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
            let (_, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
            guard let http = response as? HTTPURLResponse else { throw NetworkMediaError.invalid("Invalid media response.") }
            // Close immediately even if the server ignores Range and returns the whole file.
            session.invalidateAndCancel()
            if [301, 302, 303, 307, 308].contains(http.statusCode) {
                guard let location = http.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: current)?.absoluteURL,
                      let checked = try? NetworkMediaRequest.parse(next.absoluteString, webDAV: true),
                      !(current.scheme == "https" && checked.scheme != "https") else {
                    throw NetworkMediaError.invalid("Unsafe or invalid media redirect (HTTPS cannot downgrade to HTTP).")
                }
                // Once the chain leaves the origin, never re-attach credentials.
                maySendCredentials = maySendCredentials && WebDAVDirectory.sameOrigin(original, checked)
                current = checked
                continue
            }
            guard [200, 206].contains(http.statusCode) else {
                throw NetworkMediaError.http(http.statusCode)
            }
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard !type.contains("text/html"), !type.contains("application/json") else {
                throw NetworkMediaError.invalid("The server returned a web page or API response instead of media.")
            }
            var prepared = try NetworkMediaRequest(url: current, username: maySendCredentials ? username : "",
                password: maySendCredentials ? password : "", directFileName: sourceName)
            prepared.contentVersion = RemoteContentVersion.read(http)
            return prepared
        }
        throw NetworkMediaError.invalid("The server returned too many media redirects.")
    }
}
