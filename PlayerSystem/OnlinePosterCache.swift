// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ImageIO
import CryptoKit

private final class PosterRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Content-addressed TMDB artwork, shared between search and information views.
/// All disk access and ImageIO decoding stay off the main actor. No API tokens.
actor OnlinePosterCache {
    static let shared = OnlinePosterCache()
    typealias Loader = @Sendable (URL) async -> Data?
    private struct Entry { let image: CGImage; let cost: Int; var used: UInt64 }
    private struct Payload: Sendable { let image: CGImage; let data: Data }
    private let directory: URL
    private let loader: Loader
    private var memory: [URL: Entry] = [:]
    private var flights: [URL: (UUID, Task<Payload?, Never>)] = [:]
    private var pending: [URL] = []
    private var prefetchTask: Task<Void, Never>?
    private var prefetchID: UUID?
    private var clock: UInt64 = 0
    private var generation: UInt64 = 0
    private let memoryLimit = 32 * 1024 * 1024
    private let diskLimit = 128 * 1024 * 1024
    static let maximumBytes = 5 * 1024 * 1024

    init(directory: URL? = nil, loader: Loader? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.august.lumaplayer/OnlinePosters", isDirectory: true)
        if let loader { self.loader = loader }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.httpMaximumConnectionsPerHost = 3
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            let session = URLSession(configuration: configuration, delegate: PosterRedirectPolicy(), delegateQueue: nil)
            self.loader = { url in
                do {
                    let (bytes, response) = try await session.bytes(from: url)
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                          ["image/jpeg", "image/png"].contains(response.mimeType ?? ""),
                          response.expectedContentLength <= OnlinePosterCache.maximumBytes else { return nil }
                    var data = Data()
                    for try await byte in bytes {
                        if Task.isCancelled || data.count >= OnlinePosterCache.maximumBytes { return nil }
                        data.append(byte)
                    }
                    return data
                } catch { return nil }
            }
        }
    }

    static func accepts(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "image.tmdb.org" && url.port == nil &&
        url.user == nil && url.password == nil && url.query == nil && url.fragment == nil &&
        url.path.range(of: #"^/t/p/w500/[A-Za-z0-9_-]+\.(jpg|png)$"#, options: .regularExpression) != nil
    }
    private func file(_ url: URL) -> URL {
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key).appendingPathExtension("image")
    }
    private static func decode(_ data: Data) -> CGImage? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1000,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
    func image(for url: URL) async -> CGImage? {
        guard Self.accepts(url), !Task.isCancelled else { return nil }
        clock &+= 1
        if var entry = memory[url] { entry.used = clock; memory[url] = entry; return entry.image }
        let epoch = generation
        let flight: (UUID, Task<Payload?, Never>)
        if let pending = flights[url] { flight = pending }
        else {
            let disk = file(url)
            if let size = (try? disk.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maximumBytes,
               let data = try? Data(contentsOf: disk), let image = Self.decode(data) {
                remember(image, for: url)
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: disk.path)
                return image
            }
            try? FileManager.default.removeItem(at: disk) // Corrupt cache is retried from the provider.
            let loader = loader
            flight = (UUID(), Task {
                guard let data = await loader(url), !Task.isCancelled, let image = Self.decode(data) else { return nil }
                return Payload(image: image, data: data)
            })
            flights[url] = flight
        }
        let payload = await flight.1.value
        guard generation == epoch else { return nil }
        if flights[url]?.0 == flight.0 {
            flights[url] = nil
            if let payload {
                remember(payload.image, for: url)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? payload.data.write(to: file(url), options: .atomic)
                trimDisk()
            }
        }
        return Task.isCancelled ? nil : payload?.image
    }
    private func remember(_ image: CGImage, for url: URL) {
        clock &+= 1
        memory[url] = Entry(image: image, cost: image.bytesPerRow * image.height, used: clock)
        var size = memory.values.reduce(0) { $0 + $1.cost }
        for (key, value) in memory.sorted(by: { $0.value.used < $1.value.used }) {
            guard size > memoryLimit else { break }
            memory[key] = nil; size -= value.cost
        }
    }
    private func trimDisk() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "image" }
            .compactMap { url -> (URL, Int, Date)? in
                guard let value = try? url.resourceValues(forKeys: keys), value.isRegularFile == true else { return nil }
                return (url, value.fileSize ?? 0, value.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 < $1.2 }
        var bytes = files.reduce(0) { $0 + $1.1 }; var count = files.count
        for (url, size, _) in files {
            guard bytes > diskLimit || count > 256 else { break }
            try? FileManager.default.removeItem(at: url); bytes -= size; count -= 1
        }
    }
    /// Start downloading known artwork immediately, without blocking search results.
    /// A single worker bounds background traffic; visible views coalesce with it.
    func prefetch(_ urls: [URL]) {
        for url in urls where Self.accepts(url) && memory[url] == nil && flights[url] == nil && !pending.contains(url) {
            guard pending.count < 256 else { break }
            pending.append(url)
        }
        guard prefetchTask == nil, !pending.isEmpty else { return }
        let ticket = UUID(); prefetchID = ticket
        prefetchTask = Task {
            while !Task.isCancelled, !pending.isEmpty {
                let url = pending.removeFirst()
                _ = await image(for: url)
            }
            if prefetchID == ticket { prefetchTask = nil; prefetchID = nil }
        }
    }
    func cancelPending() {
        generation &+= 1
        pending.removeAll(); prefetchTask?.cancel(); prefetchTask = nil; prefetchID = nil
        flights.values.forEach { $0.1.cancel() }; flights.removeAll()
    }
    func clear() {
        cancelPending(); memory.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }
}
