// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum OneDriveClient {
    static func json<T: Decodable>(_ url: URL, account: String, as type: T.Type) async throws -> T {
        guard OneDriveGraph.graphURL(url) else { throw NetworkMediaError.invalid("Rejected an unexpected OneDrive API address.") }
        var refreshed = false, retryAttempt = 0
        while true {
            try Task.checkCancellation()
            let token = try await OneDriveAccount.shared.token(for: account, force: refreshed)
            let (data, status, retryAfter) = try await OneDriveGraph.data(url, token: token, limit: 6*1024*1024)
            if status == 200 { return try JSONDecoder().decode(T.self, from: data) }
            if status == 401 && !refreshed { refreshed = true; continue }
            if try await NetworkRequestPolicy.waitForRetry(status: status,
                delay: NetworkRequestPolicy.retryDelay(retryAfter), attempt: retryAttempt) {
                retryAttempt += 1; continue
            }
            throw NetworkMediaError.http(status)
        }
    }
    static func root(account: String) async throws -> (item: OneDriveItem, drive: String) {
        struct Drive: Decodable { let id: String }
        // A root item need not expose parentReference. Obtain the drive identity
        // directly instead of relying on a parent on the root folder.
        let drive = try await json(OneDriveGraph.query(OneDriveGraph.base.appendingPathComponent("me/drive"),
            [URLQueryItem(name: "$select", value: "id")]), account: account, as: Drive.self)
        let root = try await json(OneDriveGraph.base.appendingPathComponent("drives").appendingPathComponent(drive.id).appendingPathComponent("root"), account: account, as: OneDriveItem.self)
        return (root, drive.id)
    }
    static func page(_ location: OneDriveLocation, next: String? = nil) async throws -> OneDrivePage {
        let url: URL
        if let next {
            guard let parsed = URL(string: next), OneDriveGraph.graphURL(parsed) else { throw NetworkMediaError.invalid("Invalid OneDrive next-page link.") }
            url = parsed
        } else {
            url = OneDriveGraph.query(OneDriveGraph.itemURL(drive: location.drive, item: location.folder).appendingPathComponent("children"), [
                URLQueryItem(name: "$top", value: "100"), URLQueryItem(name: "$select", value: "id,name,size,folder,parentReference,video,audio")])
        }
        return try await json(url, account: location.account, as: OneDrivePage.self)
    }
    static func siblings(_ location: OneDriveLocation) async throws -> [WebDAVItem] {
        var items: [WebDAVItem] = [], next: String?, seen = Set<String>()
        repeat {
            let response = try await page(location, next: next)
            items += response.value.filter(\.playable).map { $0.mediaItem(drive: location.drive) }
            guard items.count <= 5000 else { throw NetworkMediaError.invalid("This folder exceeds the 5,000-media queue limit.") }
            next = response.nextLink
            if let next { guard seen.insert(next).inserted, seen.count < 100 else { throw NetworkMediaError.invalid("OneDrive folder pagination exceeded its limit.") } }
        } while next != nil
        return items
    }
    static func resolve(_ item: WebDAVItem, location: OneDriveLocation) async throws -> NetworkMediaRequest {
        let result = try await json(item.url, account: location.account, as: OneDriveItem.self)
        guard result.folder == nil, let raw = result.downloadURL else { throw NetworkMediaError.invalid("OneDrive has no direct download link for this file. Shared shortcuts are not supported yet.") }
        let url = try OneDriveGraph.downloadURL(raw)
        // No Graph bearer token follows the preauthenticated content URL.
        var request = try await NetworkPlaybackResolver.prepare(url, username: "", password: "", fileName: item.name)
        // Graph cTag describes content, so metadata-only renames retain progress.
        // https://learn.microsoft.com/graph/api/resources/driveitem?view=graph-rest-1.0
        if let size = result.size, size > 0, let tag = result.cTag ?? result.eTag, !tag.isEmpty {
            request.contentVersion = RemoteContentVersion(size: size, validator: "graph:" + tag)
        }
        return request
    }
    static func metadata(_ item: WebDAVItem, location: OneDriveLocation, cover: Bool) async throws -> QueueMetadata {
        var query = [URLQueryItem(name: "$select", value: "id,name,size,video,audio")]
        if cover { query.append(URLQueryItem(name: "$expand", value: "thumbnails")) }
        let url = OneDriveGraph.query(item.url, query)
        let result = try await json(url, account: location.account, as: OneDriveItem.self)
        try Task.checkCancellation()
        var image: Data?
        if cover, let raw = result.thumbnails?.first?.small?.url ?? result.thumbnails?.first?.medium?.url,
           let thumbnail = try? OneDriveGraph.downloadURL(raw) {
            if let response = try? await OneDriveGraph.data(thumbnail, token: nil, limit: 1024*1024), response.1 == 200 { image = response.0 }
        }
        return QueueMetadata(duration: result.duration, size: result.size ?? item.size, cover: image)
    }
}
