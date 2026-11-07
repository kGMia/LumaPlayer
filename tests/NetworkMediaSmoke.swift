// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main enum NetworkMediaSmoke {
    static func rejects(_ body: () throws -> Void) {
        do { try body(); fatalError("Expected rejection") } catch {}
    }
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--resolve" {
            let request = try await NetworkPlaybackResolver.prepare(URL(string: args[2])!, username: "test", password: "test-only")
            print(String(data: try JSONSerialization.data(withJSONObject: ["url": request.url.absoluteString, "options": request.options]), encoding: .utf8)!)
            return
        }
        if args.count == 3, args[1] == "--options" {
            let request = try NetworkMediaRequest(url: URL(string: args[2])!, username: "test", password: "test-only")
            print(String(data: try JSONSerialization.data(withJSONObject: request.options), encoding: .utf8)!)
            return
        }
        if args.count == 3, args[1] == "--dav" {
            let base = URL(string: args[2])!
            let entries = try await WebDAVDirectory.read(base, username: "test", password: "test-only")
            precondition(entries.count == 1 && entries[0].url.lastPathComponent == "clip.mp4")
            do { _ = try await WebDAVDirectory.read(base, username: "test", password: "wrong"); fatalError("Expected 401") }
            catch { precondition(error.localizedDescription.contains("401")) }
            let redirect = base.deletingLastPathComponent().appendingPathComponent("redirect/")
            do { _ = try await WebDAVDirectory.read(redirect, username: "test", password: "test-only"); fatalError("Expected redirect rejection") }
            catch { precondition(error.localizedDescription.contains("302")) }
            print("PASS: actual PROPFIND, Basic authentication, 401 and redirect rejection")
            return
        }
        let base = try NetworkMediaRequest.parse("davs://example.com/media/", webDAV: true)
        let secret = "https://private.invalid/file?token=secret"
        for (code, hint) in [(URLError.Code.timedOut, "time"), (.notConnectedToInternet, "unavailable"),
                             (.cannotFindHost, "DNS"), (.cannotConnectToHost, "port"),
                             (.networkConnectionLost, "interrupted"), (.serverCertificateUntrusted, "TLS"),
                             (.userAuthenticationRequired, "Authentication"), (.cancelled, "cancelled")] {
            let error = NSError(domain: NSURLErrorDomain, code: code.rawValue,
                                userInfo: [NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLErrorKey: URL(string: secret)!])
            let message = NetworkMediaError.message(for: error)
            precondition(message.contains(hint) && !message.contains("secret") && !message.contains("private.invalid"))
        }
        precondition(!NetworkMediaError.message(for: NSError(domain: "unknown", code: 1,
                     userInfo: [NSLocalizedDescriptionKey: secret])).contains("secret"))
        for (status, hint) in [(401, "Authentication"), (403, "Access denied"), (404, "missing"),
                               (429, "Wait"), (503, "temporarily"), (504, "time"), (302, "redirects")] {
            let message = NetworkMediaError.message(for: NetworkMediaError.http(status))
            precondition(message.contains(String(status)) && message.contains(hint))
        }
        precondition(NetworkRequestPolicy.shortRetryDelay(nil) == 1)
        precondition(NetworkRequestPolicy.shortRetryDelay("3") == 3)
        precondition(NetworkRequestPolicy.shortRetryDelay("120") == nil)
        precondition(NetworkRequestPolicy.shortRetryDelay("nan") == nil)
        precondition(NetworkRequestPolicy.shortRetryDelay("invalid") == nil)
        let epoch = Date(timeIntervalSince1970: 0)
        precondition(NetworkRequestPolicy.shortRetryDelay("Thu, 01 Jan 1970 00:00:04 GMT", now: epoch) == 4)
        precondition(NetworkRequestPolicy.shortRetryDelay("Thu, 01 Jan 1970 00:01:00 GMT", now: epoch) == nil)
        precondition(NetworkRequestPolicy.retryDelay("30") == 30)
        precondition(NetworkRequestPolicy.retryDelay("Thu, 01 Jan 1970 00:01:00 GMT", now: epoch) == 60)
        let background = try await NetworkRequestPolicy.waitForRetry(status: 429, delay: 12, attempt: 0)
        precondition(!background)
        try await NetworkRequestPolicy.$retryWait.withValue({ seconds in precondition(seconds == 12) }) {
            let retry = try await NetworkRequestPolicy.waitForRetry(status: 429, delay: 12, attempt: 0)
            let second = try await NetworkRequestPolicy.waitForRetry(status: 503, delay: 12, attempt: 1)
            let exhausted = try await NetworkRequestPolicy.waitForRetry(status: 429, delay: 12, attempt: 2)
            let long = try await NetworkRequestPolicy.waitForRetry(status: 429, delay: 121, attempt: 0)
            let auth = try await NetworkRequestPolicy.waitForRetry(status: 401, delay: 12, attempt: 0)
            precondition(retry && second && !exhausted && !long && !auth)
        }
        try await NetworkRequestPolicy.$retryWait.withValue({ _ in throw CancellationError() }) {
            do {
                _ = try await NetworkRequestPolicy.waitForRetry(status: 429, delay: 12, attempt: 0)
                fatalError("Cancellation ignored")
            } catch is CancellationError {}
        }
        print("PASS: bounded foreground rate-limit retry, background short budget, cancellation and HTTP-date parsing")
        let bounded = NetworkRequestPolicy.configuration(remaining: 2)
        precondition(bounded.timeoutIntervalForRequest == 2 && bounded.timeoutIntervalForResource == 2)
        precondition(base.scheme == "https")
        rejects { _ = try NetworkMediaRequest.parse("https://user:secret@example.com/a.mp4") }
        rejects { _ = try NetworkMediaRequest.parse("file:///tmp/movie.mp4") }
        rejects { _ = try NetworkMediaRequest.parse("https://example.com/a\nb") }
        rejects { _ = try NetworkMediaRequest.authorization(username: "a:b", password: "c") }
        rejects { _ = try NetworkMediaRequest(url: URL(string: "https://example.com/a.m3u8")!, username: "a", password: "b") }
        let authenticated = try NetworkMediaRequest(url: URL(string: "davs://example.com/a.mp4?token=secret")!, username: "a", password: "b")
        precondition(authenticated.options["force-media-title"] == "a.mp4")
        precondition(authenticated.options["stream-lavf-o"] == "max_redirects=0")
        precondition(authenticated.options["demuxer"] == "lavf" && authenticated.options["access-references"] == "no")
        for policy in NetworkCachePolicy.allCases {
            let options = policy.applying(to: authenticated.options, url: authenticated.url)
            precondition(options["cache-secs"] == String(policy.seconds))
            precondition(options["demuxer-readahead-secs"] == String(policy.seconds))
            precondition(options["demuxer-max-bytes"] == "\(policy.forwardMiB)MiB")
            precondition(options["demuxer-max-back-bytes"] == "\(policy.backwardMiB)MiB")
            precondition(options["http-header-fields"] == authenticated.options["http-header-fields"])
            precondition(options["stream-lavf-o"] == "max_redirects=0" && options["tls-verify"] == "yes")
        }
        let publicStream = try NetworkMediaRequest(url: URL(string: "https://example.com/live.m3u8")!)
        precondition(publicStream.options["http-header-fields"] == nil && publicStream.options["demuxer"] == nil)
        let rtsp = try NetworkMediaRequest(url: URL(string: "rtsp://example.com/live")!)
        precondition(rtsp.options["network-timeout"] == nil)
        precondition(NetworkCachePolicy.resilient.applying(to: rtsp.options, url: rtsp.url) == rtsp.options)
        func response(_ href: String, _ props: String, _ status: String = "200 OK") -> String {
            "<d:response><d:href>\(href)</d:href><d:propstat><d:prop>\(props)</d:prop><d:status>HTTP/1.1 \(status)</d:status></d:propstat></d:response>"
        }
        let xml = "<d:multistatus xmlns:d=\"DAV:\">" +
            response("/media/", "<d:resourcetype><d:collection/></d:resourcetype>") +
            response("/media/clip%20one.mp4", "<d:displayname>Clip &amp; One</d:displayname><d:getcontentlength>123</d:getcontentlength><d:creationdate>2026-01-02T03:04:05.000Z</d:creationdate><d:getlastmodified>Tue, 03 Nov 2026 10:00:00 GMT</d:getlastmodified>") +
            response("/media/Folder/", "<d:resourcetype><d:collection/></d:resourcetype>") +
            response("https://other.example/media/leak.mp4", "") + response("/outside.mp4", "") +
            response("/media/missing.mp4", "", "404 Not Found") + "</d:multistatus>"
        let entries = try WebDAVDirectory.parse(Data(xml.utf8), base: base)
        precondition(entries.count == 2 && entries[0].directory)
        precondition(entries[1].name == "Clip & One" && entries[1].size == 123)
        precondition(entries[1].created != nil && entries[1].modified != nil && entries[1].modified! > entries[1].created!)
        precondition(entries[1].url.absoluteString.contains("clip%20one.mp4"))
        rejects { _ = try WebDAVDirectory.parse(Data("<!DOCTYPE x><x/>".utf8), base: base) }
        rejects { _ = try WebDAVDirectory.parse(Data("<html/>".utf8), base: base) }
        let entityXML = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE x [<!ENTITY x \"expand\">]><d:multistatus xmlns:d=\"DAV:\">&x;</d:multistatus>"
        rejects { _ = try WebDAVDirectory.parse(entityXML.data(using: .utf16)!, base: base) }
        print("PASS: URL/options validation, credential isolation, DAV parsing, sanitized network errors and bounded retry policy")
    }
}
