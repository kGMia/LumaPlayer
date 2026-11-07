// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ImageIO
import Darwin
import AVFoundation

/// AVAssetImageGenerator has no Sendable conformance. Configure before publishing,
/// then serialize every generator call, including cancellation, on one queue.
/// Only immutable CGImage results cross the queue boundary.
final class AssetImageReader: @unchecked Sendable {
    struct Frame: @unchecked Sendable { let image: CGImage; let actualTime: CMTime }
    private let generator: AVAssetImageGenerator
    private let queue = DispatchQueue(label: "org.iive.asset-image", qos: .utility)
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    init(asset: AVAsset, maximumSize: CGSize, tolerance: CMTime) {
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
    }
    func cancelAllCGImageGeneration() {
        lock.withLock {
            epoch &+= 1
            queue.async { [self] in generator.cancelAllCGImageGeneration() }
        }
    }
    func image(at time: CMTime) async throws -> Frame {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                let ticket = epoch
                queue.async { [self] in
                    guard lock.withLock({ ticket == epoch }) else {
                        continuation.resume(throwing: CancellationError()); return
                    }
                    generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, actual, status, error in
                        if status == .succeeded, let image { continuation.resume(returning: Frame(image: image, actualTime: actual)) }
                        else { continuation.resume(throwing: error ?? CancellationError()) }
                    }
                }
            }
        }
    }
}

struct TimelineThumbnail: @unchecked Sendable {
    let image: CGImage
    let seconds: Double
    var usesFallback = false

    /// Includes the AVFoundation ±1.5s seek tolerance; reject poster images or
    /// a demuxer returning a distant timestamp instead of the requested frame.
    static func isNear(_ actual: Double, target: Double) -> Bool {
        actual.isFinite && target.isFinite && actual >= 0 && abs(actual - target) <= 1.75
    }
}

/// Optional local SDR thumbnail fallback for containers AVFoundation cannot read.
/// No shell, network input, on-disk frames, or changes to the playback decoder.
final class FFmpegPreviewDecoder: @unchecked Sendable {
    // PNG remains selectable for a generated-fixture A/B check. Timeline images
    // are small SDR RGB frames; BMP avoids lossless compression/decompression.
    enum TimelineEncoding: String, Sendable { case bmp, png }
    private let timelineEncoding: TimelineEncoding
    private let lock = NSLock()
    private var process: Process?
    private var canceled = false

    init(timelineEncoding: TimelineEncoding = .bmp) {
        self.timelineEncoding = timelineEncoding
    }

    static var executable: URL? {
        let candidates: [String?] = [Bundle.main.url(forAuxiliaryExecutable: "ffmpeg")?.path,
                          "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return candidates.compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }.map { URL(fileURLWithPath: $0) }
    }

    func cancel() {
        lock.lock()
        canceled = true
        // Only our own still-running child; prevents a slow probe from outliving
        // the deadline or a file change. The worker reaps the child below.
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        lock.unlock()
    }

    func decode(path: String, seconds: Double) async -> TimelineThumbnail? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let result = self.read(path: path, seconds: seconds)
                    continuation.resume(returning: result.flatMap { result in
                        result.seconds.map { TimelineThumbnail(image: result.image, seconds: $0, usesFallback: true) }
                    })
                }
            }
        } onCancel: { self.cancel() }
    }

    func decodeArtwork(path: String) async -> CGImage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: self.read(path: path, seconds: nil)?.image)
                }
            }
        } onCancel: { self.cancel() }
    }

    private struct DecodedImage { let image: CGImage; let seconds: Double? }
    private func read(path: String, seconds: Double?) -> DecodedImage? {
        if let seconds, !seconds.isFinite || seconds < 0 { return nil }
        guard path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path), let executable = Self.executable else { return nil }
        let child = Process()
        let output = Pipe(), log = Pipe()
        child.executableURL = executable
        var arguments = ["-hide_banner", "-nostdin", "-loglevel", "info",
                         "-protocol_whitelist", "file,pipe", "-threads", "1"]
        if let seconds { arguments += ["-copyts", "-start_at_zero", "-ss", String(seconds)] }
        arguments += ["-i", path,
            "-map", seconds == nil ? "0:v:disp:attached_pic" : "0:V:0", "-an", "-sn", "-dn",
            "-vf", seconds == nil ? "scale=w='min(1024,iw)':h='min(1024,ih)':force_original_aspect_ratio=decrease:reset_sar=1" : "scale=320:180:force_original_aspect_ratio=decrease:reset_sar=1,showinfo",
            "-frames:v", "1", "-fps_mode", "passthrough", "-threads", "1", "-filter_threads", "1"
        ]
        // Keep the cover-art path lossless with its existing alpha behavior.
        // Explicit 24-bit formats make channel order deterministic for both
        // timeline encoders; ImageIO handles BMP's bottom-up storage.
        if seconds != nil {
            arguments += ["-pix_fmt", timelineEncoding == .bmp ? "bgr24" : "rgb24"]
        }
        arguments += ["-f", "image2pipe", "-c:v", seconds == nil ? "png" : timelineEncoding.rawValue, "pipe:1"]
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output; child.standardError = log
        lock.lock()
        guard !canceled else { lock.unlock(); return nil }
        do { try child.run(); process = child }
        catch { lock.unlock(); return nil }
        lock.unlock()
        // Closing parent write handles lets readers see EOF even after cancellation.
        try? output.fileHandleForWriting.close()
        try? log.fileHandleForWriting.close()
        let deadline = DispatchWorkItem { [weak self] in self?.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4, execute: deadline)
        defer {
            deadline.cancel()
            try? output.fileHandleForReading.close()
            try? log.fileHandleForReading.close()
            lock.lock(); process = nil; lock.unlock()
        }
        // Drain both pipes concurrently; cap retained diagnostics and image bytes.
        let diagnostics = PreviewDiagnostics()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            while let chunk = try? log.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
                diagnostics.append(chunk)
            }
            group.leave()
        }
        var data = Data()
        while let chunk = try? output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            guard data.count + chunk.count <= (seconds == nil ? 8_388_608 : 2_097_152) else { cancel(); break }
            data.append(chunk)
        }
        child.waitUntilExit()
        group.wait()
        lock.lock(); let wasCanceled = canceled; lock.unlock()
        guard !wasCanceled, child.terminationStatus == 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        // An attached cover has no playback timestamp. Never pass it through
        // timeline timestamp validation or present it as a decoded video preview.
        guard let seconds else { return DecodedImage(image: image, seconds: nil) }
        guard let actual = diagnostics.firstPTS else { return nil }
        // -copyts -start_at_zero keeps the file-relative decoded PTS even with
        // input -ss. Never substitute the requested target for the image clock.
        guard TimelineThumbnail.isNear(actual, target: seconds) else { return nil }
        return DecodedImage(image: image, seconds: actual)
    }
}

private final class PreviewDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        // Keep the tail: files with many chapters can print a large header before
        // showinfo emits the one frame timestamp we need.
        data.append(chunk)
        if data.count > 131_072 { data.removeFirst(data.count - 131_072) }
    }
    var firstPTS: Double? {
        lock.lock(); defer { lock.unlock() }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") where line.contains("Parsed_showinfo") {
            guard let range = line.range(of: "pts_time:") else { continue }
            let value = line[range.upperBound...].prefix { !$0.isWhitespace }
            if let time = Double(value), time.isFinite { return time }
        }
        return nil
    }
}
