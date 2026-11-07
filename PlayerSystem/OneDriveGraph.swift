// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct OneDriveItem: Decodable, Identifiable, Sendable {
    struct Folder: Decodable, Sendable { let childCount: Int? }
    struct Parent: Decodable, Sendable { let driveId: String?; let id: String? }
    struct Media: Decodable, Sendable { let duration: Double? }
    struct Thumbnail: Decodable, Sendable { let url: String? }
    struct ThumbnailSet: Decodable, Sendable { let small: Thumbnail?; let medium: Thumbnail? }
    let id: String
    let name: String
    let size: Int64?
    let folder: Folder?
    let parentReference: Parent?
    let video: Media?
    let audio: Media?
    let thumbnails: [ThumbnailSet]?
    let downloadURL: String?
    let cTag: String?
    let eTag: String?
    enum CodingKeys: String, CodingKey {
        case id, name, size, folder, parentReference, video, audio, thumbnails, cTag, eTag
        case downloadURL = "@microsoft.graph.downloadUrl"
    }
    var duration: Double? {
        guard let ms = video?.duration ?? audio?.duration, ms.isFinite, ms >= 0 else { return nil }
        return ms / 1000
    }
    var playable: Bool { folder == nil && NetworkMediaRequest.directFormats[(name as NSString).pathExtension.lowercased()] != nil }
    func mediaItem(drive: String) -> WebDAVItem {
        WebDAVItem(url: OneDriveGraph.itemURL(drive: drive, item: id), name: name, directory: folder != nil, size: size)
    }
}

struct OneDrivePage: Decodable, Sendable {
    let value: [OneDriveItem]
    let nextLink: String?
    enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink" }
}

struct OneDriveLocation: Equatable, Sendable {
    let account: String
    let drive: String
    let folder: String
}

private final class OneDriveNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum OneDriveGraph {
    static let base = URL(string: "https://graph.microsoft.com/v1.0/")!
    static func itemURL(drive: String, item: String) -> URL {
        base.appendingPathComponent("drives").appendingPathComponent(drive).appendingPathComponent("items").appendingPathComponent(item)
    }
    static func graphURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "graph.microsoft.com" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil && url.fragment == nil && url.path.hasPrefix("/v1.0/")
    }
    static func downloadURL(_ text: String) throws -> URL {
        let url = try NetworkMediaRequest.parse(text)
        guard url.scheme == "https", url.port == nil || url.port == 443, url.fragment == nil else {
            throw NetworkMediaError.invalid("OneDrive did not return a secure download address.")
        }
        return url
    }
    static func query(_ url: URL, _ items: [URLQueryItem]) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.queryItems = items
        return parts.url!
    }
    /// Authenticated Graph requests never follow redirects. Temporary download
    /// and thumbnail URLs are read separately, without an Authorization header.
    static func data(_ url: URL, token: String?, limit: Int) async throws -> (Data, Int, String?) {
        if token != nil && !graphURL(url) { throw NetworkMediaError.invalid("Rejected an unexpected OneDrive API address.") }
        let config = NetworkRequestPolicy.configuration()
        let session = URLSession(configuration: config, delegate: OneDriveNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = config.timeoutIntervalForRequest
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw NetworkMediaError.invalid("Invalid OneDrive response.") }
        let retry = response.value(forHTTPHeaderField: "Retry-After")
        guard response.statusCode == 200 else { return (Data(), response.statusCode, retry) }
        guard response.expectedContentLength <= limit else { throw NetworkMediaError.invalid("OneDrive response exceeds the read limit.") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw NetworkMediaError.invalid("OneDrive response exceeds the read limit.") }
            data.append(byte)
        }
        return (data, response.statusCode, retry)
    }
}
