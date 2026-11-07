// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AVFoundation

/// One serial native decoder, retired after five idle seconds. Cancellation is
/// terminal and only used for an obsolete media/decode task, never a hover move.
private final class LocalTimelineReader: @unchecked Sendable {
    private let reader = IIVELocalVideoPreview()
    private let queue = DispatchQueue(label: "org.iive.timeline.native", qos: .utility)
    private var serial: UInt64 = 0 // queue only
    private var unavailable = false // A failed native attempt falls back for this media.
    func cancel() { reader.cancel() }
    func decode(path: String, seconds: Double) async -> TimelineThumbnail? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard !unavailable else { continuation.resume(returning: nil); return }
                    serial &+= 1
                    let ticket = serial
                    let frame = reader.readPath(path, seconds: seconds)
                    if frame == nil { unavailable = true }
                    continuation.resume(returning: frame.map { TimelineThumbnail(image: $0.image, seconds: $0.seconds, usesFallback: true) })
                    queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, self.serial == ticket else { return }
                        self.reader.close()
                    }
                }
            }
        } onCancel: { self.cancel() }
    }
}

/// One decode in flight; canceled hover subscribers may still populate the cache.
actor TimelinePreviewGenerator {
    private var lastInteractive = Date.distantPast
    private var lastFallbackPrewarm = Date.distantPast
    private var activePath = ""
    private var generator: AssetImageReader?
    private var nativeReader: LocalTimelineReader?
    private var cache: [Int: TimelineThumbnail] = [:]
    private var recency: [Int] = []
    private var generation: UInt64 = 0
    private var preferFallback = false
    private var fallbackAllowed = false
    private struct Failure {
        let retryAt: Date
        let allowedFallback: Bool
    }
    private struct Work {
        let id: UUID
        let bucket: Int
        let allowedFallback: Bool
        let task: Task<TimelineThumbnail?, Never>
    }
    private var failed: [Int: Failure] = [:]

    func status(for path: String, at seconds: Double) -> String? {
        guard path == activePath, seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 4),
              let failure = failed[Int((seconds * 2).rounded())],
              failure.allowedFallback == fallbackAllowed else { return nil }
        return failure.allowedFallback ? "Preview unavailable at this position" : "Preview unavailable · HDR/container support"
    }
    func cancel(for path: String) {
        guard activePath == path else { return }
        generator?.cancelAllCGImageGeneration(); pending?.task.cancel()
        nativeReader?.cancel(); nativeReader = nil
        pending = nil; generator = nil; generation &+= 1
        activePath = ""; cache.removeAll(); recency.removeAll(); failed.removeAll()
    }
    private var pending: Work?

    func noteInteraction() { lastInteractive = Date() }

    private func prepare(_ path: String) {
        guard path != activePath else { return }
        generator?.cancelAllCGImageGeneration()
        nativeReader?.cancel(); nativeReader = nil
        pending?.task.cancel()
        pending = nil
        generation &+= 1
        activePath = path
        preferFallback = false; fallbackAllowed = false; lastFallbackPrewarm = .distantPast; failed.removeAll()
        cache.removeAll(keepingCapacity: true); recency.removeAll(keepingCapacity: true)
        // Timeline thumbnails are approximate; a wider tolerance avoids exact-frame
        // seeking through a long GOP. The actual image timestamp is shown in the UI.
        generator = AssetImageReader(asset: AVURLAsset(url: URL(fileURLWithPath: path)),
            maximumSize: CGSize(width: 320, height: 180), tolerance: CMTime(seconds: 1.5, preferredTimescale: 600))
    }
    private func touch(_ bucket: Int) {
        recency.removeAll { $0 == bucket }; recency.append(bucket)
        while recency.count > 96 { cache.removeValue(forKey: recency.removeFirst()) }
    }
    func cached(for path: String, at seconds: Double) -> TimelineThumbnail? {
        guard path == activePath, seconds.isFinite,
              let key = cache.keys.min(by: { abs((cache[$0]?.seconds ?? 0) - seconds) < abs((cache[$1]?.seconds ?? 0) - seconds) }),
              let sample = cache[key], abs(sample.seconds - seconds) <= 3 else { return nil }
        touch(key)
        return sample
    }
    func prewarm(for path: String, at seconds: Double, allowSDRFallback: Bool) async {
        guard pending == nil, Date().timeIntervalSince(lastInteractive) > 2 else { return }
        if preferFallback {
            guard Date().timeIntervalSince(lastFallbackPrewarm) > 10 else { return }
            lastFallbackPrewarm = Date()
        }
        _ = await thumbnail(for: path, at: seconds, allowSDRFallback: allowSDRFallback, interactive: false)
    }
    func thumbnail(for path: String, at seconds: Double, allowSDRFallback: Bool, interactive: Bool = true) async -> TimelineThumbnail? {
        if interactive { lastInteractive = Date() }
        guard !Task.isCancelled, path.hasPrefix("/"), seconds.isFinite,
              seconds >= 0, seconds < Double(Int.max / 4) else { return nil }
        prepare(path)
        // Color metadata may arrive after file-loaded. Do not retain a failed
        // AV-only probe when we subsequently learn that SDR fallback is safe.
        if allowSDRFallback && !fallbackAllowed { failed.removeAll() }
        fallbackAllowed = allowSDRFallback
        let epoch = generation
        let bucket = Int((seconds * 2).rounded())
        while !Task.isCancelled, epoch == generation {
            if let hit = cache[bucket] { touch(bucket); return hit }
            if let failure = failed[bucket], failure.retryAt > Date(),
               failure.allowedFallback == allowSDRFallback { return nil }
            let work: Work
            if let pending { work = pending }
            else {
                guard let gen = generator else { return nil }
                failed.removeValue(forKey: bucket)
                let time = CMTime(seconds: Double(bucket) / 2, preferredTimescale: 600)
                // Matroska is handled by the local demuxer when SDR is confirmed.
                // Some AVFoundation importers return poster/stale frames instead of errors.
                let matroska = ["mkv", "webm", "mka"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
                let skipAV = allowSDRFallback && (preferFallback || (matroska && FFmpegPreviewDecoder.executable != nil))
                if matroska && allowSDRFallback && nativeReader == nil { nativeReader = LocalTimelineReader() }
                let native = matroska && allowSDRFallback ? nativeReader : nil
                let task = Task<TimelineThumbnail?, Never>.detached(priority: .utility) {
                    if !skipAV {
                        let result = await mediaReadWithDeadline(seconds: 3, cancel: { gen.cancelAllCGImageGeneration() }) { () async -> TimelineThumbnail? in
                            guard !Task.isCancelled, let result = try? await gen.image(at: time),
                                  result.actualTime.seconds.isFinite, result.actualTime.seconds >= 0 else { return nil }
                            return TimelineThumbnail(image: result.image, seconds: result.actualTime.seconds)
                        }
                        if let result, TimelineThumbnail.isNear(result.seconds, target: time.seconds) { return result }
                    }
                    guard !Task.isCancelled, allowSDRFallback else { return nil }
                    if let native, let result = await native.decode(path: path, seconds: time.seconds),
                       TimelineThumbnail.isNear(result.seconds, target: time.seconds) { return result }
                    guard !Task.isCancelled else { return nil }
                    guard let result = await FFmpegPreviewDecoder().decode(path: path, seconds: time.seconds),
                          TimelineThumbnail.isNear(result.seconds, target: time.seconds) else { return nil }
                    return result
                }
                work = Work(id: UUID(), bucket: bucket, allowedFallback: allowSDRFallback, task: task); pending = work
            }
            let result = await work.task.value
            guard epoch == generation else { return nil }
            if pending?.id == work.id {
                pending = nil
                if let result, result.seconds.isFinite {
                    cache[work.bucket] = result; touch(work.bucket)
                    preferFallback = result.usesFallback
                    failed.removeValue(forKey: work.bucket)
                } else {
                    // Back off failed probes rather than repeatedly decoding at pointer frequency.
                    failed = failed.filter { $0.value.retryAt > Date() }
                    if failed.count >= 96 { failed.removeAll() }
                    failed[work.bucket] = Failure(retryAt: Date().addingTimeInterval(10), allowedFallback: work.allowedFallback)
                }
            }
            // A canceled UI subscriber still lets the completed decode fill the cache.
            guard !Task.isCancelled else { return nil }
            // A metadata update can enable SDR fallback while an AV-only probe
            // is in flight. Retry with the new capability instead of freezing on
            // the old probe's failure until the pointer moves again.
            if work.bucket == bucket, result != nil || work.allowedFallback == allowSDRFallback { return result }
            // Only still-interested subscribers start work for their newest target.
        }
        return nil
    }
}

struct TimelinePreviewBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let image: CGImage?
    let timestamp: String
    var imageTimestamp: String?
    let chapter: String?
    var status: String?
    var compact = false
    var body: some View {
        let thumbW: CGFloat = compact ? 120 : 160
        let thumbH: CGFloat = compact ? 68 : 90
        let thumbShape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let unavailable = status?.hasPrefix("Preview unavailable") == true
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                thumbShape
                    .fill(.white.opacity(0.06))
                    .frame(width: thumbW, height: thumbH)

                if let image {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .scaledToFill()
                        .frame(width: thumbW, height: thumbH)
                        .clipped()
                        .transition(.opacity)
                } else {
                    VStack(spacing: 6) {
                        if unavailable {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(status ?? String(localized: "Preparing preview…"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 6)
                    }
                    .frame(width: thumbW, height: thumbH)
                    .transition(.opacity)
                }

                // Render transient status ("Updating preview…") inside the fixed thumbnail box
                // so it never inserts a VStack row below the image or shifts the image vertically.
                if image != nil, status != nil {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    .padding(5)
                    .glassEffect(.regular, in: Capsule())
                    .padding(5)
                    .transition(.opacity)
                }
            }
            .frame(width: thumbW, height: thumbH)
            .clipShape(thumbShape)
            .overlay(thumbShape.strokeBorder(.primary.opacity(0.16), lineWidth: 0.5))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: imageTimestamp)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: image != nil)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: status != nil)

            if let chapter, !chapter.isEmpty {
                Text(chapter)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: thumbW)
            }
            Text(timestamp)
                .contentTransition(.numericText())
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(6)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(PlaybackGlass(cornerRadius: 12))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        .allowsHitTesting(false)
    }
}


/// Explicit placement avoids overlay alignment-guide propagation through nested
/// frames/glass. The bubble bottom is always above the track, regardless of height.
struct TimelinePreviewAboveTrack: Layout {
    let x: CGFloat
    var gap: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for bubble in subviews {
            bubble.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY - gap),
                         anchor: .bottomLeading, proposal: .unspecified)
        }
    }
}
